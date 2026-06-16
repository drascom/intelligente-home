"""SQLite persistence: client registry + conversation memory (SYSTEM_PLAN §3, Layer 3)."""

import json
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
    session_id INTEGER,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    speaker TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, id);
-- Oturumlar (session): konuşma hafızasının kapsamı. scope_key routing anahtarı:
--   tanınan kişi → 'user-<speakerId>' (cihazdan bağımsız süreklilik),
--   bilinmeyen/metin → 'client-<id>' | 'satellite-<ad>' (cihaz kapsamı).
-- Şimdilik scope başına 1 aktif oturum; ileride çok-oturum/başlık/geri-çağırma
-- (status/title alanları hazır) sadece "yeni oturum + listele" ile eklenir.
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,            -- speakers.id; NULL = bilinmeyen/cihaz kapsamı
    scope_key TEXT NOT NULL,
    title TEXT,                 -- ileride LLM auto-title
    status TEXT NOT NULL DEFAULT 'active',  -- active | archived (ileride pending/done)
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_scope ON sessions(scope_key, status, updated_at);
-- Görevler (task): triage'ın "hemen cevaplama, sonraya bırak" dalı. Kişiye göre.
-- Şimdilik kaydet/listele/tamamla; zamanlama/tetikleme/proaktif-bildirim sonraki katman.
CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,            -- speakers.id; NULL = bilinmeyen/cihaz
    session_id INTEGER,         -- görevin doğduğu oturum
    text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',  -- pending | done
    due_at REAL,                -- ileride zamanlı hatırlatma (şimdilik NULL)
    created_at REAL NOT NULL,
    done_at REAL
);
CREATE INDEX IF NOT EXISTS idx_tasks_user ON tasks(user_id, status, created_at);
-- İzleme olayları (dashboard geçmişi): bus olayları arka planda buraya yazılır
-- (emit yolu DIŞINDA). id = bus event id (zaman-tohumlu, monoton) → sayfalama +
-- tekilleştirme. Canlı akış değişmedi; bu sadece geriye gitme/restart sonrası geçmiş.
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts REAL NOT NULL,
    type TEXT NOT NULL,
    source TEXT,
    summary TEXT,
    payload TEXT,
    conversation_id TEXT,
    client_id INTEGER
);
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
    "ALTER TABLE messages ADD COLUMN session_id INTEGER",
]

# Migration'lardan SONRA kurulacak index'ler (yeni eklenen sütunlara bağlı olanlar;
# SCHEMA içinde olursa eski DB'de "no such column" verir).
POST_MIGRATION_INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id)",
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
        # Index'ler migration'dan SONRA: eski DB'de sütun ALTER ile eklendikten sonra.
        for stmt in POST_MIGRATION_INDEXES:
            await self._db.execute(stmt)
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

    # ---- sessions + conversation memory ----

    async def resolve_session(self, scope_key: str, user_id: int | None = None) -> int:
        """scope_key için en güncel AKTİF oturumun id'sini ver; yoksa oluştur.
        scope_key: tanınan kişi → 'user-<id>', bilinmeyen → 'client-<id>' vb."""
        cur = await self._db.execute(
            "SELECT id FROM sessions WHERE scope_key = ? AND status = 'active'"
            " ORDER BY updated_at DESC LIMIT 1",
            (scope_key,),
        )
        row = await cur.fetchone()
        if row:
            return row["id"]
        now = time.time()
        cur = await self._db.execute(
            "INSERT INTO sessions (user_id, scope_key, status, created_at, updated_at)"
            " VALUES (?, ?, 'active', ?, ?)",
            (user_id, scope_key, now, now),
        )
        await self._db.commit()
        return cur.lastrowid

    async def add_message(
        self, session_id: int, role: str, content: str, speaker: str | None = None
    ) -> None:
        now = time.time()
        # conversation_id NOT NULL → session-türevli değerle doldur (sorgular session_id ile).
        await self._db.execute(
            "INSERT INTO messages (conversation_id, session_id, role, content, speaker, created_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (f"session-{session_id}", session_id, role, content, speaker, now),
        )
        await self._db.execute(
            "UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id)
        )
        await self._db.commit()

    async def recent_messages(self, session_id: int, limit: int = 20) -> list[dict]:
        cur = await self._db.execute(
            "SELECT role, content FROM messages WHERE session_id = ?"
            " ORDER BY id DESC LIMIT ?",
            (session_id, limit),
        )
        rows = await cur.fetchall()
        return [{"role": r["role"], "content": r["content"]} for r in reversed(rows)]

    async def list_sessions(self, user_id: int | None = None) -> list[dict]:
        if user_id is None:
            cur = await self._db.execute("SELECT * FROM sessions ORDER BY updated_at DESC")
        else:
            cur = await self._db.execute(
                "SELECT * FROM sessions WHERE user_id = ? ORDER BY updated_at DESC", (user_id,)
            )
        return [dict(r) for r in await cur.fetchall()]

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

    # ---- monitor events (dashboard geçmişi) ----

    async def save_event(self, ev: dict) -> None:
        """Bir bus olayını kalıcılaştır (arka plan abonesi çağırır). id PK → dedup."""
        await self._db.execute(
            "INSERT OR IGNORE INTO events"
            " (id, ts, type, source, summary, payload, conversation_id, client_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (ev.get("id"), ev.get("ts"), ev.get("type"), ev.get("source"),
             ev.get("summary"),
             json.dumps(ev.get("payload") or {}, ensure_ascii=False),
             ev.get("conversation_id"), ev.get("client_id")),
        )
        await self._db.commit()

    async def history_events(self, before_id: int | None = None, limit: int = 100) -> list[dict]:
        """`before_id`'den eski olaylar (yoksa en yeniler), yeni→eski sırada."""
        if before_id:
            cur = await self._db.execute(
                "SELECT * FROM events WHERE id < ? ORDER BY id DESC LIMIT ?",
                (before_id, limit),
            )
        else:
            cur = await self._db.execute(
                "SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,)
            )
        out = []
        for r in await cur.fetchall():
            d = dict(r)
            try:
                d["payload"] = json.loads(d["payload"]) if d["payload"] else {}
            except (json.JSONDecodeError, TypeError):
                d["payload"] = {}
            out.append(d)
        return out

    # ---- tasks (triage'ın görev dalı) ----

    async def create_task(
        self, text: str, user_id: int | None = None, session_id: int | None = None,
        due_at: float | None = None,
    ) -> dict:
        now = time.time()
        cur = await self._db.execute(
            "INSERT INTO tasks (user_id, session_id, text, status, due_at, created_at)"
            " VALUES (?, ?, ?, 'pending', ?, ?)",
            (user_id, session_id, text, due_at, now),
        )
        await self._db.commit()
        return {"id": cur.lastrowid, "text": text, "status": "pending",
                "user_id": user_id, "due_at": due_at, "created_at": now}

    async def list_tasks(
        self, user_id: int | None = None, status: str | None = None
    ) -> list[dict]:
        clauses, params = [], []
        if user_id is not None:
            clauses.append("user_id = ?"); params.append(user_id)
        if status:
            clauses.append("status = ?"); params.append(status)
        where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        cur = await self._db.execute(
            f"SELECT id, user_id, session_id, text, status, due_at, created_at, done_at"
            f" FROM tasks{where} ORDER BY created_at DESC",
            params,
        )
        return [dict(r) for r in await cur.fetchall()]

    async def get_task(self, task_id: int) -> dict | None:
        cur = await self._db.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
        row = await cur.fetchone()
        return dict(row) if row else None

    async def complete_task(self, task_id: int) -> bool:
        cur = await self._db.execute(
            "UPDATE tasks SET status = 'done', done_at = ? WHERE id = ? AND status != 'done'",
            (time.time(), task_id),
        )
        await self._db.commit()
        return cur.rowcount > 0

    async def delete_task(self, task_id: int) -> None:
        await self._db.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
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
