"""Mate Voice — Hermes gateway platform adapter (real implementation).

Ports `mate-brain/brain/voice/livekit_agent.py::LiveKitAgent` onto the Hermes
`BasePlatformAdapter` contract. The Mate voice stack (RMS endpointing,
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
from .voice.speaker_store import SpeakerStore
from .voice.tts import synthesize_stream, to_s16le

logger = logging.getLogger(__name__)
log = logger  # parity with ported code

PLATFORM_NAME = "mate_voice"

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


class MateVoiceAdapter(BasePlatformAdapter):
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
        # Recognize-first oto-enrollment durumu: bilinmeyen ses asistana hitap
        # edince ORİJİNAL istek BEKLETİLİR ({text, emb}), isim sorulur; sonraki
        # utterance isim olur → enroll + bekletilen istek tanınan kullanıcı olarak
        # işlenir. None = enrollment akışında değiliz.
        self._pending_enroll: Optional[dict] = None
        # Bu bağlantıda zaten "hoş geldin" denmiş speaker_id'ler (bir kez selam).
        # Her connect/reconnect'te sıfırlanır → tekrar bağlanınca yine karşılar.
        self._greeted_speakers: set = set()
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
        # Token endpoint (aiohttp): clients fetch room-scoped join tokens with a
        # shared key; LiveKit secret stays server-side. Started once in connect(),
        # independent of room reconnects, stopped in disconnect().
        self._token_runner = None

        # Eksik Python deps'i (onnxruntime/transformers/sherpa-onnx…) gateway
        # venv'ine kendi kur — Hermes installer deps kurmaz. Sadece ETKİN
        # özellikler için, fail-open (bkz. voice/_deps.py).
        try:
            from .voice._deps import ensure_deps

            ensure_deps(
                turn_detector=settings.turn_detector_enabled,
                speaker_id=settings.speaker_id_enabled,
            )
        except Exception as e:
            log.warning("mate_voice: deps ensure atlandı: %r", e)

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
                log.info("mate_voice: smart-turn EOU aktif")
            except Exception as e:
                log.warning("mate_voice: smart-turn kurulamadı: %r", e)

        # Speaker-ID + plugin-local enrollment store (Faz 2 / onboarding).
        # Store, SpeakerID açıkken kurulur; reload connect()'te yapılır (async DB).
        self.speaker = None
        self.speaker_store: Optional[SpeakerStore] = None
        if settings.speaker_id_enabled:
            try:
                from .voice.speaker import build_speaker_id

                model_path = self._ensure_speaker_model()
                if model_path:
                    settings.speaker_model_path = model_path
                self.speaker = build_speaker_id(settings)
                if self.speaker is not None:
                    self.speaker_store = SpeakerStore()
            except Exception as e:
                log.warning("mate_voice: speaker-ID kurulamadı: %r", e)

    @staticmethod
    def _ensure_speaker_model() -> str:
        """CAM++ speaker modelini garanti et — plugin self-contained (mate-brain'e
        bağlı DEĞİL). SPEAKER_MODEL_PATH set + dosya varsa onu kullan; yoksa
        ~/.hermes/mate_voice/campplus.onnx'e release URL'inden indir (bir kez).
        Döner: model yolu ('' = indirilemedi → speaker-ID graceful kapanır)."""
        import os
        import urllib.request

        p = (os.getenv("SPEAKER_MODEL_PATH") or "").strip()
        if p and os.path.exists(p):
            return p
        dst = os.path.expanduser("~/.hermes/mate_voice/campplus.onnx")
        if os.path.exists(dst):
            return dst
        url = os.getenv("MATE_SPEAKER_MODEL_URL") or (
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
            "speaker-recongition-models/"
            "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
        )
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            log.warning("mate_voice: speaker modeli indiriliyor (bir kez) → %s", dst)
            tmp = dst + ".part"
            urllib.request.urlretrieve(url, tmp)
            os.replace(tmp, dst)
            log.info("mate_voice: speaker modeli indirildi (%d bayt)", os.path.getsize(dst))
            return dst
        except Exception as e:
            log.warning("mate_voice: speaker modeli indirilemedi (%r) — speaker-ID kapalı kalır", e)
            return ""

    @property
    def name(self) -> str:
        return "Mate Voice"

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
            .with_name("Mate")
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

    def _mint_client_token(self, identity: str, room: str, ttl_seconds: Optional[int] = None) -> str:
        """Room-scoped JOIN token for a CLIENT participant (publish+subscribe+
        canUpdateOwnMetadata). NOT kind=agent — a normal participant. ttl_seconds
        verilmezse client_token_ttl (uzun); demo-token kısa TTL geçirir."""
        from datetime import timedelta

        from livekit import api

        ttl = ttl_seconds if ttl_seconds is not None else self.settings.client_token_ttl_seconds
        grants = api.VideoGrants(
            room_join=True, room=room,
            can_publish=True, can_subscribe=True, can_update_own_metadata=True,
        )
        at = (
            api.AccessToken(self.settings.livekit_api_key, self.settings.livekit_api_secret)
            .with_identity(identity)
            .with_name(identity)
            .with_ttl(timedelta(seconds=ttl))
            .with_grants(grants)
        )
        return at.to_jwt()

    # ── Token endpoint (aiohttp) ──────────────────────────────────────────

    async def _start_token_server(self) -> None:
        """Embedded HTTP server: clients fetch room-scoped join tokens with a
        shared key (LiveKit secret never leaves the server). Disabled (not
        started) when MATE_VOICE_CLIENT_KEY is empty. Idempotent."""
        if self._token_runner is not None:
            return
        if not self.settings.client_key:
            log.warning("mate_voice: token endpoint KAPALI (MATE_VOICE_CLIENT_KEY boş)")
            return
        try:
            from aiohttp import web
        except Exception as e:
            log.warning("mate_voice: aiohttp yok, token endpoint atlandı: %r", e)
            return

        app = web.Application()
        app.router.add_get("/mate/health", self._handle_health)
        app.router.add_get("/mate/token", self._handle_token)
        app.router.add_get("/mate/demo-token", self._handle_demo_token)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, self.settings.token_bind, self.settings.token_port)
        try:
            await site.start()
        except Exception as e:
            log.warning("mate_voice: token endpoint başlatılamadı (%s:%s): %r",
                        self.settings.token_bind, self.settings.token_port, e)
            try:
                await runner.cleanup()
            except Exception:
                pass
            return
        self._token_runner = runner
        log.info("mate_voice: token endpoint AÇIK http://%s:%s/mate/token",
                 self.settings.token_bind, self.settings.token_port)

    async def _stop_token_server(self) -> None:
        runner, self._token_runner = self._token_runner, None
        if runner is not None:
            try:
                await runner.cleanup()
            except Exception:
                pass

    async def _handle_health(self, request):
        from aiohttp import web
        return web.json_response({
            "status": "ok",
            "room": self.room_name,
            "connected": bool(self._connected),
            "url": self.settings.public_livekit_url,
        })

    async def _handle_token(self, request):
        from aiohttp import web
        import hmac

        key = request.headers.get("X-Mate-Key", "")
        if not (self.settings.client_key and hmac.compare_digest(key, self.settings.client_key)):
            return web.json_response({"error": "unauthorized"}, status=401)
        identity = (request.query.get("identity") or "").strip()
        if not identity:
            return web.json_response({"error": "identity required"}, status=400)
        room = (request.query.get("room") or "").strip() or self.room_name
        try:
            token = self._mint_client_token(identity, room)
        except Exception as e:
            log.warning("mate_voice: token mint hatası: %r", e)
            return web.json_response({"error": "mint failed"}, status=500)
        log.info("mate_voice: token verildi identity=%s room=%s", identity, room)
        return web.json_response({
            "url": self.settings.public_livekit_url,
            "room": room,
            "token": token,
            "identity": identity,
        })

    async def _handle_demo_token(self, request):
        """AÇIK (key'siz) onboarding token'ı: sihirbazın sıfır-konfig demo bağlantısı.
        Onboarding odası, kısa TTL. Anahtar GEREKMEZ → yalnız onboarding odasına ve
        kısa TTL'e scope'lanır. Kapatmak için MATE_VOICE_DEMO_TOKEN_ENABLED=0.

        Opsiyonel `identity` query'si: istemci kendi STABİL cihaz-kimliğini geçerse
        onu kullanırız (speaker-ID + kişiye-özel oturum reconnect'ler arası tutarlı
        kalsın → sihirbaz sonrası key'siz kalıcı bağlantı). Yoksa rastgele guest."""
        from aiohttp import web
        import uuid

        if not self.settings.demo_token_enabled:
            return web.json_response({"error": "demo token disabled"}, status=403)
        room = self.settings.onboarding_room
        identity = (request.query.get("identity") or "").strip() or ("onboard-" + uuid.uuid4().hex[:10])
        try:
            token = self._mint_client_token(
                identity, room, ttl_seconds=self.settings.demo_token_ttl_seconds
            )
        except Exception as e:
            log.warning("mate_voice: demo-token mint hatası: %r", e)
            return web.json_response({"error": "mint failed"}, status=500)
        log.info("mate_voice: demo-token verildi identity=%s room=%s ttl=%ds",
                 identity, room, self.settings.demo_token_ttl_seconds)
        return web.json_response({
            "url": self.settings.public_livekit_url,
            "room": room,
            "token": token,
            "identity": identity,
            "onboarding": True,
        })

    # ── Connection lifecycle ──────────────────────────────────────────────

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        """Public entry: ensure the room exists with a long empty_timeout, then
        join + publish. Marks _want_connected so an unexpected drop triggers
        _reconnect_loop (durable presence; B'nin testi için ajan odada kalır)."""
        if not self.settings.livekit_api_secret:
            log.error("mate_voice: LIVEKIT_API_SECRET boş — bağlanılamaz")
            self._set_fatal_error("config_missing", "LIVEKIT_API_SECRET missing", retryable=False)
            return False
        self._want_connected = True
        self._ensure_home_channel()  # sessiz auto-sethome ("no home channel" ipucunu önler)
        await self._load_speakers()  # enrolled kişileri belleğe al (varsa)
        await self._start_token_server()  # bağımsız; oda reconnect'lerinden etkilenmez
        await self._ensure_room()
        return await self._open_room()

    def _ensure_home_channel(self) -> None:
        """Sessiz auto-sethome (yuanbao kalıbı): MATE_HOME_CHANNEL boşsa odayı home
        channel yap. Böylece Hermes'in 'no home channel is set' ipucu çıkmaz VE
        proaktif teslim (cron/hatırlatma) için bir hedef oluşur. Origin'e (oturum
        chat_id'sine) giden kişiye-özel teslimler bundan etkilenmez; bu sadece
        sahipsiz/fallback teslimler için. env (bu çalışma) + config.yaml (kalıcı)."""
        import os

        if os.getenv("MATE_HOME_CHANNEL"):
            return
        os.environ["MATE_HOME_CHANNEL"] = self.room_name
        try:
            from hermes_constants import get_hermes_home
            from utils import atomic_yaml_write
            import yaml

            cfg = get_hermes_home() / "config.yaml"
            data: dict = {}
            if cfg.exists():
                with open(cfg, encoding="utf-8") as f:
                    data = yaml.safe_load(f) or {}
            if data.get("MATE_HOME_CHANNEL") != self.room_name:
                data["MATE_HOME_CHANNEL"] = self.room_name
                atomic_yaml_write(cfg, data)
            log.info("mate_voice: auto-sethome → home channel = %s", self.room_name)
        except Exception as e:
            log.warning("mate_voice: auto-sethome config yazılamadı (env set edildi): %r", e)

    async def _load_speakers(self) -> None:
        """Enrolled speaker'ları DB'den SpeakerID belleğine yükle. Speaker-ID
        kapalı / store yoksa no-op. Hatada fail-open (guest moduna düşer)."""
        if self.speaker is None or self.speaker_store is None:
            return
        try:
            speakers = await self.speaker_store.all_speaker_embeddings()
            self.speaker.reload(speakers)
            log.info("mate_voice: %d enrolled speaker yüklendi", len(speakers))
        except Exception as e:
            log.warning("mate_voice: speaker reload başarısız: %r", e)

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
            log.info("mate_voice: oda hazır (empty_timeout=24h): %s", self.room_name)
        except Exception as e:
            log.warning("mate_voice: create_room atlandı (%r)", e)
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
                log.info("mate_voice: ses track'i abone (%s)", participant.identity)
                self._start_consume(rtc, track, participant)

        @room.on("participant_attributes_changed")
        def _on_attrs_changed(changed_attributes, participant):
            ident = getattr(participant, "identity", None)
            if not ident or ident == "assistant":
                return
            try:
                changed = dict(changed_attributes or {})
                prev = self._attr_cache.get(ident, {}).get("mate.awake")
                new_awake = changed.get("mate.awake")
                if new_awake == "1" and prev == "0":
                    self._wake_at = time.monotonic()
                elif new_awake == "0":
                    self._wake_at = 0.0
                if "mate.barge_in" in changed:
                    self._barge_in_enabled = changed["mate.barge_in"] != "0"
                self._attr_cache.setdefault(ident, {}).update(changed)
            except Exception:
                pass
            log.info("mate_voice: attrs değişti (%s): %r", ident, changed_attributes)

        @room.on("disconnected")
        def _on_disconnected(reason):
            log.warning("mate_voice: odadan koptu (%s)", reason)
            self._connected = False
            # Kasıtlı kapatma (disconnect()) değilse otomatik yeniden bağlan.
            if self._want_connected and not self._reconnecting:
                try:
                    self._reconnect_task = asyncio.create_task(self._reconnect_loop())
                except RuntimeError:
                    pass

        self._attr_cache = {}
        self._greeted_speakers = set()
        self._barge_in_enabled = True
        self._wake_at = 0.0

        token = self._mint_token()
        await room.connect(self.settings.livekit_url, token)
        log.info("mate_voice: '%s' odasına bağlandı (%s)",
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
                        log.info("mate_voice: yeniden bağlandı")
                        break
                except Exception as e:
                    log.warning("mate_voice: reconnect denemesi başarısız: %r", e)
                delay = min(delay * 1.5, 15.0)
        finally:
            self._reconnecting = False

    async def disconnect(self) -> None:
        """Cancel consume/TTS tasks, stop reconnect + token server, leave room."""
        self._want_connected = False
        self._connected = False
        await self._stop_token_server()
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
                    utterance_awake = attrs.get("mate.awake", "1") != "0"
                    engine_name, stt_host, stt_port = self.settings.resolve_stt_engine(
                        attrs.get("stt_engine")
                    )
                    language = attrs.get("language") or self.settings.stt_language
                    stt = WhisperSession(stt_host, stt_port, language)
                    log.info("mate_voice: STT=%s (%s:%s) dil=%s",
                             engine_name, stt_host, stt_port, language or "(auto)")
                    try:
                        await stt.start(rate=STT_RATE, width=STT_WIDTH, channels=STT_CHANNELS)
                    except (ConnectionError, OSError) as e:
                        log.warning("mate_voice: STT erişilemiyor: %s", e)
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
                        log.warning("mate_voice: utterance işleme 60sn aştı, atlandı")
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("mate_voice: track tüketimi bitti (%s)", e)
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
            log.info("mate_voice: speaker-ID %s (%.3f)", name or "unknown", score)
            return name, emb
        except Exception as e:
            log.warning("mate_voice: speaker-ID failed: %s", e)
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
            log.warning("mate_voice: STT başarısız: %s", e)
            return
        log.info("mate_voice: duyuldu %r", text)
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
            log.info("mate_voice: %s, atlandı: %r", reason, text[:60])
            self._set_agent_state("idle")
            return
        if text and looks_hallucinated(text):
            log.info("mate_voice: transcript hayalet, atlanıyor: %r", text[:80])
            text = ""
        if not text:
            return

        speaker, emb = await self._identify(pcm)
        speaker_id = self.speaker.id_for(speaker) if (self.speaker and speaker) else None

        # Recognize-first oto-enrollment: speaker-ID + store AÇIK ve ses TANINMADI.
        # Bilinmeyen ses → isim sor (1. tur), isim utterance'ı → enroll + bekletilen
        # isteği işle (2. tur). Tanınan ses bu daldan geçmez → normal dispatch.
        if self.speaker is not None and self.speaker_store is not None and speaker_id is None:
            if self._pending_enroll is not None:
                await self._complete_enrollment(text, emb, participant, track)
            else:
                await self._begin_enrollment(text, emb, participant)
            return

        await self._dispatch_turn(text, speaker, speaker_id, participant, track)

    async def _dispatch_turn(self, text, speaker, speaker_id, participant, track) -> None:
        """Bir turu Hermes'e ver: aktif-konuşmacı UI + kullanıcı transkripti +
        MessageEvent → handle_message. (Asistan satırı send()'te yayınlanır.)"""
        # Tanınan kişiye bu bağlantıda BİR KEZ selam — SABİT metin değil: Hermes'e
        # bir DİREKTİF geçeriz (ismiyle, doğal, her sefer farklı; hafızadaki
        # selamlama tercihine uy), selamın metnini AGENT üretir. Direktif sadece
        # Hermes'e gider; transkript UI'ına temiz kullanıcı metni yayınlanır.
        hermes_text = text
        if speaker_id is not None and speaker_id not in self._greeted_speakers:
            self._greeted_speakers.add(speaker_id)
            en = self._is_en(self._attrs(participant).get("language"))
            hermes_text = self._greet_directive(speaker, en) + "\n\n" + text
        self._publish_speaker(speaker, speaker_id, guest=(speaker_id is None))
        human_track_sid = getattr(track, "sid", None)
        asyncio.create_task(self._publish_text(text, track_sid=human_track_sid, role="user"))

        # speaker-ID → session scope. Recognized → per-user; guest → DEVICE
        # scope (LiveKit participant identity). NOT None: Hermes authz
        # (authz_mixin `if not user_id: return False`) reddeder ve allow-all
        # bayrağına BİLE ulaşamaz → user_id'siz turn sessizce düşer. Katılımcı
        # kimliği stabil cihaz-kullanıcısı verir; MATE_VOICE_ALLOW_ALL_USERS=true
        # ile yetkilenir. Tanınan kişi user_id'yi override eder.
        # S4 — per-user oturum/geçmiş: TANINAN kişiye per-user chat_id ver →
        # build_session_key (dm) chat_id'den kurulduğu için her kişi AYRI Hermes
        # oturumu+geçmişi alır (kişiye özel "beni hatırla"). Hermes PROFİLLERİ
        # KULLANILMAZ (onlar davranış/model bağlamı içindir, kişi değil). chat_id
        # Hermes mantıksal kimliği; LiveKit odası (self._room) hep aynı — ses
        # yönlendirmesini etkilemez. Guest → paylaşımlı oda.
        if speaker_id:
            user_id, user_name = str(speaker_id), speaker
            chat_id = f"{self.room_name}:{speaker_id}"
        else:
            pid = getattr(participant, "identity", None) or "guest"
            user_id, user_name = f"voice:{pid}", pid
            chat_id = self.room_name
        source = self.build_source(
            chat_id=chat_id,
            chat_name=self.room_name,
            chat_type="dm",
            user_id=user_id,
            user_name=user_name,
        )
        self._set_agent_state("thinking")
        await self.handle_message(MessageEvent(
            text=hermes_text, message_type=MessageType.TEXT, source=source,
            message_id=str(int(time.time() * 1000)),
        ))

    # ── Recognize-first oto-enrollment ─────────────────────────────────────

    @staticmethod
    def _is_en(language) -> bool:
        return (language or "").lower().startswith("en")

    @staticmethod
    def _greet_directive(name: str, en: bool) -> str:
        """Tanınan kişinin oturumdaki İLK mesajına eklenen DİREKTİF (sabit selam
        DEĞİL): Hermes selamın metnini kendi üretir — ismiyle, doğal, her sefer
        farklı, hafızadaki selamlama tercihine uyarak. Sadece günün vakti + isim
        bağlamı verilir. NOT: sunucu yerel saati (TZ farkıysa ileride istemci TZ'i)."""
        h = time.localtime().tm_hour
        if en:
            part = ("morning" if 5 <= h < 12 else "afternoon" if 12 <= h < 18
                    else "evening" if 18 <= h < 22 else "night")
            return (f"(System note: {name} just connected (~{h:02d}:00, {part}); this is their first "
                    f"message this session. Before answering, greet them by name — short, natural and "
                    f"different each time; if your memory has any greeting instruction/preference, follow "
                    f"it. Then answer their message.)")
        part = ("sabah" if 5 <= h < 12 else "öğleden sonra" if 12 <= h < 18
                else "akşam" if 18 <= h < 22 else "gece")
        return (f"(Sistem notu: {name} az önce bağlandı (~{h:02d}:00, {part}); bu, bu oturumdaki ilk "
                f"mesajı. Yanıtlamadan önce ona ismiyle KISA, doğal ve her seferinde FARKLI bir selam "
                f"ver; hafızanda selamlamayla ilgili bir talimat/tercih varsa ona uy. Sonra mesajını yanıtla.)")

    @staticmethod
    def _parse_name(text: str) -> Optional[str]:
        """Kısa isim çıkar: 'Ben Ali', 'Adım Ali', 'My name is Ali', 'Ali'. İlk 1-2
        kelimeyi isim say; dolgu öneklerini at. Harf yoksa None."""
        import re

        t = (text or "").strip().strip(".!?,").strip()
        low = t.lower()
        for p in ("benim adım", "adım", "ben ", "my name is", "i am ", "i'm ",
                  "it's ", "it is ", "im "):
            if low.startswith(p):
                t = t[len(p):].strip()
                break
        words = [w for w in re.split(r"\s+", t) if w][:2]
        name = " ".join(words).strip(".!?,")
        if not name or not any(c.isalpha() for c in name):
            return None
        return name[:40].title()

    async def _enroll_say(self, text: str, participant=None) -> None:
        """Enrollment alt-akışı asistan satırı: transcript + TTS (await → sıralı).
        Sohbet history'sine YAZMAZ (Hermes'e gitmez; meta konuşma)."""
        asyncio.create_task(
            self._publish_text(text, track_sid=self._pub_track_sid, role="assistant")
        )
        await self._speak(text, self._attrs(participant).get("voice") or None)

    async def _begin_enrollment(self, text, emb, participant) -> None:
        """1. TUR: bilinmeyen ses → orijinal isteği BEKLET, ismi sor (TR; EN fallback)."""
        self._pending_enroll = {"text": text, "emb": emb}
        en = self._is_en(self._attrs(participant).get("language"))
        ask = "I don't recognize you. What's your name?" if en else "Seni tanımıyorum, adın ne?"
        log.info("mate_voice: enrollment — bilinmeyen ses, isim soruluyor (held=%r)", text[:40])
        self._publish_speaker(None, None, guest=True)
        await self._enroll_say(ask, participant)

    async def _complete_enrollment(self, name_text, name_emb, participant, track) -> None:
        """2. TUR: isim utterance'ı → kişi oluştur + örnek(ler) ekle + reload, sonra
        'Memnun oldum {name}' + BEKLETİLEN isteği tanınan kullanıcı olarak işle.
        Fail-open: isim ayrıştırılamaz / DB hatası → guest olarak bekletilen isteğe dön."""
        pend = self._pending_enroll or {"text": "", "emb": None}
        self._pending_enroll = None
        en = self._is_en(self._attrs(participant).get("language"))
        name = self._parse_name(name_text)
        if not name:
            log.info("mate_voice: enrollment — isim ayrıştırılamadı (%r) → guest", name_text[:40])
            if pend.get("text"):
                await self._dispatch_turn(pend["text"], None, None, participant, track)
            return
        try:
            from .voice.speaker import emb_to_bytes

            rec = await self.speaker_store.create_speaker(name)
            sid = rec["id"]
            mid, dim = self.speaker.model_id, self.speaker.dim
            if pend.get("emb") is not None:
                await self.speaker_store.add_speaker_sample(
                    sid, emb_to_bytes(pend["emb"]), dim, mid, source="auto-enroll"
                )
            if name_emb is not None:
                await self.speaker_store.add_speaker_sample(
                    sid, emb_to_bytes(name_emb), dim, mid, source="auto-enroll"
                )
            await self._load_speakers()
            log.info("mate_voice: enrollment — %r kaydedildi (id=%s)", name, sid)
        except Exception as e:
            log.warning("mate_voice: enrollment başarısız (%s) → guest fail-open", e)
            if pend.get("text"):
                await self._dispatch_turn(pend["text"], None, None, participant, track)
            return
        greet = f"Nice to meet you, {name}." if en else f"Memnun oldum {name}."
        self._publish_speaker(name, sid, guest=False)
        await self._enroll_say(greet, participant)
        # Yeni kayıt zaten "Memnun oldum" duydu → bu bağlantıda ayrıca "hoş geldin"
        # ile karşılama (çift selam olmasın).
        self._greeted_speakers.add(sid)
        # Bekletilen orijinal isteği şimdi TANINAN kullanıcı olarak işle (kullanıcı
        # tekrar etmek zorunda kalmasın). Held boşsa sadece selam yeter.
        if pend.get("text"):
            await self._dispatch_turn(pend["text"], name, sid, participant, track)

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
            log.warning("mate_voice: send/TTS hatası: %r", e)
            return SendResult(success=False, error=str(e))
        return SendResult(success=True, message_id=str(int(time.time() * 1000)))

    async def _speak(self, text: str, voice: Optional[str] = None) -> None:
        from livekit import rtc

        source = self._source
        if source is None:
            log.warning("mate_voice: TTS atlandı — yayın kaynağı yok")
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
            log.info("mate_voice: TTS iptal (barge-in)")
            try:
                source.clear_queue()
            except Exception:
                pass
            self._set_agent_state("listening")
            raise
        except Exception as e:
            log.warning("mate_voice: TTS başarısız: %r", e)
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
            attrs["mate.role"] = role
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
            log.warning("mate_voice: transcript yayınlanamadı (%s): %r", role, e)

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
                await room.local_participant.send_text(payload, topic="mate.speaker")
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
                await room.local_participant.send_text(line, topic="mate.debug")
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
                log.warning("mate_voice: agent-state ayarlanamadı (%s): %r", state, e)

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
        return SendResult(success=False, error="mate_voice: image delivery unsupported")

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
        logger.warning("mate_voice: livekit not importable — connect() will fail")
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
        label="LiveKit Voice",
        adapter_factory=lambda cfg: MateVoiceAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["LIVEKIT_URL", "LIVEKIT_API_SECRET"],
        install_hint="Needs livekit + numpy + onnxruntime + sherpa_onnx + transformers + wyoming",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="MATE_HOME_CHANNEL",
        allow_all_env="MATE_VOICE_ALLOW_ALL_USERS",
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

    # CLI: `hermes mate_voice reconfigure` — re-enter connection settings.
    # Registration is optional; older Hermes builds may lack the hook.
    register_cli = getattr(ctx, "register_cli_command", None)
    if register_cli is not None:
        def _setup(subparser):
            subparser.add_argument(
                "action",
                nargs="?",
                default="reconfigure",
                choices=["reconfigure"],
                help="reconfigure: bağlantı bilgilerini sorup .env'e yazar",
            )

        def _handler(args):
            # Lazy import so the voice stack (livekit/wyoming) is NOT loaded
            # on this path — reconfigure must work when audio deps are broken.
            from .voice.reconfigure import run_reconfigure
            return run_reconfigure(args)

        register_cli(
            "mate_voice",
            "mate_voice ses eklentisi komutları (reconfigure)",
            _setup,
            _handler,
        )
