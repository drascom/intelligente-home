from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    brain_port: int = 8800
    brain_db_path: str = "brain.db"
    # Master token; also used by HA's conversation-agent integration as its API key.
    brain_admin_token: str = ""

    # "vllm" (prod: native tool loop against LLM_BASE_URL) or
    # "pi" (dev: delegate turns to the project-local pi agent / Codex sub)
    llm_backend: str = "vllm"
    llm_base_url: str = "http://localhost:8000/v1"
    llm_model: str = ""
    llm_temperature: float = 0.3
    pi_binary: str = "node_modules/.bin/pi"
    pi_model: str = "openai-codex/gpt-5.5"

    ha_url: str = "http://localhost:8123"
    ha_token: str = ""

    # Voice plane: brain drives satellites + STT/TTS directly (no HA in path)
    stt_host: str = "localhost"
    stt_port: int = 10300
    stt_language: str = ""
    # TTS engine: "vox" (VoxCPM2 bridge server, f32le 48k, vox/) or
    # "piper" (Wyoming, s16le 22k — also what HA's Voice PE path uses)
    tts_engine: str = "vox"
    tts_host: str = "localhost"
    tts_port: int = 10200
    vox_host: str = "localhost"
    vox_port: int = 8808
    vox_api_key: str = ""
    # e.g. "kitchen@192.168.1.50:10700,hall@192.168.1.51"
    satellites: str = ""

    # Speaker-ID (voice-ID): sherpa-onnx CAM++ embedding. Kapalı = kişi tanıma yok.
    # Model: models/campplus.onnx (mate-brain/models/README.md'den indir).
    speaker_id_enabled: bool = False
    speaker_model_path: str = "models/campplus.onnx"
    speaker_model_id: str = "campplus_zh_en_advanced_v1"  # tutarlılık kilidi etiketi
    speaker_threshold: float = 0.6   # kosinüs eşiği (ayar 0.5–0.65)
    speaker_margin: float = 0.05     # en iyi eşleşme 2.'yi bu kadar geçmezse unknown
    # En az bu kadar saniyelik konuşma yoksa speaker-ID denenmez (kısa/gürültü).
    speaker_min_seconds: float = 1.0

    # Intent fast-path (vendored intent-lab classifier); needs
    # sentence-transformers installed, otherwise degrades to full agent path.
    intent_fastpath: bool = True

    # MQTT node management plane (SYSTEM_PLAN Layer 2). Host boş = düzlem kapalı.
    # Dev: zigbee2mqtt sunucusundaki mosquitto (192.168.0.90), kullanıcı "brain".
    mqtt_host: str = ""
    mqtt_port: int = 1883
    mqtt_username: str = ""
    mqtt_password: str = ""
    # Node topic ağacı: <prefix>/<node_id>/status|telemetry|cmd
    mqtt_node_prefix: str = "nodes"
    # Bu saniyeden uzun süredir haber alınmayan node "stale" sayılır ve
    # API'de online=False döner (LWT tetiklenmeden crash eden node'lar için).
    node_offline_after: float = 90.0

    # FCM push (HTTP v1). Service-account JSON yolu; boş = dry-run (sadece log).
    fcm_credentials_path: str = ""

    # Dashboard SPA için CORS origin'leri (virgülle ayrık). Dev Vite varsayılanı.
    monitor_cors_origins: str = "http://localhost:5173,http://127.0.0.1:5173"

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
