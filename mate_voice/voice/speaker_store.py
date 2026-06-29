"""Plugin-local speaker (voice-ID) deposu — stdlib sqlite3, brain'den bağımsız.

`mate-brain/brain/db.py`'deki speakers + speaker_samples tablolarını mate_voice
plugin'ine PORT eder (Hermes çekirdeğine DOKUNMADAN; bkz. candan-voice-plugin-only).
Embedding'ler ham float32 little-endian BLOB; centroid/eşleştirme bellekte
`voice/speaker.py::SpeakerID`'de yapılır. `all_speaker_embeddings()` çıktısı
doğrudan `SpeakerID.reload(...)` formatındadır.

Senkron sqlite3 çağrıları `asyncio.to_thread` ile sarılır (aiosqlite deps'i
eklemeden event loop'u bloklamaz). Tek-yazar/az-trafik (ev) için yeterli.
"""

import asyncio
import os
import sqlite3
import time

_SCHEMA = """
CREATE TABLE IF NOT EXISTS speakers (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    user_id     INTEGER,            -- opsiyonel dış kullanıcı bağı
    dim         INTEGER,            -- embedding boyutu (sanity)
    model_id    TEXT,               -- embedding modeli kimliği (tutarlılık kilidi)
    sample_count INTEGER DEFAULT 0,
    enrolled_at REAL,
    updated_at  REAL
);
CREATE TABLE IF NOT EXISTS speaker_samples (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    speaker_id  INTEGER NOT NULL,
    embedding   BLOB NOT NULL,      -- float32 vektör baytları
    source      TEXT,
    created_at  REAL
);
CREATE INDEX IF NOT EXISTS idx_samples_speaker ON speaker_samples(speaker_id);
"""


def _default_db_path() -> str:
    env = os.getenv("MATE_VOICE_DB_PATH")
    if env:
        return env
    home = os.path.expanduser("~/.hermes/mate_voice")
    return os.path.join(home, "speakers.db")


class SpeakerStore:
    """Senkron çekirdek + async sarmalayıcılar. Kullanım: `await store.list_speakers()`."""

    def __init__(self, path: str | None = None):
        self.path = path or _default_db_path()
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self._init_sync()

    # ---- sync core ----

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_sync(self) -> None:
        conn = self._connect()
        try:
            conn.executescript(_SCHEMA)
            conn.commit()
        finally:
            conn.close()

    def _create_speaker(self, name: str, user_id: int | None) -> dict:
        conn = self._connect()
        try:
            cur = conn.execute(
                "INSERT INTO speakers (name, user_id, sample_count, enrolled_at)"
                " VALUES (?, ?, 0, ?)",
                (name, user_id, time.time()),
            )
            conn.commit()
            return {"id": cur.lastrowid, "name": name, "user_id": user_id}
        finally:
            conn.close()

    def _add_sample(self, speaker_id: int, embedding: bytes, dim: int,
                    model_id: str, source: str | None) -> int:
        now = time.time()
        conn = self._connect()
        try:
            cur = conn.execute(
                "INSERT INTO speaker_samples (speaker_id, embedding, source, created_at)"
                " VALUES (?, ?, ?, ?)",
                (speaker_id, embedding, source, now),
            )
            conn.execute(
                "UPDATE speakers SET"
                "  sample_count = (SELECT COUNT(*) FROM speaker_samples WHERE speaker_id = ?),"
                "  dim = COALESCE(dim, ?),"
                "  model_id = COALESCE(model_id, ?),"
                "  updated_at = ?"
                " WHERE id = ?",
                (speaker_id, dim, model_id, now, speaker_id),
            )
            conn.commit()
            return cur.lastrowid
        finally:
            conn.close()

    def _list_speakers(self) -> list[dict]:
        conn = self._connect()
        try:
            cur = conn.execute(
                "SELECT id, name, user_id, dim, model_id, sample_count, enrolled_at, updated_at"
                " FROM speakers ORDER BY id"
            )
            return [dict(r) for r in cur.fetchall()]
        finally:
            conn.close()

    def _embeddings(self, speaker_id: int) -> list[bytes]:
        conn = self._connect()
        try:
            cur = conn.execute(
                "SELECT embedding FROM speaker_samples WHERE speaker_id = ? ORDER BY id",
                (speaker_id,),
            )
            return [r["embedding"] for r in cur.fetchall()]
        finally:
            conn.close()

    def _all_with_embeddings(self) -> list[dict]:
        out = []
        for sp in self._list_speakers():
            sp = dict(sp)
            sp["embeddings"] = self._embeddings(sp["id"])
            out.append(sp)
        return out

    def _delete_speaker(self, speaker_id: int) -> None:
        conn = self._connect()
        try:
            conn.execute("DELETE FROM speaker_samples WHERE speaker_id = ?", (speaker_id,))
            conn.execute("DELETE FROM speakers WHERE id = ?", (speaker_id,))
            conn.commit()
        finally:
            conn.close()

    # ---- async wrappers ----

    async def create_speaker(self, name: str, user_id: int | None = None) -> dict:
        return await asyncio.to_thread(self._create_speaker, name, user_id)

    async def add_speaker_sample(self, speaker_id: int, embedding: bytes, dim: int,
                                 model_id: str, source: str | None = None) -> int:
        return await asyncio.to_thread(self._add_sample, speaker_id, embedding, dim, model_id, source)

    async def list_speakers(self) -> list[dict]:
        return await asyncio.to_thread(self._list_speakers)

    async def all_speaker_embeddings(self) -> list[dict]:
        """SpeakerID.reload(...) formatı: her kişi + tüm örnek embedding'leri (bytes)."""
        return await asyncio.to_thread(self._all_with_embeddings)

    async def delete_speaker(self, speaker_id: int) -> None:
        return await asyncio.to_thread(self._delete_speaker, speaker_id)
