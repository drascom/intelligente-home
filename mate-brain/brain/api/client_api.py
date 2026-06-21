"""REST + WebSocket API for the brain's own clients (Flutter app, web client)."""

import json
import logging
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, WebSocket
from fastapi.websockets import WebSocketDisconnect
from pydantic import BaseModel

from brain.api.auth import admin_only, current_client
from brain.config import settings
from brain.monitor.bus import emit_turn

log = logging.getLogger("brain.api")

router = APIRouter(prefix="/api")


@router.get("/health")
async def health(request: Request):
    mirror = request.app.state.mirror
    nodes = getattr(request.app.state, "nodes", None)
    return {
        "status": "ok",
        "ha_connected": mirror.connected,
        "entities": len(mirror.states),
        "satellites": {
            s.name: s.connected for s in getattr(request.app.state, "satellites", [])
        },
        "mqtt_connected": nodes.connected if nodes else None,
    }


# ---- devices ----

@router.get("/areas")
async def areas(request: Request, client: dict = Depends(current_client)):
    return sorted(request.app.state.mirror.areas.values())


@router.get("/devices")
async def devices(
    request: Request,
    area: str | None = None,
    domain: str | None = None,
    client: dict = Depends(current_client),
):
    return request.app.state.mirror.list_entities(area, domain)


@router.get("/devices/{entity_id}")
async def device(
    entity_id: str, request: Request, client: dict = Depends(current_client)
):
    info = request.app.state.mirror.entity_info(entity_id)
    if info is None:
        raise HTTPException(404, "unknown entity")
    return info


@router.get("/voices")
async def voices(request: Request, client: dict = Depends(current_client)):
    """Available TTS voice profiles (vox engine; piper has a single voice)."""
    if settings.tts_engine != "vox":
        return [{"display_name": "Varsayılan", "filename": "default"}]
    import httpx

    headers = (
        {"Authorization": f"Bearer {settings.vox_api_key}"} if settings.vox_api_key else {}
    )
    try:
        async with httpx.AsyncClient(timeout=5) as http:
            resp = await http.get(
                f"http://{settings.vox_host}:{settings.vox_port}/v1/voices",
                headers=headers,
            )
            resp.raise_for_status()
            return resp.json()
    except Exception as e:
        raise HTTPException(503, f"vox unreachable: {e}")


# İstemcinin Ayarlar'da gösterdiği STT motoru listesi. Statik (config'ten);
# whisper varsayılan ve geri-uyum gereği hep ilk/işaretli.
STT_ENGINE_NAMES = {
    "whisper": "Whisper (faster-whisper)",
    "nemotron": "Nemotron 3.5 ASR",
}


@router.get("/stt-engines")
async def stt_engines(request: Request, client: dict = Depends(current_client)):
    """Seçilebilir STT motorları. Varsayılan (whisper) `default: true` ile işaretli."""
    default = settings.stt_default_engine
    out = []
    for eid in settings.stt_engines:
        entry = {"id": eid, "name": STT_ENGINE_NAMES.get(eid, eid)}
        if eid == default:
            entry["default"] = True
        out.append(entry)
    # Varsayılanı listenin başına al (istemci fallback'i ile tutarlı sıralama).
    out.sort(key=lambda e: e.get("default", False), reverse=True)
    return out


class ServiceCall(BaseModel):
    domain: str
    service: str
    entity_id: str | None = None
    data: dict | None = None


@router.post("/devices/service")
async def call_service(
    body: ServiceCall, request: Request, client: dict = Depends(current_client)
):
    try:
        await request.app.state.mirror.call_service(
            body.domain, body.service, body.data, body.entity_id
        )
    except ConnectionError as e:
        raise HTTPException(503, str(e))
    return {"ok": True}


# ---- chat ----

class ChatRequest(BaseModel):
    message: str
    conversation_id: str | None = None


@router.post("/chat")
async def chat(
    body: ChatRequest, request: Request, client: dict = Depends(current_client)
):
    db = request.app.state.db
    scope_key = body.conversation_id or f"client-{client['id']}"
    # Konu-tabanlı oturum segmentasyonu (devam/böl kararı içeride); yoksa legacy.
    seg = getattr(request.app.state, "segmenter", None)
    if seg is not None:
        session_id = await seg.resolve_session_for_turn(scope_key, None, body.message)
    else:
        session_id = await db.resolve_session(scope_key)
    history = await db.recent_messages(session_id)
    answer = await request.app.state.agent.respond(history, body.message)
    await db.add_message(session_id, "user", body.message)
    await db.add_message(session_id, "assistant", answer)
    emit_turn(getattr(request.app.state, "bus", None), scope_key, client["id"], body.message, answer)
    return {"conversation_id": scope_key, "reply": answer}


@router.websocket("/ws")
async def ws_chat(websocket: WebSocket):
    token = websocket.query_params.get("token") or ""
    app = websocket.app
    client = None
    if settings.brain_admin_token and token == settings.brain_admin_token:
        client = {"id": 0, "name": "admin"}
    else:
        client = await app.state.db.get_client_by_token(token)
    if client is None:
        await websocket.close(code=4401)
        return
    await websocket.accept()
    conv = f"client-{client['id']}"
    db = app.state.db
    # Announce yayını için kayıt (set yoksa oluştur — testlerde app çıplak gelir).
    if not hasattr(app.state, "ws_clients"):
        app.state.ws_clients = set()
    app.state.ws_clients.add(websocket)
    bus = getattr(app.state, "bus", None)
    if bus:
        bus.emit("client_connect", "ws", f"{client['name']} (ws) bağlandı",
                 payload={"transport": "ws"}, conversation_id=conv, client_id=client["id"])
    try:
        while True:
            raw = await websocket.receive_text()
            msg = json.loads(raw)
            if msg.get("type") != "chat" or not msg.get("text"):
                await websocket.send_json({"type": "error", "error": "expected {type:'chat', text}"})
                continue
            # Konu-tabanlı oturum segmentasyonu (devam/böl kararı içeride); yoksa legacy.
            seg = getattr(app.state, "segmenter", None)
            if seg is not None:
                session_id = await seg.resolve_session_for_turn(conv, None, msg["text"])
            else:
                session_id = await db.resolve_session(conv)
            history = await db.recent_messages(session_id)
            answer = await app.state.agent.respond(history, msg["text"])
            await db.add_message(session_id, "user", msg["text"])
            await db.add_message(session_id, "assistant", answer)
            emit_turn(bus, conv, client["id"], msg["text"], answer)
            await websocket.send_json({"type": "reply", "text": answer})
    except WebSocketDisconnect:
        pass
    finally:
        app.state.ws_clients.discard(websocket)
        if bus:
            bus.emit("client_disconnect", "ws", f"{client['name']} (ws) ayrıldı",
                     payload={"transport": "ws"}, conversation_id=conv, client_id=client["id"])


# ---- nodes (MQTT yönetim düzlemi) ----

@router.get("/nodes")
async def list_nodes(request: Request, client: dict = Depends(current_client)):
    """DB'deki kalıcı node kayıtları + canlı in-memory durum birleşik görünüm."""
    import time

    nodes = getattr(request.app.state, "nodes", None)
    persisted = await request.app.state.db.list_nodes()
    live = {n["node_id"]: n for n in nodes.snapshot()} if nodes else {}
    now = time.time()
    for row in persisted:
        row["online"] = bool(row["online"])
        # meta DB'de JSON string saklanıyor; tüketici için object'e çevir.
        if isinstance(row.get("meta"), str):
            try:
                row["meta"] = json.loads(row["meta"])
            except (json.JSONDecodeError, TypeError):
                pass
        # LWT tetiklenmeden crash eden node'u son temastan türeterek stale işaretle.
        row["stale"] = (now - row["last_seen"]) > settings.node_offline_after
        if row["stale"]:
            row["online"] = False
        row["telemetry"] = live.get(row["node_id"], {}).get("telemetry", {})
    return {
        "mqtt_connected": nodes.connected if nodes else None,
        "nodes": persisted,
    }


class NodeCommand(BaseModel):
    action: str
    data: dict | None = None


@router.post("/nodes/{node_id}/cmd")
async def node_command(
    node_id: str, body: NodeCommand, request: Request, _: dict = Depends(admin_only)
):
    nodes = getattr(request.app.state, "nodes", None)
    if nodes is None:
        raise HTTPException(503, "MQTT düzlemi kapalı (MQTT_HOST ayarlı değil)")
    try:
        await nodes.send_command(node_id, {"action": body.action, **(body.data or {})})
    except ConnectionError as e:
        raise HTTPException(503, str(e))
    return {"ok": True}


# ---- announce (cihazlar arası akış: satellites + WS istemcileri + push) ----

class Announcement(BaseModel):
    text: str
    voice: str | None = None       # şimdilik satellite yolunda kullanılmıyor
    title: str = "Candan"
    push: bool = True              # FCM push da gitsin mi


@router.post("/announce")
async def announce(
    body: Announcement, request: Request, _: dict = Depends(admin_only)
):
    """Anonsu her yere dağıt: bağlı satellite'lar sesli söyler, bağlı WS
    istemcileri {"type":"announce"} mesajı alır, kayıtlı telefonlara FCM
    push gider (yapılandırılmışsa)."""
    app = request.app
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "text boş")

    sats = getattr(app.state, "satellites", [])
    spoken = []
    if sats:
        import asyncio as _asyncio
        results = await _asyncio.gather(
            *(s.announce(text) for s in sats), return_exceptions=True
        )
        spoken = [s.name for s, ok in zip(sats, results) if ok is True]

    ws_sent = 0
    for ws in list(getattr(app.state, "ws_clients", set())):
        try:
            await ws.send_json({"type": "announce", "title": body.title, "text": text})
            ws_sent += 1
        except Exception:
            pass

    pushed = 0
    fcm = getattr(app.state, "fcm", None)
    if body.push and fcm is not None:
        clients = await app.state.db.clients_with_fcm()
        pushed = await fcm.broadcast(clients, body.title, text)

    bus = getattr(app.state, "bus", None)
    if bus:
        bus.emit("announce", "client_api", text,
                 payload={"title": body.title, "text": text, "satellites": spoken,
                          "ws_clients": ws_sent, "push_sent": pushed})

    return {"satellites": spoken, "ws_clients": ws_sent, "push_sent": pushed}


# ---- client registry (admin) ----

class NewClient(BaseModel):
    name: str


@router.post("/clients")
async def create_client(
    body: NewClient, request: Request, _: dict = Depends(admin_only)
):
    return await request.app.state.db.create_client(body.name)


@router.get("/clients")
async def list_clients(request: Request, _: dict = Depends(admin_only)):
    return await request.app.state.db.list_clients()


class FcmToken(BaseModel):
    fcm_token: str


@router.post("/clients/me/fcm")
async def set_fcm(
    body: FcmToken, request: Request, client: dict = Depends(current_client)
):
    if client["id"] == 0:
        raise HTTPException(400, "admin token has no client record")
    await request.app.state.db.set_fcm_token(client["id"], body.fcm_token)
    return {"ok": True}


# ---- LiveKit (deneysel; flag arkasında bir agent ile birlikte) ----

def _mint_livekit_token(identity: str, name: str) -> str:
    """Sunucu-taraflı LiveKit JWT üret. Secret .env'den gelir (asla istemciye
    sızmaz). livekit-api 1.x: AccessToken(key, secret).with_*(...).to_jwt()."""
    from livekit import api

    grants = api.VideoGrants(
        room_join=True,
        room=settings.livekit_room,
        can_publish=True,
        can_subscribe=True,
        # İstemci kendi attribute'larını set(attributes:) ile yazabilsin (candan.awake +
        # stt_engine/voice/language). Bu izin olmadan sunucu güncellemeyi reddeder →
        # brain'de attrs={} kalır (wake gate no-op + ayarlar etkisiz).
        can_update_own_metadata=True,
    )
    token = (
        api.AccessToken(settings.livekit_api_key, settings.livekit_api_secret)
        .with_identity(identity)
        .with_name(name)
        .with_ttl(timedelta(seconds=settings.livekit_token_ttl_seconds))
        .with_grants(grants)
    )
    return token.to_jwt()


@router.post("/livekit-token")
async def livekit_token(request: Request, client: dict = Depends(current_client)):
    """İstemciye LiveKit odasına katılmak için kısa-ömürlü JWT ver. Secret
    sunucuda kalır. LIVEKIT_API_SECRET ayarlı değilse 503 döner."""
    if not settings.livekit_api_secret:
        raise HTTPException(503, "LiveKit yapılandırılmamış (LIVEKIT_API_SECRET boş)")
    identity = f"client-{client['id']}"
    name = client.get("name") or identity
    return {
        "serverUrl": settings.livekit_url,
        "roomName": settings.livekit_room,
        "participantToken": _mint_livekit_token(identity, name),
        "participantName": name,
    }


@router.get("/livekit-token")
async def livekit_token_get(request: Request, client: dict = Depends(current_client)):
    return await livekit_token(request, client)
