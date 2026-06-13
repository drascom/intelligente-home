"""Bearer-token auth (SYSTEM_PLAN §4): the admin token from .env, plus
per-device tokens issued into the SQLite client registry."""

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from brain.config import settings

bearer = HTTPBearer(auto_error=False)

ADMIN = {"id": 0, "name": "admin"}


async def current_client(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> dict:
    if creds is None:
        raise HTTPException(401, "missing bearer token")
    token = creds.credentials
    if settings.brain_admin_token and token == settings.brain_admin_token:
        return ADMIN
    client = await request.app.state.db.get_client_by_token(token)
    if client is None:
        raise HTTPException(401, "invalid token")
    await request.app.state.db.touch_client(client["id"])
    return client


async def admin_only(client: dict = Depends(current_client)) -> dict:
    if client["id"] != 0:
        raise HTTPException(403, "admin token required")
    return client
