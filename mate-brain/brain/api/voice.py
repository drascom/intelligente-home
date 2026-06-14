"""Bridge v0 voice WebSocket — `/api/voice` (see docs/PRIOR_WORK.md).

Speaks the protocol mate-ios already implements (RealtimeBridgeClient.swift):

  client → server (JSON text frames):
    {"type": "speak", "id": ..., "text": ..., "voice"?: ..., "want_audio"?: bool}
      — `text` is the USER utterance (client did STT on-device)
    {"type": "audio_start", "id": ..., "rate"?: 16000, "width"?: 2,
     "channels"?: 1, "voice"?: ..., "want_audio"?: bool}
      — audio-up mode: client streams mic PCM, server does STT (Whisper)
    <binary PCM frames (s16le by default)>
    {"type": "audio_stop", "id": ...}  — end of utterance → transcript + turn
    {"type": "cancel", "id": ...}      — barge-in: stop STT/TTS for that id
    {"type": "ping"}

  server → client:
    {"type": "transcript", "id": ..., "text": ...}     — server-STT result
    {"type": "reply", "id": ..., "text": ...}          — assistant reply text
    {"type": "audio_start", "id": ..., "sample_rate": ..., "channels": ...}
    <binary pcm_f32le frames>
    {"type": "audio_end", "id": ...}
    {"type": "pong"} / {"type": "error", "id"?: ..., "message": ...}

`want_audio` defaults to true (Bridge v0 clients expect audio). Phones doing
local TTS send want_audio=false and only get the `reply` text. Auth: `?token=`
query param, same as `/api/ws`.
"""

import asyncio
import json
import logging

from fastapi import APIRouter, WebSocket
from fastapi.websockets import WebSocketDisconnect
from wyoming.event import Event as WyomingEvent

from brain.config import settings
from brain.monitor.bus import emit_turn
from brain.voice.services import WhisperSession
from brain.voice.tts import synthesize_stream, to_f32le

log = logging.getLogger("brain.voice.bridge")

router = APIRouter()


def looks_hallucinated(text: str) -> bool:
    """Whisper'ın gürültüden uydurduğu metinleri yakala: aynı kelimenin takılı
    plak gibi tekrarı ('iplik iplik iplik...') veya çok düşük kelime çeşitliliği."""
    words = [w.strip(".,!?…").lower() for w in text.split()]
    words = [w for w in words if w]
    if len(words) < 6:
        return False
    if len(set(words)) / len(words) < 0.4:
        return True
    run = 1
    for a, b in zip(words, words[1:]):
        run = run + 1 if a == b else 1
        if run >= 4:
            return True
    return False


async def _authenticate(websocket: WebSocket) -> dict | None:
    token = websocket.query_params.get("token") or ""
    if settings.brain_admin_token and token == settings.brain_admin_token:
        return {"id": 0, "name": "admin"}
    return await websocket.app.state.db.get_client_by_token(token)


@router.websocket("/api/voice")
async def voice_bridge(websocket: WebSocket):
    client = await _authenticate(websocket)
    if client is None:
        await websocket.close(code=4401)
        return
    await websocket.accept()
    app = websocket.app
    conversation_id = f"client-{client['id']}"  # shared with /api/ws and /api/chat
    active: dict[str, asyncio.Task] = {}
    bus = getattr(app.state, "bus", None)
    if bus:
        bus.emit("client_connect", "voice", f"{client['name']} (voice) bağlandı",
                 payload={"transport": "voice"},
                 conversation_id=conversation_id, client_id=client["id"])

    async def send_json(obj: dict) -> None:
        await websocket.send_text(json.dumps(obj, ensure_ascii=False))

    async def handle_turn(msg: dict) -> None:
        turn_id = msg.get("id") or ""
        text = msg["text"]
        want_audio = msg.get("want_audio", True)
        db = app.state.db
        try:
            history = await db.recent_messages(conversation_id)
            answer = await app.state.agent.respond(history, text)
            await db.add_message(conversation_id, "user", text)
            await db.add_message(conversation_id, "assistant", answer)
            emit_turn(bus, conversation_id, client["id"], text, answer)
            await send_json({"type": "reply", "id": turn_id, "text": answer})
            if want_audio and answer:
                await stream_tts(turn_id, answer, msg.get("voice"))
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.exception("voice turn failed")
            await send_json({"type": "error", "id": turn_id, "message": str(e)})

    async def stream_tts(turn_id: str, text: str, voice: str | None) -> None:
        started = False
        try:
            await _stream_tts_events(turn_id, text, voice)
        except (ConnectionError, OSError) as e:
            log.warning("TTS (%s) unreachable: %s", settings.tts_engine, e)
            await send_json(
                {
                    "type": "error",
                    "id": turn_id,
                    "message": "TTS hizmeti kapalı — ses yok, yanıt yalnızca metin "
                    f"({settings.tts_engine} erişilemiyor)",
                }
            )

    async def _stream_tts_events(turn_id: str, text: str, voice: str | None) -> None:
        started = False
        fmt = None
        try:
            async for kind, value in synthesize_stream(text, voice=voice):
                if kind == "start":
                    fmt = value
                    started = True
                    await send_json(
                        {
                            "type": "audio_start",
                            "id": turn_id,
                            "sample_rate": fmt.rate,
                            "channels": fmt.channels,
                            "format": "pcm_f32le",
                        }
                    )
                elif kind == "chunk" and fmt is not None:
                    await websocket.send_bytes(to_f32le(value, fmt))
        finally:
            if started:
                await send_json({"type": "audio_end", "id": turn_id})

    # Upstream STT state: one in-flight utterance per connection.
    # {"id", "session": WhisperSession, "msg": original audio_start payload}
    stt: dict | None = None

    async def abort_stt() -> None:
        nonlocal stt
        if stt is not None:
            await stt["session"].abort()
            stt = None

    async def finish_stt() -> None:
        """audio_stop: transcript → client, then a normal turn with that text."""
        nonlocal stt
        current, stt = stt, None
        turn_id = current["id"]
        try:
            text = (await current["session"].finish()).strip()
        except (ConnectionError, OSError, asyncio.TimeoutError) as e:
            log.warning("server STT failed: %s", e)
            await send_json(
                {"type": "error", "id": turn_id,
                 "message": f"STT hizmeti kapalı — ses çözülemedi ({e})"}
            )
            return
        if text and looks_hallucinated(text):
            log.info("transcript looks hallucinated, dropping: %r", text[:80])
            text = ""
        await send_json({"type": "transcript", "id": turn_id, "text": text})
        if not text:
            return
        for task in active.values():
            task.cancel()
        active.clear()
        active[turn_id] = asyncio.create_task(
            handle_turn({**current["msg"], "id": turn_id, "text": text})
        )

    try:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break

            # Binary frame = mic PCM for the in-flight utterance.
            if message.get("bytes") is not None:
                if stt is not None:
                    fmt = stt["fmt"]
                    await stt["session"].feed(
                        WyomingEvent(type="audio-chunk", data=fmt, payload=message["bytes"])
                    )
                continue
            if message.get("text") is None:
                continue
            try:
                msg = json.loads(message["text"])
            except json.JSONDecodeError:
                await send_json({"type": "error", "message": "invalid JSON"})
                continue
            mtype = msg.get("type")

            if mtype == "ping":
                await send_json({"type": "pong"})

            elif mtype == "speak" and msg.get("text"):
                # New utterance interrupts whatever is still talking (barge-in).
                for task in active.values():
                    task.cancel()
                turn_id = msg.get("id") or ""
                active.clear()
                active[turn_id] = asyncio.create_task(handle_turn(msg))

            elif mtype == "audio_start":
                # Upstream utterance begins: phone streams mic audio, the brain
                # runs server-side Whisper (same path the satellites use).
                await abort_stt()
                fmt = {
                    "rate": int(msg.get("rate", 16000)),
                    "width": int(msg.get("width", 2)),
                    "channels": int(msg.get("channels", 1)),
                }
                session = WhisperSession(
                    settings.stt_host, settings.stt_port, settings.stt_language
                )
                try:
                    await session.start(**fmt)
                except (ConnectionError, OSError) as e:
                    log.warning("STT unreachable: %s", e)
                    await send_json(
                        {"type": "error", "id": msg.get("id") or "",
                         "message": f"STT hizmeti kapalı ({e})"}
                    )
                    continue
                stt = {"id": msg.get("id") or "", "session": session, "fmt": fmt, "msg": msg}

            elif mtype == "audio_stop":
                if stt is not None:
                    await finish_stt()

            elif mtype == "cancel":
                if stt is not None and stt["id"] == (msg.get("id") or ""):
                    await abort_stt()
                task = active.pop(msg.get("id") or "", None)
                if task:
                    task.cancel()

            else:
                await send_json(
                    {"type": "error", "message": f"unknown message type: {mtype}"}
                )
    except WebSocketDisconnect:
        pass
    finally:
        if stt is not None:
            await stt["session"].abort()
        for task in active.values():
            task.cancel()
        if bus:
            bus.emit("client_disconnect", "voice", f"{client['name']} (voice) ayrıldı",
                     payload={"transport": "voice"},
                     conversation_id=conversation_id, client_id=client["id"])
