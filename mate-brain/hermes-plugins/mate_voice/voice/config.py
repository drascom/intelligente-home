"""Env-driven config shim for the vendored Mate voice modules.

The voice modules (tts/services/turn_detector/speaker) were lifted from
`mate-brain/brain/voice/` where they read `brain.config.settings`. Inside the
Hermes plugin there is no `brain` package, so this builds an equivalent
`settings` object from environment variables (same names as brain's .env, so a
stage deploy reuses the existing brain.env values).

Plain os.getenv — no pydantic dependency (keeps the Hermes venv install light).
"""

import os


def _f(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, "") or default)
    except (TypeError, ValueError):
        return default


def _i(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, "") or default)
    except (TypeError, ValueError):
        return default


def _b(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _s(name: str, default: str) -> str:
    return os.getenv(name) or default


class _Settings:
    """Mirror of the subset of brain.config.Settings the voice modules touch."""

    def __init__(self) -> None:
        # --- STT (Wyoming whisper) ---
        self.stt_host = _s("STT_HOST", "localhost")
        self.stt_port = _i("STT_PORT", 10300)
        self.stt_language = _s("STT_LANGUAGE", "")
        self.stt_default_engine = _s("STT_DEFAULT_ENGINE", "whisper")
        # Optional alt engine (nemotron) host:port — same Wyoming protocol.
        self.stt_engines = {
            "whisper": (self.stt_host, self.stt_port),
            "nemotron": (_s("STT_NEMOTRON_HOST", self.stt_host), _i("STT_NEMOTRON_PORT", 10301)),
        }

        # --- TTS (vox bridge / piper) ---
        self.tts_engine = _s("TTS_ENGINE", "vox")
        self.tts_host = _s("TTS_HOST", "localhost")
        self.tts_port = _i("TTS_PORT", 10200)
        self.vox_host = _s("VOX_HOST", "localhost")
        self.vox_port = _i("VOX_PORT", 8808)
        self.vox_api_key = _s("VOX_API_KEY", "")

        # --- Speaker-ID (CAM++ sherpa-onnx) ---
        self.speaker_id_enabled = _b("SPEAKER_ID_ENABLED", False)
        self.speaker_model_path = _s("SPEAKER_MODEL_PATH", "")
        self.speaker_model_id = _s("SPEAKER_MODEL_ID", "campplus_zh_en_advanced_v1")
        self.speaker_threshold = _f("SPEAKER_THRESHOLD", 0.45)
        self.speaker_margin = _f("SPEAKER_MARGIN", 0.05)
        self.speaker_min_seconds = _f("SPEAKER_MIN_SECONDS", 1.0)

        # --- Smart-turn v3 EOU ---
        self.turn_detector_enabled = _b("TURN_DETECTOR_ENABLED", True)
        self.turn_detector_repo = _s("TURN_DETECTOR_REPO", "pipecat-ai/smart-turn-v3")
        self.turn_detector_file = _s("TURN_DETECTOR_FILE", "smart-turn-v3.2-cpu.onnx")
        self.turn_detector_threshold = _f("TURN_DETECTOR_THRESHOLD", 0.5)
        self.turn_min_endpointing_delay = _f("TURN_MIN_ENDPOINTING_DELAY", 1.6)
        self.turn_max_endpointing_delay = _f("TURN_MAX_ENDPOINTING_DELAY", 6.0)
        self.turn_recheck_interval = _f("TURN_RECHECK_INTERVAL", 0.4)

        # --- LiveKit ---
        # MATE_LIVEKIT_ROOM lets the plugin join a SEPARATE room from brain's
        # agent (mate-demo) so the two don't collide. Falls back to LIVEKIT_ROOM.
        self.livekit_url = _s("LIVEKIT_URL", "ws://127.0.0.1:7880")
        self.livekit_api_key = _s("LIVEKIT_API_KEY", "devkey")
        self.livekit_api_secret = _s("LIVEKIT_API_SECRET", "")
        self.livekit_room = _s("MATE_LIVEKIT_ROOM", _s("LIVEKIT_ROOM", "mate-hermes-test"))
        self.livekit_token_ttl_seconds = _i("LIVEKIT_TOKEN_TTL_SECONDS", 3600)
        # Public LiveKit URL handed to CLIENTS via the token endpoint (clients
        # can't reach the agent's internal ws://127.0.0.1:7880). Falls back to
        # livekit_url if unset.
        self.public_livekit_url = _s("MATE_PUBLIC_LIVEKIT_URL", "") or self.livekit_url

        # --- Token endpoint (clients fetch room-scoped join tokens; secret stays
        #     on the server). Disabled if client_key is empty. ---
        self.token_port = _i("MATE_VOICE_TOKEN_PORT", 8830)
        self.token_bind = _s("MATE_VOICE_TOKEN_BIND", "0.0.0.0")
        self.client_key = _s("MATE_VOICE_CLIENT_KEY", "")
        # TTL for client tokens minted by the endpoint.
        self.client_token_ttl_seconds = _i("MATE_VOICE_CLIENT_TOKEN_TTL", 3600)

        # --- Onboarding (sihirbaz): açık /mate/demo-token rotası (key'siz, kısa
        #     ömürlü). onboarding_room boşsa ana odaya düşülür (agent zaten orada)
        #     → iki-oda (S3) gelene kadar demo işlevsel kalır. ---
        self.onboarding_room = _s("MATE_ONBOARDING_ROOM", "") or self.livekit_room
        self.demo_token_ttl_seconds = _i("MATE_VOICE_DEMO_TOKEN_TTL", 600)
        # Açık demo rotası güvenlik kapısı: varsayılan AÇIK; kapatmak için "0".
        self.demo_token_enabled = _b("MATE_VOICE_DEMO_TOKEN_ENABLED", True)

    def resolve_stt_engine(self, engine):
        """(name, host, port). Unknown/missing → default (whisper)."""
        name = engine or self.stt_default_engine
        if name not in self.stt_engines:
            name = self.stt_default_engine
        if name == self.stt_default_engine:
            return name, self.stt_host, self.stt_port
        host, port = self.stt_engines[name]
        return name, host, port


settings = _Settings()
