"""Modüler STT motor seçimi: config çözümleyici + varsayılan/geri-uyum.

Run: .venv/bin/python -m brain.tests.test_stt_engines
"""

from brain.config import Settings


def test_resolve_default_and_fallback() -> int:
    n = 0
    s = Settings()
    # Eksik/boş/None → varsayılan (whisper), stt_host/stt_port'u onurlandırır.
    assert s.resolve_stt_engine(None) == ("whisper", s.stt_host, s.stt_port); n += 1
    assert s.resolve_stt_engine("") == ("whisper", s.stt_host, s.stt_port); n += 1
    # Bilinmeyen motor → sessizce varsayılana düş (canlı turu asla kırma).
    assert s.resolve_stt_engine("bogus") == ("whisper", s.stt_host, s.stt_port); n += 1
    # Açık whisper de varsayılan yolu kullanır.
    assert s.resolve_stt_engine("whisper") == ("whisper", s.stt_host, s.stt_port); n += 1
    return n


def test_resolve_alternate_engine() -> int:
    n = 0
    s = Settings()
    name, host, port = s.resolve_stt_engine("nemotron")
    assert (name, host, port) == ("nemotron", "localhost", 10301), (name, host, port); n += 1
    return n


def test_default_engine_honors_env_override() -> int:
    n = 0
    # Varsayılan motor stt_host/stt_port'u kullanmalı (env ile değişebilir).
    s = Settings(stt_host="10.0.0.5", stt_port=19999)
    assert s.resolve_stt_engine(None) == ("whisper", "10.0.0.5", 19999); n += 1
    # Alternatif motor sabit haritadan gelir, override'dan etkilenmez.
    assert s.resolve_stt_engine("nemotron") == ("nemotron", "localhost", 10301); n += 1
    return n


def main() -> None:
    total = test_resolve_default_and_fallback()
    total += test_resolve_alternate_engine()
    total += test_default_engine_honors_env_override()
    print(f"test_stt_engines: {total} assertion OK")


if __name__ == "__main__":
    main()
