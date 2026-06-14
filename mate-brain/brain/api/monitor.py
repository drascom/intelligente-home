"""Dashboard canlı akış endpoint'i — `/api/monitor/*` (SYSTEM_PLAN: izleme düzlemi).

Braine gelip giden olayları (transcript, intent, HA tool çağrısı, MQTT node
olayları, announce, FCM) Server-Sent Events ile dashboard'a akıtır. Akış tek
yönlü olduğu için SSE seçildi: tarayıcı `EventSource`'u otomatik reconnect ve
`Last-Event-ID` desteğini bedavaya verir, ring buffer `id`'siyle birebir oturur.

Auth: admin token `?token=` query param ile (EventSource özel header
gönderemez; /api/voice ve /api/ws ile aynı desen).
"""

import asyncio
import json
import logging

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from brain.config import settings

log = logging.getLogger("brain.monitor")

router = APIRouter(prefix="/api")

KEEPALIVE_SECS = 15


def _admin_or_401(token: str) -> None:
    if not settings.brain_admin_token or token != settings.brain_admin_token:
        raise HTTPException(401, "admin token required")


def _sse(event: dict) -> str:
    # Named event (`event:`) KULLANMA: tarayıcı EventSource.onmessage yalnızca
    # isimsiz (default "message") olaylarda tetiklenir; named event'ler
    # addEventListener gerektirir. Tür zaten data payload'ında (event["type"]).
    return (
        f"id: {event['id']}\n"
        f"data: {json.dumps(event, ensure_ascii=False, default=str)}\n\n"
    )


@router.get("/monitor/recent")
async def monitor_recent(request: Request):
    """Akışsız 'son olaylar' görünümü — ring snapshot'ı düz JSON."""
    _admin_or_401(request.query_params.get("token") or "")
    bus = getattr(request.app.state, "bus", None)
    return {"events": bus.backlog() if bus else []}


@router.get("/monitor/stream")
async def monitor_stream(request: Request):
    """SSE: önce ring backfill, sonra canlı tail. 15 sn keepalive comment frame."""
    _admin_or_401(request.query_params.get("token") or "")
    bus = getattr(request.app.state, "bus", None)
    if bus is None:
        raise HTTPException(503, "event bus kapalı")

    async def gen():
        # Önce abone ol, SONRA backlog snapshot al: backfill sırasında üretilen
        # olaylar queue'ya düşer, en fazla tekrar id olur, asla boşluk olmaz.
        with bus.subscribe() as q:
            for event in bus.backlog():
                yield _sse(event)
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(q.get(), timeout=KEEPALIVE_SECS)
                    yield _sse(event)
                except asyncio.TimeoutError:
                    yield ": keepalive\n\n"

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
