"""Oturum geçmişi + açık konular endpoint'leri — `/api/sessions/*`,
`/api/open-items/*` (SessionSegmenter'ın ürettiği oturumları/özetleri okuma).

Auth: monitor.py ile aynı desen — admin token `?token=` query param ile
(`settings.brain_admin_token`'a karşı). `db` request.app.state'ten alınır.

Ayrıca TEST/DIAGNOSTIK amaçlı `POST /api/debug/turn` (ses hattı olmadan düz
metinle tam tur sürerek segmentasyonu sınamak için)."""

import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from brain.config import settings
from brain.monitor.bus import emit_turn

log = logging.getLogger("brain.api.sessions")

router = APIRouter(prefix="/api")


def _admin_or_401(token: str) -> None:
    if not settings.brain_admin_token or token != settings.brain_admin_token:
        raise HTTPException(401, "admin token required")


def _int_or_none(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except ValueError:
        raise HTTPException(400, "user_id/limit sayı olmalı")


@router.get("/sessions")
async def list_sessions(request: Request):
    """Oturumlar (updated_at DESC) + turn_count. Opsiyonel user_id / limit."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    user_id = _int_or_none(request.query_params.get("user_id"))
    limit = _int_or_none(request.query_params.get("limit")) or 100
    return {"sessions": await db.list_sessions_detailed(user_id, limit)}


@router.get("/sessions/{session_id}")
async def get_session(session_id: int, request: Request):
    """Tek oturum + tüm turn'leri (kronolojik transkript)."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    session = await db.get_session(session_id)
    if session is None:
        raise HTTPException(404, "session not found")
    return {"session": session, "turns": await db.session_turns(session_id)}


@router.get("/open-items")
async def list_open_items(request: Request):
    """Açık konular (kind='open_question'). Opsiyonel user_id / status (varsayılan pending)."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    user_id = _int_or_none(request.query_params.get("user_id"))
    status = request.query_params.get("status") or "pending"
    return {"items": await db.list_open_items(user_id, status)}


@router.post("/open-items/{item_id}/resolve")
async def resolve_open_item(item_id: int, request: Request):
    """Açık konuyu çözüldü olarak işaretle (tasks.complete_task)."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    await db.complete_task(item_id)
    return {"ok": True}


# ---- konu thread'leri (topic-threaded memory) ----

@router.get("/topics")
async def list_topics(request: Request):
    """Konu thread'leri (updated_at DESC). Opsiyonel scope_key / status filtresi.

    `with_items=true` verilirse her konuya bağlı AÇIK (pending) işler de inline
    eklenir (`open_items`) → ses asistanı tek çağrıda konu + açık işleri okur."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    scope_key = request.query_params.get("scope_key") or None
    status = request.query_params.get("status") or None
    with_items = (request.query_params.get("with_items") or "").lower() in ("1", "true", "yes")
    topics = await db.list_topics(scope_key=scope_key, status=status)
    if with_items:
        # Küçük N+1 döngüsü: her konunun açık (pending) işlerini ekle.
        for topic in topics:
            topic["open_items"] = await db.topic_open_items(topic["id"], status="pending")
    return {"topics": topics}


@router.get("/topics/{topic_id}")
async def get_topic(topic_id: int, request: Request):
    """Tek konu thread'i + bağlı açık işleri."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    topic = await db.get_topic(topic_id)
    if topic is None:
        raise HTTPException(404, "topic not found")
    return {"topic": topic, "open_items": await db.topic_open_items(topic_id)}


# ---- TEST/DIAGNOSTIK: ses hattı olmadan düz metinle tam tur ----

class DebugTurn(BaseModel):
    scope_key: str
    text: str
    user_id: int | None = None


@router.post("/debug/turn")
async def debug_turn(body: DebugTurn, request: Request):
    """SADECE TEST/DIAGNOSTIK: ses hattı (STT/voice-ID/TTS) olmadan düz metinle
    tam bir turu sürer → segmenter + agent'ı çalıştırıp oturum segmentasyonunu
    incelemeye yarar. `_handle_utterance`'ın ses-dışı özünü taklit eder."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    agent = request.app.state.agent
    seg = request.app.state.segmenter

    session_id = await seg.resolve_session_for_turn(body.scope_key, body.user_id, body.text)
    history = await db.recent_messages(session_id)
    try:
        answer = await agent.respond(history, body.text, conversation_id=body.scope_key)
    except Exception as e:
        # LLM backend tökezlese bile segmentasyon sınanabilsin → session_id yine döner.
        log.warning("debug/turn: agent başarısız: %r", e)
        answer = "(agent error)"
    await db.add_message(session_id, "user", body.text)
    await db.add_message(session_id, "assistant", answer)
    emit_turn(request.app.state.bus, body.scope_key, None, body.text, answer)
    return {"session_id": session_id, "answer": answer}


@router.post("/debug/close-session/{session_id}")
async def debug_close_session(session_id: int, request: Request):
    """SADECE TEST/DIAGNOSTIK: idle beklemeden oturum kapanışını (konu yönlendirmesi
    dahil) SENKRON tetikler → testin hemen ardından konuları inceleyebilmesi için."""
    _admin_or_401(request.query_params.get("token") or "")
    db = request.app.state.db
    session = await db.get_session(session_id)
    if session is None:
        raise HTTPException(404, "session not found")
    if session.get("status") == "closed":
        return {"already_closed": True}
    # Gerçek kapatma pipeline'ını SENKRON çağır (arka plan task'ı değil).
    await request.app.state.segmenter._close_session(session, session.get("user_id"))
    return {"closed": session_id}
