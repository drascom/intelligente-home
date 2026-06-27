"""Whisper hallucination filter — vendored from brain/api/voice.py."""

WHISPER_PHANTOM_PHRASES = (
    "abone ol",
    "izlediğiniz için teşekkür",
    "iyi seyirler",
    "altyazı m.k",
    "dipnot",
)


def _normalize_tr(text: str) -> str:
    # Türkçe küçük-harf tuzağı: "İ".lower() → birleşik nokta U+0307 kalır.
    return text.lower().replace("̇", "")


def looks_hallucinated(text: str) -> bool:
    """Whisper'ın gürültüden uydurduğu metinleri yakala: bilinen hayalet altyazı
    kalıpları, takılı-plak tekrar, veya çok düşük kelime çeşitliliği."""
    norm = _normalize_tr(text)
    if any(p in norm for p in WHISPER_PHANTOM_PHRASES):
        return True
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
