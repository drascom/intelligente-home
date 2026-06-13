"""Live mirror of Home Assistant state over its WebSocket API (SYSTEM_PLAN §3, Layer 1).

On connect: pull area/device/entity registries + all states, then hold a
`state_changed` subscription so the in-memory model is always current.
Control goes back over the same socket via `call_service`.
"""

import asyncio
import itertools
import json
import logging

import websockets

log = logging.getLogger("brain.ha")

RECONNECT_DELAY = 5


class HAMirror:
    def __init__(self, url: str, token: str):
        self.ws_url = url.rstrip("/").replace("http", "ws", 1) + "/api/websocket"
        self.token = token
        self.connected = False

        self.states: dict[str, dict] = {}          # entity_id -> state object
        self.areas: dict[str, str] = {}            # area_id -> name
        self.entity_area: dict[str, str] = {}      # entity_id -> area_id
        self.entity_names: dict[str, str] = {}     # entity_id -> friendly/registry name

        self._ws = None
        self._msg_id = itertools.count(1)
        self._pending: dict[int, asyncio.Future] = {}

    async def run(self) -> None:
        """Reconnect-forever loop. Run as a background task."""
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("HA connection lost (%s); retrying in %ss", e, RECONNECT_DELAY)
            self.connected = False
            self._ws = None
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionError("HA connection lost"))
            self._pending.clear()
            await asyncio.sleep(RECONNECT_DELAY)

    async def _session(self) -> None:
        async with websockets.connect(self.ws_url, max_size=16 * 1024 * 1024) as ws:
            self._ws = ws
            await self._auth(ws)
            reader = asyncio.create_task(self._read_loop(ws))
            try:
                await self._bootstrap()
                self.connected = True
                log.info(
                    "HA mirror ready: %d entities, %d areas",
                    len(self.states), len(self.areas),
                )
                await reader
            finally:
                reader.cancel()

    async def _auth(self, ws) -> None:
        msg = json.loads(await ws.recv())
        if msg["type"] != "auth_required":
            raise ConnectionError(f"unexpected hello: {msg}")
        await ws.send(json.dumps({"type": "auth", "access_token": self.token}))
        msg = json.loads(await ws.recv())
        if msg["type"] != "auth_ok":
            raise ConnectionError(f"HA auth failed: {msg}")

    async def _read_loop(self, ws) -> None:
        async for raw in ws:
            msg = json.loads(raw)
            if msg["type"] == "result":
                fut = self._pending.pop(msg["id"], None)
                if fut and not fut.done():
                    if msg["success"]:
                        fut.set_result(msg.get("result"))
                    else:
                        fut.set_exception(RuntimeError(str(msg.get("error"))))
            elif msg["type"] == "event":
                self._on_event(msg["event"])

    async def _send(self, payload: dict):
        msg_id = next(self._msg_id)
        fut = asyncio.get_running_loop().create_future()
        self._pending[msg_id] = fut
        await self._ws.send(json.dumps({"id": msg_id, **payload}))
        return await fut

    async def _bootstrap(self) -> None:
        areas = await self._send({"type": "config/area_registry/list"})
        devices = await self._send({"type": "config/device_registry/list"})
        entities = await self._send({"type": "config/entity_registry/list"})
        states = await self._send({"type": "get_states"})

        self.areas = {a["area_id"]: a["name"] for a in areas}
        device_area = {d["id"]: d.get("area_id") for d in devices}
        self.entity_area = {}
        self.entity_names = {}
        for e in entities:
            area = e.get("area_id") or device_area.get(e.get("device_id"))
            if area:
                self.entity_area[e["entity_id"]] = area
            name = e.get("name") or e.get("original_name")
            if name:
                self.entity_names[e["entity_id"]] = name
        self.states = {s["entity_id"]: s for s in states}

        await self._send({"type": "subscribe_events", "event_type": "state_changed"})

    def _on_event(self, event: dict) -> None:
        if event.get("event_type") != "state_changed":
            return
        data = event["data"]
        entity_id = data["entity_id"]
        new_state = data.get("new_state")
        if new_state is None:
            self.states.pop(entity_id, None)
        else:
            self.states[entity_id] = new_state

    # ---- public API ----

    async def call_service(
        self,
        domain: str,
        service: str,
        service_data: dict | None = None,
        entity_id: str | None = None,
    ):
        if not self.connected:
            raise ConnectionError("not connected to Home Assistant")
        payload: dict = {
            "type": "call_service",
            "domain": domain,
            "service": service,
            "service_data": service_data or {},
        }
        if entity_id:
            payload["target"] = {"entity_id": entity_id}
        return await self._send(payload)

    def entity_info(self, entity_id: str) -> dict | None:
        state = self.states.get(entity_id)
        if not state:
            return None
        area_id = self.entity_area.get(entity_id)
        return {
            "entity_id": entity_id,
            "name": state.get("attributes", {}).get("friendly_name")
            or self.entity_names.get(entity_id, entity_id),
            "state": state.get("state"),
            "area": self.areas.get(area_id) if area_id else None,
            "attributes": state.get("attributes", {}),
        }

    def list_entities(self, area: str | None = None, domain: str | None = None) -> list[dict]:
        out = []
        for entity_id in self.states:
            if domain and not entity_id.startswith(domain + "."):
                continue
            info = self.entity_info(entity_id)
            if area and (info["area"] or "").lower() != area.lower():
                continue
            out.append({k: info[k] for k in ("entity_id", "name", "state", "area")})
        return out
