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
