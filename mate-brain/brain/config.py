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
    # Modüler STT: aynı Wyoming protokolünü konuşan birden çok motor, porta göre
    # drop-in. İstemci oturum başına motor seçebilir; seçmezse varsayılan kullanılır.
    # Varsayılan motor (whisper) stt_host/stt_port'u onurlandırır (geri-uyum).
    stt_default_engine: str = "whisper"
    stt_engines: dict[str, tuple[str, int]] = {
        "whisper": ("localhost", 10300),
        "nemotron": ("localhost", 10301),
    }
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
    # Kosinüs eşiği. Gerçek ev kayıtlarıyla kalibre (2026-06-16): doğru kişi
    # ~0.56–0.77, karşı taraf ~0.10–0.17 → 0.45 güvenli ve geniş paylı.
    speaker_threshold: float = 0.45
    speaker_margin: float = 0.05     # en iyi eşleşme 2.'yi bu kadar geçmezse unknown
    # En az bu kadar saniyelik konuşma yoksa speaker-ID denenmez (kısa/gürültü).
    speaker_min_seconds: float = 1.0

    # Zamanlı hatırlatmalar: vakti gelen görevleri yoklayan scheduler. Vakti
    # gelince araya girmeden chime çalar; teslim bir sonraki uyandırmada.
    reminder_enabled: bool = True
    reminder_poll_seconds: float = 20.0

    # Intent fast-path (vendored intent-lab classifier); needs
    # sentence-transformers installed, otherwise degrades to full agent path.
    intent_fastpath: bool = True

    # Oturum segmentasyonu (SessionSegmenter) — IDLE-BOUNDED ("konuşma öbeği").
    # session_sim_threshold ŞU AN KULLANILMIYOR: e5 multilingual-small Türkçe kısa
    # sözlerde konuyu ayırt edemedi (ölçüldü: alakasız sözler ~0.85 cosine, hiçbir
    # eşik çalışmadı) → per-turn embedding bölme kapatıldı. Daha iyi bir embedding
    # modeli gelirse segmentasyon buradan yeniden açılabilir.
    session_sim_threshold: float = 0.80
    # Oturum sınırı: bu kadar saniye sessizlik (son tur üstünden) → oturum kapanır
    # (Codex başlık/özet/açık-iş üretir) ve sonraki söz yeni oturum açar. 600 = 10 dk.
    # Env SESSION_IDLE_SECONDS ile override edilebilir (test için kısaltılabilir).
    session_idle_seconds: float = 600

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

    # LiveKit server-side agent (deneysel, flag arkasında). Kapalıyken (varsayılan)
    # main.py davranışı değişmez. Ses yolu mevcut Wyoming STT + agent.respond + TTS'i
    # yeniden kullanır; sadece taşıma katmanı LiveKit WebRTC olur.
    livekit_url: str = "ws://192.168.0.150:7880"
    livekit_api_key: str = "devkey"
    livekit_api_secret: str = ""       # boş = token üretilemez (endpoint 503, agent kapalı)
    livekit_room: str = "mate-demo"
    livekit_agent_enabled: bool = False
    livekit_token_ttl_seconds: int = 3600

    # Smart Turn v3 — SES-tabanlı konuşma-sonu (end-of-utterance) dedektörü.
    # Sabit sessizlik zamanlayıcısı yerine, konuşmacının GERÇEKTEN bitirip
    # bitirmediğini utterance sesinden tahmin eder → cümle ortası duraksamada
    # (özellikle Türkçe fiil-sonu) kullanıcıyı kesmez, tam düşüncede hemen biter.
    # Model: pipecat-ai/smart-turn-v3 (Whisper-tiny + lineer kafa, ~8MB ONNX, CPU,
    # BSD-2). Kapalıyken (varsayılan) eski saf-sessizlik endpointing kullanılır.
    # Deps (brain venv): onnxruntime, transformers, huggingface_hub.
    turn_detector_enabled: bool = False
    turn_detector_repo: str = "pipecat-ai/smart-turn-v3"
    turn_detector_file: str = "smart-turn-v3.2-cpu.onnx"
    # Tahmin eşiği: p >= eşik → tur tamamlandı. Model varsayılanı 0.5.
    turn_detector_threshold: float = 0.5

    def resolve_stt_engine(self, engine: str | None) -> tuple[str, str, int]:
        """(name, host, port) çöz. Bilinmeyen/eksik motor → varsayılan (whisper).
        Varsayılan motor için stt_host/stt_port'u kullanır (env override geri-uyumu)."""
        name = engine or self.stt_default_engine
        if name not in self.stt_engines:
            name = self.stt_default_engine
        if name == self.stt_default_engine:
            return name, self.stt_host, self.stt_port
        host, port = self.stt_engines[name]
        return name, host, port

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
