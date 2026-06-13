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
"""


class Database:
    def __init__(self, path: str):
        self.path = path
        self._db: aiosqlite.Connection | None = None

    async def connect(self) -> None:
        self._db = await aiosqlite.connect(self.path)
        self._db.row_factory = aiosqlite.Row
        await self._db.executescript(SCHEMA)
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

    async def add_message(self, conversation_id: str, role: str, content: str) -> None:
        await self._db.execute(
            "INSERT INTO messages (conversation_id, role, content, created_at) VALUES (?, ?, ?, ?)",
            (conversation_id, role, content, time.time()),
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
