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
    status TEXT NOT NULL DEFAULT 'active',  -- active = açık | closed = bitti (konu segmentasyonu)
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    ended_at REAL,              -- oturum kapanış anı (konu değişti / idle)
    summary TEXT,               -- kapanışta LLM özeti (1-2 cümle)
    centroid BLOB,              -- oturum gövdesinin koşan-ortalama embedding'i (float32 baytlar)
    embed_count INTEGER NOT NULL DEFAULT 0  -- centroid'e katkıda bulunan tur sayısı
);
CREATE INDEX IF NOT EXISTS idx_sessions_scope ON sessions(scope_key, status, updated_at);
-- Görevler (task): triage'ın "hemen cevaplama, sonraya bırak" dalı. Kişiye göre.
-- due_at dolu = zamanlı hatırlatma; scheduler vakti gelince chime çalar (notified_at),
-- kullanıcı uyandırınca bir sonraki turda teslim edilir (status=done).
CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY,
    user_id INTEGER,            -- speakers.id; NULL = bilinmeyen/cihaz
    session_id INTEGER,         -- görevin doğduğu oturum
    text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',  -- pending | done
    due_at REAL,                -- zamanlı hatırlatma anı (epoch); NULL = zamansız not
    notified_at REAL,           -- chime çalındığı an (vakti geldi, teslim bekliyor)
    created_at REAL NOT NULL,
    done_at REAL,
    kind TEXT NOT NULL DEFAULT 'reminder'  -- reminder = hatırlatma | open_question = açık konu/çözülmemiş soru
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
-- Kişi → en son konuştuğu cihaz (presence). Proaktif bildirimi (chime) doğru
-- cihaza yönlendirmek için. device_id = 'satellite:<ad>' | 'client:<id>'.
CREATE TABLE IF NOT EXISTS user_presence (
    user_id INTEGER PRIMARY KEY,   -- speakers.id (tanınan kişi)
    device_id TEXT NOT NULL,
    updated_at REAL NOT NULL
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
    "ALTER TABLE tasks ADD COLUMN notified_at REAL",
    # Konu-tabanlı oturum segmentasyonu + açık-konu takibi (yeni sütunlar).
    "ALTER TABLE sessions ADD COLUMN ended_at REAL",
    "ALTER TABLE sessions ADD COLUMN summary TEXT",
    "ALTER TABLE sessions ADD COLUMN centroid BLOB",
    "ALTER TABLE sessions ADD COLUMN embed_count INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'reminder'",
]

# Migration'lardan SONRA kurulacak index'ler (yeni eklenen sütunlara bağlı olanlar;
# SCHEMA içinde olursa eski DB'de "no such column" verir).
POST_MIGRATION_INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id)",
]

# Oturum okuma sütunları — centroid BLOB HARİÇ (binary float32, JSON serileştirilemez).
_SESSION_COLS = (
    "s.id, s.user_id, s.scope_key, s.title, s.status, s.created_at, "
    "s.updated_at, s.ended_at, s.summary, s.embed_count"
)


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

    async def client_with_fcm(self, client_id: int) -> dict | None:
        """Tek bir client'ın FCM token'ı (presence yönlendirmesi için). Token yoksa None."""
        cur = await self._db.execute(
            "SELECT id, name, fcm_token FROM clients"
            " WHERE id = ? AND fcm_token IS NOT NULL AND fcm_token != ''",
            (client_id,),
        )
        row = await cur.fetchone()
        return dict(row) if row else None

    # ---- presence: kişi → en son konuştuğu cihaz ----

    async def set_presence(self, user_id: int, device_id: str) -> None:
        now = time.time()
        await self._db.execute(
            "INSERT INTO user_presence (user_id, device_id, updated_at) VALUES (?, ?, ?)"
            " ON CONFLICT(user_id) DO UPDATE SET"
            " device_id = excluded.device_id, updated_at = excluded.updated_at",
            (user_id, device_id, now),
        )
        await self._db.commit()

    async def get_presence(self, user_id: int) -> str | None:
        cur = await self._db.execute(
            "SELECT device_id FROM user_presence WHERE user_id = ?", (user_id,)
        )
        row = await cur.fetchone()
        return row["device_id"] if row else None

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

    # ---- konu-tabanlı oturum segmentasyonu (SessionSegmenter destekleri) ----

    async def active_session(self, scope_key: str) -> dict | None:
        """scope_key için en güncel AKTİF (status='active') oturum; yoksa None.
        Segmenter'ın koşan-ortalama/idle kararı için centroid + embed_count döner."""
        cur = await self._db.execute(
            "SELECT id, scope_key, user_id, centroid, embed_count, summary,"
            "       created_at, updated_at, title"
            " FROM sessions WHERE scope_key = ? AND status = 'active'"
            " ORDER BY updated_at DESC LIMIT 1",
            (scope_key,),
        )
        row = await cur.fetchone()
        return dict(row) if row else None

    async def create_session(
        self, scope_key: str, user_id: int | None,
        centroid: bytes | None, embed_count: int,
    ) -> int:
        """Yeni AKTİF oturum aç (centroid + embed_count ile); id döner."""
        now = time.time()
        cur = await self._db.execute(
            "INSERT INTO sessions"
            " (user_id, scope_key, status, created_at, updated_at, centroid, embed_count)"
            " VALUES (?, ?, 'active', ?, ?, ?, ?)",
            (user_id, scope_key, now, now, centroid, embed_count),
        )
        await self._db.commit()
        return cur.lastrowid

    async def update_session_centroid(
        self, session_id: int, centroid: bytes, embed_count: int
    ) -> None:
        """Aynı konu devam ederken koşan-ortalama centroid'i + sayacı güncelle."""
        await self._db.execute(
            "UPDATE sessions SET centroid = ?, embed_count = ?, updated_at = ? WHERE id = ?",
            (centroid, embed_count, time.time(), session_id),
        )
        await self._db.commit()

    async def close_session(
        self, session_id: int, title: str | None, summary: str | None, ended_at: float
    ) -> None:
        """Oturumu kapat (konu değişti / idle): status='closed' + başlık/özet/kapanış anı."""
        await self._db.execute(
            "UPDATE sessions SET status = 'closed', title = ?, summary = ?,"
            "  ended_at = ?, updated_at = ? WHERE id = ?",
            (title, summary, ended_at, time.time(), session_id),
        )
        await self._db.commit()

    async def session_turns(self, session_id: int) -> list[dict]:
        """Oturumdaki tüm mesajlar, id ASC (kapanış özeti için kronolojik transkript)."""
        cur = await self._db.execute(
            "SELECT role, content, speaker, created_at FROM messages"
            " WHERE session_id = ? ORDER BY id ASC",
            (session_id,),
        )
        return [
            {"role": r["role"], "content": r["content"],
             "speaker": r["speaker"], "created_at": r["created_at"]}
            for r in await cur.fetchall()
        ]

    async def list_sessions_detailed(
        self, user_id: int | None = None, limit: int = 100
    ) -> list[dict]:
        """Oturumlar (updated_at DESC, opsiyonel user_id filtresi) + her birine
        turn_count = o oturuma ait mesaj sayısı. Tüm oturum sütunları + turn_count."""
        params: list = []
        where = ""
        if user_id is not None:
            where = " WHERE s.user_id = ?"
            params.append(user_id)
        params.append(limit)
        cur = await self._db.execute(
            # centroid BLOB DIŞTA: JSON serileştirilemez (binary float32 → 500).
            f"SELECT {_SESSION_COLS},"
            "  (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS turn_count"
            f" FROM sessions s{where} ORDER BY s.updated_at DESC LIMIT ?",
            params,
        )
        return [dict(r) for r in await cur.fetchall()]

    async def get_session(self, session_id: int) -> dict | None:
        """Tek oturum satırı (centroid HARİÇ tüm sütunlar + turn_count); yoksa None."""
        cur = await self._db.execute(
            # centroid BLOB DIŞTA (JSON serileştirilemez).
            f"SELECT {_SESSION_COLS},"
            "  (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS turn_count"
            " FROM sessions s WHERE s.id = ?",
            (session_id,),
        )
        row = await cur.fetchone()
        return dict(row) if row else None

    async def add_open_item(self, session_id: int, user_id: int | None, text: str) -> int:
        """Açık konu / çözülmemiş soru → tasks(kind='open_question', status='pending'). id döner."""
        now = time.time()
        cur = await self._db.execute(
            "INSERT INTO tasks (user_id, session_id, text, status, kind, created_at)"
            " VALUES (?, ?, ?, 'pending', 'open_question', ?)",
            (user_id, session_id, text, now),
        )
        await self._db.commit()
        return cur.lastrowid

    async def list_open_items(
        self, user_id: int | None = None, status: str = "pending"
    ) -> list[dict]:
        """Açık konular (kind='open_question'), opsiyonel user_id + status, created_at DESC."""
        clauses = ["kind = 'open_question'"]
        params: list = []
        if user_id is not None:
            clauses.append("user_id = ?"); params.append(user_id)
        if status:
            clauses.append("status = ?"); params.append(status)
        where = " WHERE " + " AND ".join(clauses)
        cur = await self._db.execute(
            "SELECT id, user_id, session_id, text, status, kind, created_at, done_at"
            f" FROM tasks{where} ORDER BY created_at DESC",
            params,
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

    async def clear_tasks(self, user_id: int | None = None) -> int:
        """Tüm görevleri (ya da bir kullanıcınınkileri) sil. Test kolaylığı için.
        Silinen satır sayısını döner."""
        if user_id is None:
            cur = await self._db.execute("DELETE FROM tasks")
        else:
            cur = await self._db.execute("DELETE FROM tasks WHERE user_id = ?", (user_id,))
        await self._db.commit()
        return cur.rowcount

    # ---- zamanlı hatırlatmalar (scheduler + proaktif bildirim) ----

    async def due_tasks(self, now: float) -> list[dict]:
        """Vakti gelmiş ama henüz chime çalınmamış zamanlı görevler (scheduler için)."""
        cur = await self._db.execute(
            "SELECT id, user_id, session_id, text, due_at FROM tasks"
            " WHERE status = 'pending' AND due_at IS NOT NULL"
            " AND due_at <= ? AND notified_at IS NULL ORDER BY due_at",
            (now,),
        )
        return [dict(r) for r in await cur.fetchall()]

    async def mark_task_notified(self, task_id: int) -> None:
        await self._db.execute(
            "UPDATE tasks SET notified_at = ? WHERE id = ?", (time.time(), task_id)
        )
        await self._db.commit()

    async def pending_deliveries(self, user_id: int) -> list[dict]:
        """Chime çalınmış ama henüz teslim edilmemiş hatırlatmalar (uyandırma sonrası
        teslim için): pending + notified_at dolu, bu kullanıcıya ait."""
        cur = await self._db.execute(
            "SELECT id, user_id, session_id, text, due_at, notified_at FROM tasks"
            " WHERE user_id = ? AND status = 'pending' AND notified_at IS NOT NULL"
            " ORDER BY due_at",
            (user_id,),
        )
        return [dict(r) for r in await cur.fetchall()]

    async def pending_deliveries_for_device(self, device_id: str) -> list[dict]:
        """Tanınmayan turda yedek: chime'ın gittiği cihaza (presence) ait kullanıcıların
        bekleyen teslimleri. Bu cihazda konuşan, presence'ı buraya işaret eden kişidir →
        speaker-ID o kısa turda tutmasa bile hatırlatma teslim edilsin."""
        cur = await self._db.execute(
            "SELECT t.id, t.user_id, t.session_id, t.text, t.due_at, t.notified_at"
            " FROM tasks t JOIN user_presence p ON p.user_id = t.user_id"
            " WHERE p.device_id = ? AND t.status = 'pending' AND t.notified_at IS NOT NULL"
            " ORDER BY t.due_at",
            (device_id,),
        )
        return [dict(r) for r in await cur.fetchall()]

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
