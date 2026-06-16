"""Görev (task) API'si — triage'ın "sonraya bırak" dalı.

Hem agent tool'ları (pi/vLLM) hem uygulamalar buradan görev oluşturur/listeler/
tamamlar. Görevler kişiye göre (user_id = tanınan speaker). current_client auth.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from brain.api.auth import current_client
from brain.monitor.bus import emit_turn  # noqa: F401  (ileride task event'i için)

log = logging.getLogger("brain.api.task")

router = APIRouter(prefix="/api/tasks")


class NewTask(BaseModel):
    text: str
    user_id: int | None = None
    session_id: int | None = None
    due_at: float | None = None


@router.post("")
async def create_task(body: NewTask, request: Request, _: dict = Depends(current_client)):
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "text boş")
    task = await request.app.state.db.create_task(
        text, user_id=body.user_id, session_id=body.session_id, due_at=body.due_at
    )
    bus = getattr(request.app.state, "bus", None)
    if bus:
        # conversation_id = turun scope_key'i (user-<id>) → dashboard'da tur kartına girer
        conv = f"user-{body.user_id}" if body.user_id is not None else None
        bus.emit("task", "task_api", text,
                 payload={"action": "create", **task},
                 conversation_id=conv, client_id=body.user_id)
    return task


@router.get("")
async def list_tasks(
    request: Request,
    user_id: int | None = None,
    status: str | None = None,
    _: dict = Depends(current_client),
):
    return await request.app.state.db.list_tasks(user_id=user_id, status=status)


@router.post("/{task_id}/complete")
async def complete_task(task_id: int, request: Request, _: dict = Depends(current_client)):
    if await request.app.state.db.get_task(task_id) is None:
        raise HTTPException(404, "görev yok")
    done = await request.app.state.db.complete_task(task_id)
    bus = getattr(request.app.state, "bus", None)
    if bus:
        bus.emit("task", "task_api", f"görev #{task_id} tamamlandı",
                 payload={"action": "complete", "id": task_id})
    return {"ok": done}


@router.delete("/{task_id}")
async def delete_task(task_id: int, request: Request, _: dict = Depends(current_client)):
    await request.app.state.db.delete_task(task_id)
    return {"ok": True}
