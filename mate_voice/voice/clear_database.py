"""Clear mate_voice speaker database without requiring the sqlite3 CLI."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path


def _db_path() -> Path:
    configured = (os.getenv("MATE_VOICE_DB_PATH") or "").strip()
    if configured:
        return Path(configured).expanduser()
    return Path("~/.hermes/mate_voice/speakers.db").expanduser()


def _clear_database(path: Path) -> tuple[int, int]:
    if not path.exists():
        return 0, 0
    with sqlite3.connect(path) as conn:
        speaker_samples = conn.execute("SELECT COUNT(*) FROM speaker_samples").fetchone()[0]
        speakers = conn.execute("SELECT COUNT(*) FROM speakers").fetchone()[0]
        conn.execute("DELETE FROM speaker_samples")
        conn.execute("DELETE FROM speakers")
        conn.execute(
            "DELETE FROM sqlite_sequence WHERE name IN ('speakers', 'speaker_samples')"
        )
        conn.commit()
    return int(speakers), int(speaker_samples)


def run_clear_database(args=None) -> int:
    path = _db_path()
    print(f"mate_voice speaker DB: {path}")
    answer = input("Tüm kayıtlı sesleri silmek istiyor musunuz? [yes/no]: ").strip().casefold()
    if answer not in {"e", "evet", "y", "yes"}:
        print("İptal edildi.")
        return 0
    try:
        speakers, samples = _clear_database(path)
    except sqlite3.OperationalError as e:
        print(f"Veritabanı temizlenemedi: {e}")
        return 1
    except Exception as e:
        print(f"Veritabanı temizlenemedi: {e!r}")
        return 1
    print(f"Temizlendi: {speakers} speaker, {samples} sample.")
    print("Değişikliğin yüklenmesi için çalıştırın: sudo hermes gateway restart")
    return 0
