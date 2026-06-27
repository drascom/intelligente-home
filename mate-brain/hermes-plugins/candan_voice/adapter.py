"""Candan Voice — Hermes gateway platform adapter (real implementation).

Ports `mate-brain/brain/voice/livekit_agent.py::LiveKitAgent` onto the Hermes
`BasePlatformAdapter` contract. The Candan voice stack (RMS endpointing,
smart-turn v3 EOU, barge-in, wake gate, speaker-ID, live transcript + TTS
publish) lives INSIDE this adapter. STT (whisper) and TTS (vox) stay as network
services (.25 GPU) — reached over the same host:port the brain uses; they are
not pushed to the client. The mate-mac LiveKit client is unchanged.

Flow (vs the standalone agent):
  mic track ─► connect(): LiveKit room + per-track consume loop (STT + wake-gate
              + smart-turn EOU + barge-in) ─► utterance final ─►
              MessageEvent(text, source=speaker scope) ─► handle_message()
  handle_message() ─(base spawns task)─► Hermes brain ─► base calls self.send()
  send(reply) ─► vox TTS ─► 48kHz frames published to room + lk.transcription

KEY SHIFT: the standalone `_process_turn` did respond + transcript + TTS in one
method. Under Hermes the brain reply returns OUT-OF-BAND (handle_message → None,
base calls send()), so outbound TTS lives in send(). The LLM/session/db tail of
`_process_turn` is dropped (Hermes brain + Hermes memory own it). The USER
transcript line is published at inbound time; the ASSISTANT line in send().

Phase note: speaker-ID is wired (identify), but there is no brain DB on the
Hermes side, so recognized-vs-guest scoping is identify-only — with no enrolled
embeddings everyone resolves to guest (room-scoped session). Per-user Hermes
memory + auto-enrollment persistence is Phase 2 (see MAP.md / BLOCKER notes).
"""

import asyncio
import logging
import time
from array import array
from typing import Any, Dict, Optional

from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
)
from gateway.config import Platform

from .voice.config import settings
from .voice.hallucination import looks_hallucinated
from .voice.services import WhisperSession
from .voice.tts import synthesize_stream, to_s16le

logger = logging.getLogger(__name__)
log = logger  # parity with ported code

PLATFORM_NAME = "candan_voice"

# --- Endpointing / audio constants (1:1 with livekit_agent.py) ---
SILENCE_RMS = 700
SILENCE_AFTER_S = 1.0
MAX_UTTERANCE_S = 12.0
WAKE_PROPAGATION_TOLERANCE_S = 0.4
BARGE_IN_MIN_S = 0.25
AUDIO_QUEUE_MS = 200
STT_RATE = 16000
STT_WIDTH = 2
STT_CHANNELS = 1
PUB_RATE = 48000
PUB_CHANNELS = 1


class CandanVoiceAdapter(BasePlatformAdapter):
    """LiveKit voice adapter. Instantiated by the adapter_factory in register()."""

    supports_async_delivery: bool = True
    splits_long_messages: bool = True

    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform(PLATFORM_NAME))
        self.settings = settings
        self.room_name = settings.livekit_room

        # Runtime state (mirrors LiveKitAgent).
        self._room = None            # rtc.Room
        self._source = None          # rtc.AudioSource (published TTS)
        self._pub_track_sid = None   # our published track sid (transcript attribution)
        self._tts_task: Optional[asyncio.Task] = None  # in-flight TTS (barge-in cancels)
        self._consume_tasks: Dict[str, asyncio.Task] = {}  # per-participant track consumers
        self._attr_cache: Dict[str, dict] = {}
        self._wake_at = 0.0
        self._barge_in_enabled = True
        self._connected = False
        # Reconnect: LiveKit boş odayı empty_timeout ile kapatır (reason 10 =
        # ROOM_CLOSED) → ajan düşer. _want_connected True iken (kasıtlı disconnect
        # değil) kopuşta _reconnect_loop otomatik yeniden bağlanır. B (insan)
        # katılınca oda boş kalmaz → kapanmaz → kalıcı stabil.
        self._want_connected = False
        self._reconnecting = False
        self._reconnect_task: Optional[asyncio.Task] = None

        # Smart-turn EOU (lazy, fail-open).
        self.turn_detector = None
        if settings.turn_detector_enabled:
            try:
                from .voice.turn_detector import SmartTurnDetector

                self.turn_detector = SmartTurnDetector(
                    settings.turn_detector_repo,
                    settings.turn_detector_file,
                    settings.turn_detector_threshold,
                )
                log.info("candan_voice: smart-turn EOU aktif")
            except Exception as e:
                log.warning("candan_voice: smart-turn kurulamadı: %r", e)

        # Speaker-ID (identify-only; no enrollment store on Hermes side).
        self.speaker = None
        if settings.speaker_id_enabled:
            try:
                from .voice.speaker import build_speaker_id

                self.speaker = build_speaker_id(settings)
            except Exception as e:
                log.warning("candan_voice: speaker-ID kurulamadı: %r", e)

    @property
    def name(self) -> str:
        return "Candan Voice"

    # ── Token ─────────────────────────────────────────────────────────────

    def _mint_token(self) -> str:
        """Server-side JWT (publish+subscribe), identity 'assistant', kind=agent."""
        from datetime import timedelta

        from livekit import api

        grants = api.VideoGrants(
            room_join=True,
            room=self.room_name,
            can_publish=True,
            can_subscribe=True,
            can_update_own_metadata=True,
        )
        at = (
            api.AccessToken(self.settings.livekit_api_key, self.settings.livekit_api_secret)
            .with_identity("assistant")
            .with_name("Candan")
            .with_ttl(timedelta(seconds=self.settings.livekit_token_ttl_seconds))
            .with_grants(grants)
        )
        try:
            at = at.with_kind("agent")
        except (AttributeError, TypeError):
            pass
        try:
            at = at.with_attributes({"lk.agent.state": "initializing"})
        except (AttributeError, TypeError):
            pass
        return at.to_jwt()

    # ── Connection lifecycle ──────────────────────────────────────────────

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        """Public entry: ensure the room exists with a long empty_timeout, then
        join + publish. Marks _want_connected so an unexpected drop triggers
        _reconnect_loop (durable presence; B'nin testi için ajan odada kalır)."""
        if not self.settings.livekit_api_secret:
            log.error("candan_voice: LIVEKIT_API_SECRET boş — bağlanılamaz")
            self._set_fatal_error("config_missing", "LIVEKIT_API_SECRET missing", retryable=False)
            return False
        self._want_connected = True
        await self._ensure_room()
        return await self._open_room()

    async def _ensure_room(self) -> None:
        """Pre-create the room with a long empty_timeout so LiveKit doesn't close
        it while empty (the reason-10 ROOM_CLOSED drop). Idempotent-ish: if the
        room already exists this is a no-op on the server side. Best-effort."""
        from livekit import api

        http_url = (self.settings.livekit_url
                    .replace("wss://", "https://").replace("ws://", "http://"))
        lk = api.LiveKitAPI(http_url, self.settings.livekit_api_key,
                            self.settings.livekit_api_secret)
        try:
            await lk.room.create_room(api.CreateRoomRequest(
                name=self.room_name,
                empty_timeout=86400,       # 24h — boş odayı kapatma
                departure_timeout=86400,
            ))
            log.info("candan_voice: oda hazır (empty_timeout=24h): %s", self.room_name)
        except Exception as e:
            log.warning("candan_voice: create_room atlandı (%r)", e)
        finally:
            try:
                await lk.aclose()
            except Exception:
                pass

    async def _open_room(self) -> bool:
        """Join the LiveKit room, publish a TTS track, subscribe to human mic
        tracks (task-per-participant). Returns True once joined + publishing.
        Called by connect() and by _reconnect_loop()."""
        from livekit import rtc

        room = rtc.Room()
        self._rtc = rtc

        @room.on("track_subscribed")
        def _on_track_subscribed(track, publication, participant):
            if track.kind == rtc.TrackKind.KIND_AUDIO and participant.identity != "assistant":
                log.info("candan_voice: ses track'i abone (%s)", participant.identity)
                self._start_consume(rtc, track, participant)

        @room.on("participant_attributes_changed")
        def _on_attrs_changed(changed_attributes, participant):
            ident = getattr(participant, "identity", None)
            if not ident or ident == "assistant":
                return
            try:
                changed = dict(changed_attributes or {})
                prev = self._attr_cache.get(ident, {}).get("candan.awake")
                new_awake = changed.get("candan.awake")
                if new_awake == "1" and prev == "0":
                    self._wake_at = time.monotonic()
                elif new_awake == "0":
                    self._wake_at = 0.0
                if "candan.barge_in" in changed:
                    self._barge_in_enabled = changed["candan.barge_in"] != "0"
                self._attr_cache.setdefault(ident, {}).update(changed)
            except Exception:
                pass
            log.info("candan_voice: attrs değişti (%s): %r", ident, changed_attributes)

        @room.on("disconnected")
        def _on_disconnected(reason):
            log.warning("candan_voice: odadan koptu (%s)", reason)
            self._connected = False
            # Kasıtlı kapatma (disconnect()) değilse otomatik yeniden bağlan.
            if self._want_connected and not self._reconnecting:
                try:
                    self._reconnect_task = asyncio.create_task(self._reconnect_loop())
                except RuntimeError:
                    pass

        self._attr_cache = {}
        self._barge_in_enabled = True
        self._wake_at = 0.0

        token = self._mint_token()
        await room.connect(self.settings.livekit_url, token)
        log.info("candan_voice: '%s' odasına bağlandı (%s)",
                 self.room_name, self.settings.livekit_url)

        # Publish one audio source/track for TTS replies.
        source = rtc.AudioSource(
            sample_rate=PUB_RATE, num_channels=PUB_CHANNELS, queue_size_ms=AUDIO_QUEUE_MS
        )
        track = rtc.LocalAudioTrack.create_audio_track("assistant", source)
        options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        await room.local_participant.publish_track(track, options)
        self._source = source
        self._room = room
        self._pub_track_sid = getattr(track, "sid", None)
        self._connected = True
        self._set_agent_state("idle")

        # Catch any human tracks that were already published before we joined.
        for participant in room.remote_participants.values():
            if participant.identity == "assistant":
                continue
            for pub in participant.track_publications.values():
                if pub.track is not None and pub.kind == rtc.TrackKind.KIND_AUDIO:
                    self._start_consume(rtc, pub.track, participant)

        return True

    async def _reconnect_loop(self) -> None:
        """Re-open the room after an unexpected drop (e.g. ROOM_CLOSED). Backs
        off on failure; stops once reconnected or disconnect() clears the want
        flag. Once a human (B) is in the room it won't go empty → stays stable."""
        if self._reconnecting:
            return
        self._reconnecting = True
        delay = 2.0
        try:
            while self._want_connected and not self._connected:
                await asyncio.sleep(delay)
                if not self._want_connected:
                    break
                try:
                    self._consume_tasks.clear()  # eski track'ler ölü
                    await self._ensure_room()     # uzun empty_timeout'u garanti et
                    if await self._open_room():
                        log.info("candan_voice: yeniden bağlandı")
                        break
                except Exception as e:
                    log.warning("candan_voice: reconnect denemesi başarısız: %r", e)
                delay = min(delay * 1.5, 15.0)
        finally:
            self._reconnecting = False

    async def disconnect(self) -> None:
        """Cancel consume/TTS tasks, stop reconnect, leave the room."""
        self._want_connected = False
        self._connected = False
        if self._reconnect_task:
            self._reconnect_task.cancel()
            self._reconnect_task = None
        for t in list(self._consume_tasks.values()):
            t.cancel()
        self._consume_tasks.clear()
        if self._tts_task:
            self._tts_task.cancel()
            self._tts_task = None
        room, self._room, self._source = self._room, None, None
        if room is not None:
            try:
                await room.disconnect()
            except Exception:
                pass

    def _start_consume(self, rtc, track, participant) -> None:
        """Spawn (or replace) a per-participant consume task."""
        ident = getattr(participant, "identity", "?")
        old = self._consume_tasks.get(ident)
        if old is not None and not old.done():
            return  # already consuming this participant
        task = asyncio.create_task(self._consume_track(rtc, track, participant))
        self._consume_tasks[ident] = task

    # ── Inbound: mic → STT → endpointing → utterance ──────────────────────

    async def _consume_track(self, rtc, track, participant=None) -> None:
        """Pull 16k mono frames; RMS endpointing + smart-turn EOU + barge-in;
        per-utterance WhisperSession. Ported from LiveKitAgent._consume_track."""
        from wyoming.event import Event as WyomingEvent

        stream = rtc.AudioStream.from_track(
            track=track, sample_rate=STT_RATE, num_channels=STT_CHANNELS
        )
        stt: Optional[WhisperSession] = None
        buf = bytearray()
        speech_seen = False
        consec_speech_s = 0.0
        silence_s = 0.0
        utterance_s = 0.0
        last_turn_check_s = 0.0
        utterance_awake = True
        utterance_start_at = 0.0
        try:
            async for event in stream:
                frame = event.frame
                payload = bytes(frame.data)
                if not payload:
                    continue

                if stt is None:
                    attrs = self._attrs(participant)
                    utterance_awake = attrs.get("candan.awake", "1") != "0"
                    engine_name, stt_host, stt_port = self.settings.resolve_stt_engine(
                        attrs.get("stt_engine")
                    )
                    language = attrs.get("language") or self.settings.stt_language
                    stt = WhisperSession(stt_host, stt_port, language)
                    log.info("candan_voice: STT=%s (%s:%s) dil=%s",
                             engine_name, stt_host, stt_port, language or "(auto)")
                    try:
                        await stt.start(rate=STT_RATE, width=STT_WIDTH, channels=STT_CHANNELS)
                    except (ConnectionError, OSError) as e:
                        log.warning("candan_voice: STT erişilemiyor: %s", e)
                        stt = None
                        continue
                    buf = bytearray()
                    speech_seen = False
                    consec_speech_s = 0.0
                    silence_s = 0.0
                    utterance_s = 0.0
                    last_turn_check_s = 0.0
                    utterance_start_at = 0.0

                await stt.feed(
                    WyomingEvent(
                        type="audio-chunk",
                        data={"rate": STT_RATE, "width": STT_WIDTH, "channels": STT_CHANNELS},
                        payload=payload,
                    )
                )
                buf.extend(payload)
                n_samples = len(payload) // (STT_WIDTH * STT_CHANNELS)
                chunk_s = n_samples / STT_RATE if STT_RATE else 0.0
                utterance_s += chunk_s

                if self._is_silence(payload, STT_WIDTH):
                    silence_s += chunk_s
                    consec_speech_s = 0.0
                else:
                    if not speech_seen:
                        self._set_agent_state("listening")
                        self._debug("user_speech…")
                        utterance_start_at = time.monotonic()
                    speech_seen = True
                    silence_s = 0.0
                    last_turn_check_s = 0.0
                    consec_speech_s += chunk_s
                    if (self._barge_in_enabled
                            and consec_speech_s >= BARGE_IN_MIN_S
                            and self._tts_task and not self._tts_task.done()):
                        self._tts_task.cancel()

                if utterance_s >= MAX_UTTERANCE_S:
                    ended = True
                elif not speech_seen:
                    ended = False
                elif self.turn_detector is None:
                    ended = silence_s >= SILENCE_AFTER_S
                elif silence_s >= self.settings.turn_max_endpointing_delay:
                    ended = True
                elif silence_s >= self.settings.turn_min_endpointing_delay and (
                    last_turn_check_s == 0.0
                    or silence_s - last_turn_check_s >= self.settings.turn_recheck_interval
                ):
                    last_turn_check_s = silence_s
                    ended = await self.turn_detector.is_complete(bytes(buf))
                    p = self.turn_detector.last_prob
                    self._debug(
                        f"eou {'complete' if ended else 'incomplete'}"
                        + (f" p={p:.2f}" if p is not None else "")
                    )
                else:
                    ended = False

                if ended:
                    session, stt = stt, None
                    try:
                        await asyncio.wait_for(
                            self._handle_utterance(
                                session, bytes(buf), participant, track,
                                utterance_awake, utterance_start_at,
                            ),
                            timeout=60.0,
                        )
                    except asyncio.TimeoutError:
                        log.warning("candan_voice: utterance işleme 60sn aştı, atlandı")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("candan_voice: track tüketimi bitti (%s)", e)
        finally:
            if stt is not None:
                try:
                    await asyncio.wait_for(stt.abort(), timeout=2.0)
                except (asyncio.TimeoutError, Exception):
                    pass
            try:
                await asyncio.wait_for(stream.aclose(), timeout=2.0)
            except (asyncio.TimeoutError, Exception):
                pass

    @staticmethod
    def _is_silence(payload: Optional[bytes], width: int) -> bool:
        if not payload or width != 2:
            return not payload
        samples = array("h")
        samples.frombytes(payload[: len(payload) - len(payload) % 2])
        if not samples:
            return True
        mean_abs = sum(abs(s) for s in samples) / len(samples)
        return mean_abs < SILENCE_RMS

    async def _identify(self, pcm: bytes):
        """Voice-ID from utterance PCM. (name, emb). Short / disabled / error →
        (None, None). With no enrolled embeddings, identify → (None, _)."""
        sp = self.speaker
        if sp is None or not pcm:
            return None, None
        n_samples = len(pcm) // 2
        if n_samples < int(self.settings.speaker_min_seconds * STT_RATE):
            return None, None
        try:
            emb = await asyncio.to_thread(sp.embed_pcm, pcm, STT_RATE, 2, 1)
            name, score = sp.identify(emb)
            log.info("candan_voice: speaker-ID %s (%.3f)", name or "unknown", score)
            return name, emb
        except Exception as e:
            log.warning("candan_voice: speaker-ID failed: %s", e)
            return None, None

    async def _handle_utterance(
        self, stt: WhisperSession, pcm: bytes, participant, track,
        awake: bool, utterance_start_at: float,
    ) -> None:
        """Wake-gate + hallucination filter + speaker-ID → MessageEvent →
        handle_message. The LLM/TTS tail of the old _process_turn is gone:
        Hermes returns the reply out-of-band and the base calls send()."""
        try:
            text = (await stt.finish()).strip()
        except (ConnectionError, OSError, asyncio.TimeoutError) as e:
            log.warning("candan_voice: STT başarısız: %s", e)
            return
        log.info("candan_voice: duyuldu %r", text)
        self._debug(f"stt_final: {text[:40]}" if text else "stt_final: (boş)")

        wake_at = self._wake_at
        is_wake_word = bool(wake_at) and (
            utterance_start_at < wake_at - WAKE_PROPAGATION_TOLERANCE_S
        )
        woke = bool(wake_at) and (
            utterance_start_at >= wake_at - WAKE_PROPAGATION_TOLERANCE_S
        )
        if is_wake_word or not (awake or woke):
            reason = "wake kelimesi" if is_wake_word else "uyku modunda söz"
            log.info("candan_voice: %s, atlandı: %r", reason, text[:60])
            self._set_agent_state("idle")
            return
        if text and looks_hallucinated(text):
            log.info("candan_voice: transcript hayalet, atlanıyor: %r", text[:80])
            text = ""
        if not text:
            return

        speaker, _emb = await self._identify(pcm)
        speaker_id = self.speaker.id_for(speaker) if (self.speaker and speaker) else None

        # Active-speaker UI + user transcript line (assistant line is in send()).
        self._publish_speaker(speaker, speaker_id, guest=(speaker_id is None))
        human_track_sid = getattr(track, "sid", None)
        asyncio.create_task(self._publish_text(text, track_sid=human_track_sid, role="user"))

        # speaker-ID → session scope. Recognized → per-user; guest → room scope.
        if speaker_id:
            user_id, user_name = str(speaker_id), speaker
        else:
            user_id, user_name = None, None
        source = self.build_source(
            chat_id=self.room_name,
            chat_name=self.room_name,
            chat_type="dm",
            user_id=user_id,
            user_name=user_name,
        )
        self._set_agent_state("thinking")
        await self.handle_message(MessageEvent(
            text=text, message_type=MessageType.TEXT, source=source,
            message_id=str(int(time.time() * 1000)),
        ))

    # ── Outbound: Hermes reply → vox TTS → room ───────────────────────────

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Speak the brain reply into the room + publish the assistant transcript.
        Ported from LiveKitAgent._speak / _publish_text."""
        if not content or not content.strip():
            self._set_agent_state("idle")
            return SendResult(success=True, message_id="empty")
        # Assistant transcript line (best-effort, parallel).
        asyncio.create_task(
            self._publish_text(content, track_sid=self._pub_track_sid, role="assistant")
        )
        # TTS as a cancellable task so the next utterance can barge-in.
        voice = None  # per-client voice attr could be threaded via metadata later
        self._tts_task = asyncio.create_task(self._speak(content, voice))
        try:
            await self._tts_task
        except asyncio.CancelledError:
            return SendResult(success=True, message_id="barge_in")
        except Exception as e:
            log.warning("candan_voice: send/TTS hatası: %r", e)
            return SendResult(success=False, error=str(e))
        return SendResult(success=True, message_id=str(int(time.time() * 1000)))

    async def _speak(self, text: str, voice: Optional[str] = None) -> None:
        from livekit import rtc

        source = self._source
        if source is None:
            log.warning("candan_voice: TTS atlandı — yayın kaynağı yok")
            self._set_agent_state("idle")
            return
        fmt = None
        frames_pub = 0
        try:
            async for kind, value in synthesize_stream(text, voice):
                if kind == "start":
                    fmt = value
                    self._set_agent_state("speaking")
                    self._debug("tts_start")
                elif kind == "chunk" and fmt is not None:
                    pcm = to_s16le(value, fmt)
                    frames_pub += await self._capture_s16le(
                        rtc, source, pcm, fmt.rate, fmt.channels
                    )
            self._debug("tts_end")
        except asyncio.CancelledError:
            log.info("candan_voice: TTS iptal (barge-in)")
            try:
                source.clear_queue()
            except Exception:
                pass
            self._set_agent_state("listening")
            raise
        except Exception as e:
            log.warning("candan_voice: TTS başarısız: %r", e)
        self._set_agent_state("idle")

    async def _capture_s16le(self, rtc, source, pcm: bytes, rate: int, channels: int) -> int:
        if not pcm:
            return 0
        if channels > 1:
            pcm = self._to_mono(pcm, channels)
        frames = []
        if rate != PUB_RATE:
            resampler = rtc.AudioResampler(
                input_rate=rate, output_rate=PUB_RATE, num_channels=PUB_CHANNELS
            )
            frames.extend(resampler.push(bytearray(pcm)))
            frames.extend(resampler.flush())
        else:
            samples_per_channel = len(pcm) // 2
            frames.append(rtc.AudioFrame(
                data=pcm, sample_rate=PUB_RATE, num_channels=PUB_CHANNELS,
                samples_per_channel=samples_per_channel,
            ))
        for frame in frames:
            await source.capture_frame(frame)
        return len(frames)

    @staticmethod
    def _to_mono(pcm: bytes, channels: int) -> bytes:
        samples = array("h")
        samples.frombytes(pcm[: len(pcm) - len(pcm) % (2 * channels)])
        mono = array("h", samples[::channels])
        return mono.tobytes()

    # ── Publish helpers (text-stream topics) ──────────────────────────────

    async def _publish_text(self, text: str, *, track_sid: Optional[str] = None,
                            role: str = "") -> None:
        room = self._room
        if room is None or not text:
            return
        attrs = {"lk.transcription_final": "true"}
        if track_sid:
            attrs["lk.transcribed_track_id"] = track_sid
        if role:
            attrs["candan.role"] = role
        try:
            lp = room.local_participant
            try:
                await lp.send_text(text, topic="lk.transcription", attributes=attrs)
            except TypeError:
                try:
                    await lp.send_text(text, topic="lk.transcription")
                except TypeError:
                    await lp.send_text(text)
        except Exception as e:
            log.warning("candan_voice: transcript yayınlanamadı (%s): %r", role, e)

    def _publish_speaker(self, name, speaker_id, guest: bool) -> None:
        room = self._room
        if room is None:
            return
        import json

        payload = json.dumps(
            {"name": name, "speakerId": speaker_id, "guest": bool(guest)},
            ensure_ascii=False,
        )

        async def _send() -> None:
            try:
                await room.local_participant.send_text(payload, topic="candan.speaker")
            except Exception:
                pass

        try:
            asyncio.create_task(_send())
        except RuntimeError:
            pass

    def _debug(self, msg: str) -> None:
        room = self._room
        if room is None:
            return
        ms = int((time.time() % 1) * 1000)
        line = f"{time.strftime('%H:%M:%S')}.{ms:03d} {msg}"

        async def _send() -> None:
            try:
                await room.local_participant.send_text(line, topic="candan.debug")
            except Exception:
                pass

        try:
            asyncio.create_task(_send())
        except RuntimeError:
            pass

    def _set_agent_state(self, state: str) -> None:
        self._debug(f"agent: {state}")
        room = self._room
        if room is None:
            return

        async def _apply() -> None:
            try:
                await room.local_participant.set_attributes({"lk.agent.state": state})
            except Exception as e:
                log.warning("candan_voice: agent-state ayarlanamadı (%s): %r", state, e)

        try:
            asyncio.create_task(_apply())
        except RuntimeError:
            pass

    def _attrs(self, participant) -> dict:
        merged: dict = {}
        try:
            a = getattr(participant, "attributes", None)
            if a:
                merged.update(dict(a))
        except Exception:
            pass
        ident = getattr(participant, "identity", None)
        if ident:
            merged.update(self._attr_cache.get(ident, {}))
        return merged

    # ── Misc contract methods ─────────────────────────────────────────────

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def send_image(
        self, chat_id: str, image_url: str, caption: Optional[str] = None,
        reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        return SendResult(success=False, error="candan_voice: image delivery unsupported")

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": self.room_name, "type": "dm", "chat_id": chat_id}


# ---------------------------------------------------------------------------
# Plugin helpers + registration
# ---------------------------------------------------------------------------

def check_requirements() -> bool:
    """Heavy deps (livekit, numpy, ...) checked lazily at connect; return True so
    the plugin always registers and connect() can report a precise error."""
    try:
        import livekit  # noqa: F401
        return True
    except Exception:
        logger.warning("candan_voice: livekit not importable — connect() will fail")
        return True


def validate_config(config) -> bool:
    return bool(settings.livekit_url and settings.livekit_api_secret)


def is_connected(config) -> bool:
    return bool(settings.livekit_url and settings.livekit_api_secret)


def _env_enablement() -> Optional[dict]:
    import os
    if not (os.getenv("LIVEKIT_URL") and os.getenv("LIVEKIT_API_SECRET")):
        return None
    room = settings.livekit_room
    return {
        "url": settings.livekit_url,
        "room": room,
        "home_channel": {"chat_id": room, "chat_type": "dm"},
    }


def register(ctx) -> None:
    """Plugin entry point: called by the Hermes plugin system."""
    ctx.register_platform(
        name=PLATFORM_NAME,
        label="Candan Voice",
        adapter_factory=lambda cfg: CandanVoiceAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["LIVEKIT_URL", "LIVEKIT_API_SECRET"],
        install_hint="Needs livekit + numpy + onnxruntime + sherpa_onnx + transformers + wyoming",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="CANDAN_HOME_CHANNEL",
        allow_all_env="CANDAN_VOICE_ALLOW_ALL_USERS",
        emoji="🎙️",
        pii_safe=False,
        platform_hint=(
            "You are speaking with the user over a live voice channel (LiveKit). "
            "Replies are read aloud via text-to-speech — write natural spoken "
            "Turkish or English, no markdown, no code blocks, no emoji. Keep "
            "answers short and conversational; the user can interrupt you "
            "(barge-in) at any time."
        ),
    )
