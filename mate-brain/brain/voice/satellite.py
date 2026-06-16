"""Wyoming satellite controller — the brain's own voice access point.

The brain connects directly to each wyoming-satellite (Pi Zero 2 W) on TCP
10700 and drives the full loop itself: wake detection event from the satellite
→ stream mic audio to Whisper → transcript → agent → Piper → stream reply
audio back to the satellite's speaker. Home Assistant is not in this path:
if HA is down, voice still works (the agent just loses its device tools).

Endpointing: we honour the satellite's own VAD events (voice-stopped) when
configured, and fall back to a simple RMS silence detector + hard cap.
"""

import asyncio
import logging
from array import array

from wyoming.event import Event, async_read_event, async_write_event

from brain.monitor.bus import emit_turn
from brain.voice.services import WhisperSession
from brain.voice.tts import synthesize_stream, to_s16le

log = logging.getLogger("brain.voice")

RECONNECT_DELAY = 5
SILENCE_RMS = 700          # int16 mean-abs level treated as silence
SILENCE_AFTER_S = 1.0      # end utterance after this much trailing silence
MAX_UTTERANCE_S = 12.0     # hard cap per utterance
PING_INTERVAL_S = 30


class Satellite:
    def __init__(self, name: str, host: str, port: int, agent, db, settings, speaker=None):
        self.name = name
        self.host = host
        self.port = port
        self.agent = agent
        self.db = db
        self.settings = settings
        self.speaker = speaker  # SpeakerID | None (voice-ID)
        self.connected = False
        # Aktif oturumun writer'ı (announce için) + speak serileştirme kilidi:
        # anons ile turn cevabı aynı anda yazarsa Wyoming event akışı bozulur.
        self._writer = None
        self._speak_lock = asyncio.Lock()

    @property
    def conversation_id(self) -> str:
        return f"satellite-{self.name}"

    async def run(self) -> None:
        """Reconnect-forever loop. Run as a background task."""
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("satellite %s: connection lost (%s); retry in %ss",
                            self.name, e, RECONNECT_DELAY)
            self.connected = False
            self._writer = None
            await asyncio.sleep(RECONNECT_DELAY)

    async def _session(self) -> None:
        reader, writer = await asyncio.open_connection(self.host, self.port)
        log.info("satellite %s: connected (%s:%s)", self.name, self.host, self.port)
        self.connected = True
        self._writer = writer
        await async_write_event(Event(type="run-satellite"), writer)

        pinger = asyncio.create_task(self._ping_loop(writer))
        stt: WhisperSession | None = None
        buf = bytearray()  # voice-ID için ham utterance PCM (s16le 16k mono)
        speech_seen = False
        silence_s = 0.0
        utterance_s = 0.0
        try:
            while True:
                event = await async_read_event(reader)
                if event is None:
                    raise ConnectionError("satellite closed connection")

                if event.type == "ping":
                    await async_write_event(Event(type="pong"), writer)

                elif event.type in ("run-pipeline", "detection"):
                    if stt is None:
                        log.info("satellite %s: wake (%s)", self.name, event.type)
                        stt = WhisperSession(
                            self.settings.stt_host, self.settings.stt_port,
                            self.settings.stt_language,
                        )
                        # wyoming-satellite default mic format
                        await stt.start(rate=16000, width=2, channels=1)
                        buf = bytearray()
                        speech_seen = False
                        silence_s = 0.0
                        utterance_s = 0.0

                elif event.type == "audio-chunk" and stt is not None:
                    await stt.feed(event)
                    if event.payload:
                        buf.extend(event.payload)
                    data = event.data or {}
                    rate = data.get("rate", 16000)
                    width = data.get("width", 2)
                    channels = data.get("channels", 1)
                    n_samples = len(event.payload or b"") // (width * channels)
                    chunk_s = n_samples / rate if rate else 0.0
                    utterance_s += chunk_s

                    if self._is_silence(event.payload, width):
                        silence_s += chunk_s
                    else:
                        speech_seen = True
                        silence_s = 0.0

                    ended = (speech_seen and silence_s >= SILENCE_AFTER_S) or (
                        utterance_s >= MAX_UTTERANCE_S
                    )
                    if ended:
                        session, stt = stt, None
                        await self._handle_utterance(session, writer, bytes(buf))

                elif event.type in ("voice-stopped", "audio-stop") and stt is not None:
                    session, stt = stt, None
                    await self._handle_utterance(session, writer, bytes(buf))

                elif event.type == "error":
                    log.warning("satellite %s error event: %s", self.name, event.data)
        finally:
            pinger.cancel()
            if stt is not None:
                await stt.abort()
            writer.close()

    async def _ping_loop(self, writer) -> None:
        while True:
            await asyncio.sleep(PING_INTERVAL_S)
            await async_write_event(Event(type="ping"), writer)

    @staticmethod
    def _is_silence(payload: bytes | None, width: int) -> bool:
        if not payload or width != 2:
            return not payload
        samples = array("h")
        samples.frombytes(payload[: len(payload) - len(payload) % 2])
        if not samples:
            return True
        mean_abs = sum(abs(s) for s in samples) / len(samples)
        return mean_abs < SILENCE_RMS

    async def _identify(self, pcm: bytes) -> str | None:
        """Biriken utterance PCM'inden kişiyi tanı (voice-ID). s16le 16k mono."""
        sp = self.speaker
        if sp is None or not pcm:
            return None
        n_samples = len(pcm) // 2
        if n_samples < int(self.settings.speaker_min_seconds * 16000):
            return None
        try:
            emb = await asyncio.to_thread(sp.embed_pcm, pcm, 16000, 2, 1)
            name, score = sp.identify(emb)
            log.info("satellite %s: speaker-ID %s (%.3f)", self.name, name or "unknown", score)
            return name
        except Exception as e:
            log.warning("satellite %s: speaker-ID failed: %s", self.name, e)
            return None

    async def _handle_utterance(self, stt: WhisperSession, writer, pcm: bytes = b"") -> None:
        text = (await stt.finish()).strip()
        log.info("satellite %s: heard %r", self.name, text)
        if not text:
            return
        speaker = await self._identify(pcm)
        data = {"text": text}
        if speaker:
            data["speaker"] = speaker
        await async_write_event(Event(type="transcript", data=data), writer)

        # Tanınan kişi → kullanıcı-kapsamlı oturum; yoksa bu satellite'ın cihaz kapsamı.
        speaker_id = self.speaker.id_for(speaker) if (self.speaker and speaker) else None
        scope_key, user_id = (
            (f"user-{speaker_id}", speaker_id) if speaker_id else (self.conversation_id, None)
        )
        session_id = await self.db.resolve_session(scope_key, user_id)
        history = await self.db.recent_messages(session_id)
        try:
            answer = await self.agent.respond(history, text, speaker=speaker, speaker_id=speaker_id,
                                              conversation_id=scope_key)
        except Exception as e:
            log.error("satellite %s: agent failed: %s", self.name, e)
            answer = "Sorry, something went wrong."
        await self.db.add_message(session_id, "user", text, speaker=speaker)
        await self.db.add_message(session_id, "assistant", answer)
        emit_turn(getattr(self.agent, "bus", None), scope_key, None, text, answer,
                  speaker=speaker)

        await self.speak(answer, writer)

    async def announce(self, text: str) -> bool:
        """Sunucu kaynaklı anons: aktif oturum varsa hoparlöre söyle.
        True = gönderildi, False = satellite bağlı değil."""
        writer = self._writer
        if not self.connected or writer is None:
            return False
        await self.speak(text, writer)
        return True

    async def speak(self, text: str, writer) -> None:
        """Stream TTS audio (vox or piper) to the satellite's speaker as
        Wyoming s16le audio events."""
        async with self._speak_lock:
            await self._speak_unlocked(text, writer)

    async def _speak_unlocked(self, text: str, writer) -> None:
        fmt = None
        try:
            async for kind, value in synthesize_stream(text):
                if kind == "start":
                    fmt = value
                    await async_write_event(
                        Event(
                            type="audio-start",
                            data={"rate": fmt.rate, "width": 2, "channels": fmt.channels},
                        ),
                        writer,
                    )
                elif kind == "chunk" and fmt is not None:
                    payload = to_s16le(value, fmt)
                    await async_write_event(
                        Event(
                            type="audio-chunk",
                            data={"rate": fmt.rate, "width": 2, "channels": fmt.channels},
                            payload=payload,
                        ),
                        writer,
                    )
            if fmt is not None:
                await async_write_event(Event(type="audio-stop"), writer)
        except (ConnectionError, OSError) as e:
            log.error("satellite %s: TTS failed: %s", self.name, e)


def parse_satellites(spec: str) -> list[tuple[str, str, int]]:
    """Parse SATELLITES env: 'kitchen@192.168.1.50:10700,hall@10.0.0.7'."""
    out = []
    for part in filter(None, (p.strip() for p in spec.split(","))):
        name, _, addr = part.partition("@")
        host, _, port = addr.partition(":")
        out.append((name, host or name, int(port or 10700)))
    return out
