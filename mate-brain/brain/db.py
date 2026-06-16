"""SQLite persistence: client registry + conversation memory (SYSTEM_PLAN §3, Layer 3)."""

import secrets
import time

import aiosqlite

SCHEMA = """
CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    token TEXT NOT NULL UNIQUE,
    fcm_token TEXT,
    created_at REAL NOT NULL,
    last_seen REAL
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    speaker TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, id);
CREATE TABLE IF NOT EXISTS nodes (
    node_id TEXT PRIMARY KEY,
    kind TEXT,
    online INTEGER NOT NULL DEFAULT 0,
    version TEXT,
    meta TEXT,
    first_seen REAL NOT NULL,
    last_seen REAL NOT NULL
);
-- Speaker-ID (voice-ID): kayıtlı kişiler + ses örneği embedding'leri.
-- embedding'ler ham float32 little-endian baytlar olarak (BLOB) saklanır;
-- centroid/eşleştirme bellekte SpeakerID modülünde yapılır (bkz. voice/speaker.py).
CREATE TABLE IF NOT EXISTS speakers (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    user_id INTEGER,             -- ileride users tablosuna bağlanır (çok-kullanıcı)
    dim INTEGER,                 -- embedding boyutu (sanity)
    model_id TEXT,               -- embedding modeli kimliği (tutarlılık kilidi)
    sample_count INTEGER NOT NULL DEFAULT 0,
    enrolled_at REAL NOT NULL,
    updated_at REAL
);
CREATE TABLE IF NOT EXISTS speaker_samples (
    id INTEGER PRIMARY KEY,
    speaker_id INTEGER NOT NULL,
    embedding BLOB NOT NULL,     -- float32 vektör baytları
    source TEXT,                 -- 'mac' | 'ios' | 'satellite:salon' ...
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_speaker ON speaker_samples(speaker_id);
"""

# Eski DB'ler için additive migration'lar (CREATE TABLE IF NOT EXISTS sütun eklemez).
MIGRATIONS = [
    "ALTER TABLE messages ADD COLUMN speaker TEXT",
]


class Database:
    def __init__(self, path: str):
        self.path = path
        self._db: aiosqlite.Connection | None = None

    async def connect(self) -> None:
        self._db = await aiosqlite.connect(self.path)
        self._db.row_factory = aiosqlite.Row
        await self._db.executescript(SCHEMA)
        for stmt in MIGRATIONS:
            try:
                await self._db.execute(stmt)
            except Exception:
                pass  # sütun zaten var (yeni DB'lerde SCHEMA hallediyor)
        await self._db.commit()

    async def close(self) -> None:
        if self._db:
            await self._db.close()

    # ---- clients ----

    async def create_client(self, name: str) -> dict:
        token = secrets.token_urlsafe(32)
        cur = await self._db.execute(
            "INSERT INTO clients (name, token, created_at) VALUES (?, ?, ?)",
            (name, token, time.time()),
        )
        await self._db.commit()
        return {"id": cur.lastrowid, "name": name, "token": token}

    async def get_client_by_token(self, token: str) -> dict | None:
        cur = await self._db.execute("SELECT * FROM clients WHERE token = ?", (token,))
        row = await cur.fetchone()
        return dict(row) if row else None

    async def touch_client(self, client_id: int) -> None:
        await self._db.execute(
            "UPDATE clients SET last_seen = ? WHERE id = ?", (time.time(), client_id)
        )
        await self._db.commit()

    async def set_fcm_token(self, client_id: int, fcm_token: str) -> None:
        await self._db.execute(
            "UPDATE clients SET fcm_token = ? WHERE id = ?", (fcm_token, client_id)
        )
        await self._db.commit()

    async def list_clients(self) -> list[dict]:
        cur = await self._db.execute(
            "SELECT id, name, created_at, last_seen FROM clients ORDER BY id"
        )
        return [dict(r) for r in await cur.fetchall()]

    # ---- nodes (MQTT yönetim düzlemi) ----

    async def upsert_node(
        self,
        node_id: str,
        online: bool,
        kind: str | None = None,
        version: str | None = None,
        meta: str | None = None,
    ) -> None:
        now = time.time()
        await self._db.execute(
            """INSERT INTO nodes (node_id, kind, online, version, meta, first_seen, last_seen)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(node_id) DO UPDATE SET
                 online = excluded.online,
                 kind = COALESCE(excluded.kind, nodes.kind),
                 version = COALESCE(excluded.version, nodes.version),
                 meta = COALESCE(excluded.meta, nodes.meta),
                 last_seen = excluded.last_seen""",
            (node_id, kind, int(online), version, meta, now, now),
        )
        await self._db.commit()

    async def list_nodes(self) -> list[dict]:
        cur = await self._db.execute("SELECT * FROM nodes ORDER BY node_id")
        return [dict(r) for r in await cur.fetchall()]

    async def clients_with_fcm(self) -> list[dict]:
        cur = await self._db.execute(
            "SELECT id, name, fcm_token FROM clients WHERE fcm_token IS NOT NULL AND fcm_token != ''"
        )
        return [dict(r) for r in await cur.fetchall()]

    # ---- conversation memory ----

    async def add_message(
        self, conversation_id: str, role: str, content: str, speaker: str | None = None
    ) -> None:
        await self._db.execute(
            "INSERT INTO messages (conversation_id, role, content, speaker, created_at)"
            " VALUES (?, ?, ?, ?, ?)",
            (conversation_id, role, content, speaker, time.time()),
        )
        await self._db.commit()

    async def recent_messages(self, conversation_id: str, limit: int = 20) -> list[dict]:
        cur = await self._db.execute(
            "SELECT role, content FROM messages WHERE conversation_id = ?"
            " ORDER BY id DESC LIMIT ?",
            (conversation_id, limit),
        )
        rows = await cur.fetchall()
        return [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]

    # ---- speakers (voice-ID) ----

    async def create_speaker(self, name: str, user_id: int | None = None) -> dict:
        cur = await self._db.execute(
            "INSERT INTO speakers (name, user_id, sample_count, enrolled_at)"
            " VALUES (?, ?, 0, ?)",
            (name, user_id, time.time()),
        )
        await self._db.commit()
        return {"id": cur.lastrowid, "name": name, "user_id": user_id}

    async def add_speaker_sample(
        self, speaker_id: int, embedding: bytes, dim: int, model_id: str,
        source: str | None = None,
    ) -> int:
        """Bir enrollment örneği ekle; kişinin dim/model_id (ilk örnekte) ve
        sample_count/updated_at alanlarını güncelle. Örnek id döner."""
        now = time.time()
        cur = await self._db.execute(
            "INSERT INTO speaker_samples (speaker_id, embedding, source, created_at)"
            " VALUES (?, ?, ?, ?)",
            (speaker_id, embedding, source, now),
        )
        await self._db.execute(
            "UPDATE speakers SET"
            "  sample_count = (SELECT COUNT(*) FROM speaker_samples WHERE speaker_id = ?),"
            "  dim = COALESCE(dim, ?),"
            "  model_id = COALESCE(model_id, ?),"
            "  updated_at = ?"
            " WHERE id = ?",
            (speaker_id, dim, model_id, now, speaker_id),
        )
        await self._db.commit()
        return cur.lastrowid

    async def get_speaker(self, speaker_id: int) -> dict | None:
        cur = await self._db.execute(
            "SELECT id, name, user_id, dim, model_id, sample_count, enrolled_at, updated_at"
            " FROM speakers WHERE id = ?",
            (speaker_id,),
        )
        row = await cur.fetchone()
        return dict(row) if row else None

    async def list_speakers(self) -> list[dict]:
        cur = await self._db.execute(
            "SELECT id, name, user_id, dim, model_id, sample_count, enrolled_at, updated_at"
            " FROM speakers ORDER BY id"
        )
        return [dict(r) for r in await cur.fetchall()]

    async def speaker_embeddings(self, speaker_id: int) -> list[bytes]:
        cur = await self._db.execute(
            "SELECT embedding FROM speaker_samples WHERE speaker_id = ? ORDER BY id",
            (speaker_id,),
        )
        return [r["embedding"] for r in await cur.fetchall()]

    async def all_speaker_embeddings(self) -> list[dict]:
        """SpeakerID.reload için: her kişi + tüm örnek embedding'leri (bytes)."""
        speakers = await self.list_speakers()
        out = []
        for sp in speakers:
            sp = dict(sp)
            sp["embeddings"] = await self.speaker_embeddings(sp["id"])
            out.append(sp)
        return out

    async def delete_speaker(self, speaker_id: int) -> None:
        await self._db.execute("DELETE FROM speaker_samples WHERE speaker_id = ?", (speaker_id,))
        await self._db.execute("DELETE FROM speakers WHERE id = ?", (speaker_id,))
        await self._db.commit()

    async def delete_speaker_sample(self, speaker_id: int, sample_id: int) -> None:
        await self._db.execute(
            "DELETE FROM speaker_samples WHERE id = ? AND speaker_id = ?",
            (sample_id, speaker_id),
        )
        await self._db.execute(
            "UPDATE speakers SET"
            "  sample_count = (SELECT COUNT(*) FROM speaker_samples WHERE speaker_id = ?),"
            "  updated_at = ?"
            " WHERE id = ?",
            (speaker_id, time.time(), speaker_id),
        )
        await self._db.commit()
