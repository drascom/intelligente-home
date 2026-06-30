"""Interactive reconfigure for mate_voice connection settings.

Lets the user re-enter LiveKit / STT / VOX / token / client-key env values
after install, writing them to ~/.hermes/.env via Hermes config utils.

Kept dependency-light (no livekit/wyoming imports) so it runs even when the
voice stack is broken — which is exactly when reconfigure is needed.
"""

from __future__ import annotations

# (key, human label) in the order they are prompted.
FIELDS = [
    ("LIVEKIT_URL", "LiveKit URL (agent → server, ör. ws://127.0.0.1:7880)"),
    ("LIVEKIT_API_KEY", "LiveKit API key"),
    ("LIVEKIT_API_SECRET", "LiveKit API secret"),
    ("MATE_PUBLIC_LIVEKIT_URL", "Public LiveKit URL (client/app, wss://...)"),
    ("MATE_LIVEKIT_ROOM", "LiveKit oda adı"),
    ("STT_HOST", "STT host"),
    ("STT_PORT", "STT port"),
    ("STT_LANGUAGE", "STT dili (tr/en)"),
    ("VOX_HOST", "VOX (TTS) host"),
    ("VOX_PORT", "VOX (TTS) port"),
    ("TTS_ENGINE", "TTS motoru"),
    ("TURN_DETECTOR_ENABLED", "Turn detector (true/false)"),
    ("SPEAKER_ID_ENABLED", "Speaker-ID (true/false)"),
    ("SPEAKER_MODEL_PATH", "Speaker model yolu"),
    ("MATE_VOICE_TOKEN_PORT", "Token sunucu portu"),
    ("MATE_VOICE_ALLOW_ALL_USERS", "Tüm kullanıcılara izin (true/false)"),
    ("MATE_VOICE_CLIENT_KEY", "Client key (uygulama bağlantı anahtarı)"),
]

# Keys whose current value is masked when displayed.
SECRET_KEYS = {"LIVEKIT_API_SECRET", "MATE_VOICE_CLIENT_KEY"}


def _mask(value: str) -> str:
    """Show first 6 + last 4 chars of a secret, mask the middle."""
    if not value:
        return ""
    if len(value) <= 10:
        return "•" * len(value)
    return f"{value[:6]}…{value[-4:]}"


def run_reconfigure(args=None) -> int:
    """Prompt for each connection field; empty Enter keeps the current value.

    Returns 0 on success (also on clean Ctrl-C abort)."""
    # Lazy import: keep handler import-safe even if Hermes internals shift.
    from hermes_cli.config import get_env_value, save_env_value

    print("mate_voice — bağlantı bilgilerini yeniden yapılandır")
    print("Boş Enter = mevcut değeri koru. İptal: Ctrl-C\n")

    changed = 0
    try:
        for key, label in FIELDS:
            current = get_env_value(key) or ""
            shown = _mask(current) if key in SECRET_KEYS else current
            suffix = f" [{shown}]" if shown else " [boş]"
            new = input(f"{label}{suffix}: ").strip()
            if not new:
                continue
            save_env_value(key, new)
            changed += 1
    except KeyboardInterrupt:
        print("\nİptal edildi. Değişiklik yok." if changed == 0
              else f"\nİptal edildi. {changed} değer yazıldı.")
        return 0

    print(f"\n{changed} değer değişti.")
    if changed:
        print("Değişikliklerin etkili olması için gateway'i yeniden başlat:")
        print("  sudo systemctl restart hermes-gateway   (veya: hermes gateway restart)")
    return 0


def _print_qr(data: str) -> None:
    """data'yı terminal ASCII QR olarak bas. qrcode yoksa kurmayı dene; olmazsa
    atla (fail-open — düz-metin key zaten gösterildi, asla çökme).

    NOT: voice/config.py'deki _print_key_qr ile aynı mantık ama config'i import
    ETMEYİZ — config import-time'da _ensure_client_key() çalıştırıp eksik key'i
    ÜRETİRDİ; show-key sadece OKUMALI, üretmemeli."""
    try:
        import importlib.util
        if importlib.util.find_spec("qrcode") is None:
            try:
                from ._deps import _pip_install
                _pip_install(["qrcode"])
                importlib.invalidate_caches()
            except Exception:
                pass
        import qrcode
        qr = qrcode.QRCode(border=1)
        qr.add_data(data)
        qr.make(fit=True)
        print("  (mate-mac ile kamera/QR taransın):")
        qr.print_ascii()
    except Exception:
        pass  # QR atlandı; metin key yine de görünür


def run_show_key(args=None) -> int:
    """CLIENT_KEY + QR + özet bağlantı bilgisini tekrar göster (maskeleme YOK).

    Sadece OKUR — eksik key üretmez. Returns 0 her zaman (çökme yok)."""
    from hermes_cli.config import get_env_value

    key = (get_env_value("MATE_VOICE_CLIENT_KEY") or "").strip()
    if not key:
        print("CLIENT_KEY henüz üretilmemiş.")
        print("`hermes gateway restart` ile ilk başlatmada otomatik üretilir.")
        return 0

    print("mate_voice — client bağlantı kodu\n")
    print(f"MATE_VOICE_CLIENT_KEY: {key}")
    print("client (mate-mac) → 'X-Mate-Key' / Client Key alanına gir.")
    _print_qr(key)

    # Bağlantı için gereken özet (varsa)
    livekit = (get_env_value("MATE_PUBLIC_LIVEKIT_URL")
               or get_env_value("LIVEKIT_URL") or "").strip()
    room = (get_env_value("MATE_LIVEKIT_ROOM") or "").strip()
    port = (get_env_value("MATE_VOICE_TOKEN_PORT") or "8830").strip()
    print("\nBağlantı özeti:")
    if livekit:
        print(f"  LiveKit URL : {livekit}")
    if room:
        print(f"  Oda         : {room}")
    print(f"  Token portu : {port}")
    return 0
