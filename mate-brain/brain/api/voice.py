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
from brain.notify.reminders import delivery_prefix, take_due_deliveries
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
    # Canlı bağlantıyı client_id ile kaydet → scheduler proaktif chime'ı buraya yollar.
    voice_clients = app.state.voice_clients
    voice_clients.setdefault(client["id"], set()).add(websocket)
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
        speaker = msg.get("speaker")        # voice-ID sonucu (ad)
        speaker_id = msg.get("speaker_id")  # voice-ID sonucu (DB id)
        db = app.state.db
        try:
            # Tanınan kişi → kullanıcı-kapsamlı oturum (cihazdan bağımsız süreklilik);
            # bilinmeyen → cihaz-kapsamlı oturum.
            scope_key, user_id = (
                (f"user-{speaker_id}", speaker_id) if speaker_id else (conversation_id, None)
            )
            session_id = await db.resolve_session(scope_key, user_id)
            if user_id is not None:
                # presence: bu kişi en son bu cihazdan konuştu → chime buraya gider.
                await db.set_presence(user_id, f"client:{client['id']}")
            history = await db.recent_messages(session_id)
            answer = await app.state.agent.respond(
                history, text, speaker=speaker, speaker_id=speaker_id,
                conversation_id=scope_key,
            )
            # Bekleyen hatırlatma teslimi (chime → uyandır → teslim).
            reminders = await take_due_deliveries(db, user_id)
            if reminders:
                answer = (delivery_prefix(reminders) + " " + answer).strip()
            await db.add_message(session_id, "user", text, speaker=speaker)
            await db.add_message(session_id, "assistant", answer)
            emit_turn(bus, scope_key, client["id"], text, answer, speaker=speaker)
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

    async def identify_speaker(current: dict) -> str | None:
        """Biriken utterance PCM'inden kişiyi tanı (voice-ID). Kapalıysa / çok
        kısaysa / hata olursa None. CPU-bound embed thread'e atılır."""
        sp = getattr(app.state, "speaker", None)
        if sp is None:
            return None
        fmt = current["fmt"]
        buf = bytes(current["buf"])
        frame = fmt["width"] * fmt["channels"]
        n_samples = len(buf) // frame if frame else 0
        if n_samples < int(settings.speaker_min_seconds * fmt["rate"]):
            return None
        try:
            emb = await asyncio.to_thread(
                sp.embed_pcm, buf, fmt["rate"], fmt["width"], fmt["channels"]
            )
            name, score = sp.identify(emb)
            log.info("speaker-ID: %s (%.3f)", name or "unknown", score)
            return name
        except Exception as e:
            log.warning("speaker-ID failed: %s", e)
            return None

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
        speaker = await identify_speaker(current) if text else None
        sp = getattr(app.state, "speaker", None)
        speaker_id = sp.id_for(speaker) if (sp and speaker) else None
        transcript_msg = {"type": "transcript", "id": turn_id, "text": text}
        if speaker:
            transcript_msg["speaker"] = speaker
        await send_json(transcript_msg)
        if not text:
            return
        for task in active.values():
            task.cancel()
        active.clear()
        active[turn_id] = asyncio.create_task(
            handle_turn({**current["msg"], "id": turn_id, "text": text,
                         "speaker": speaker, "speaker_id": speaker_id})
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
                    stt["buf"].extend(message["bytes"])  # voice-ID için ham PCM biriktir
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
                stt = {"id": msg.get("id") or "", "session": session, "fmt": fmt,
                       "msg": msg, "buf": bytearray()}

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
        conns = voice_clients.get(client["id"])
        if conns is not None:
            conns.discard(websocket)
            if not conns:
                voice_clients.pop(client["id"], None)
        if stt is not None:
            await stt["session"].abort()
        for task in active.values():
            task.cancel()
        if bus:
            bus.emit("client_disconnect", "voice", f"{client['name']} (voice) ayrıldı",
                     payload={"transport": "voice"},
                     conversation_id=conversation_id, client_id=client["id"])
