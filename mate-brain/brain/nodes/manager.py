"""MQTT node yönetim düzlemi (SYSTEM_PLAN Layer 2).

Pi/ESP32 node'ları broker'a şu sözleşmeyle bağlanır:

  <prefix>/<node_id>/status     node → brain   "online"/"offline" (LWT, retained)
                                veya JSON: {"state": "online", "kind": "satellite",
                                            "version": "1.2", ...meta}
  <prefix>/<node_id>/telemetry  node → brain   serbest JSON (sensör/health)
  <prefix>/<node_id>/cmd        brain → node   JSON komut: {"action": "restart", ...}

Brain hepsini izler, DB'deki `nodes` tablosunu ve in-memory aynayı günceller.
MQTT_HOST boşsa düzlem tamamen kapalıdır (NodeManager hiç başlatılmaz).
"""

import asyncio
import json
import logging
import time

import aiomqtt

log = logging.getLogger("brain.nodes")

RECONNECT_DELAY = 5.0


class NodeManager:
    def __init__(self, settings, db):
        self.settings = settings
        self.db = db
        self.connected = False
        # node_id -> {"online": bool, "kind", "version", "last_seen", "telemetry": dict}
        self.nodes: dict[str, dict] = {}
        self._client: aiomqtt.Client | None = None

    @property
    def prefix(self) -> str:
        return self.settings.mqtt_node_prefix.strip("/")

    async def run(self) -> None:
        """Reconnect-forever loop; background task olarak çalıştırılır."""
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("mqtt: connection lost (%s); retry in %ss", e, RECONNECT_DELAY)
            self.connected = False
            self._client = None
            await asyncio.sleep(RECONNECT_DELAY)

    async def _session(self) -> None:
        async with aiomqtt.Client(
            self.settings.mqtt_host,
            self.settings.mqtt_port,
            username=self.settings.mqtt_username or None,
            password=self.settings.mqtt_password or None,
            identifier="brain",
        ) as client:
            self._client = client
            self.connected = True
            await client.subscribe(f"{self.prefix}/+/status")
            await client.subscribe(f"{self.prefix}/+/telemetry")
            log.info("mqtt: connected to %s:%s, watching %s/+/(status|telemetry)",
                     self.settings.mqtt_host, self.settings.mqtt_port, self.prefix)
            async for message in client.messages:
                try:
                    await self.handle_message(str(message.topic), bytes(message.payload))
                except Exception:
                    log.exception("mqtt: message handling failed (%s)", message.topic)

    async def handle_message(self, topic: str, payload: bytes) -> None:
        """Tek bir status/telemetry mesajını işle (testlerde doğrudan çağrılır)."""
        parts = topic.split("/")
        if len(parts) != 3 or parts[0] != self.prefix:
            return
        node_id, channel = parts[1], parts[2]
        text = payload.decode("utf-8", "replace").strip()

        if channel == "status":
            online, kind, version, meta = self._parse_status(text)
            entry = self.nodes.setdefault(node_id, {"telemetry": {}})
            entry.update({
                "online": online, "kind": kind or entry.get("kind"),
                "version": version or entry.get("version"),
                "last_seen": time.time(),
            })
            await self.db.upsert_node(node_id, online, kind=kind, version=version, meta=meta)
            log.info("node %s: %s%s", node_id, "online" if online else "offline",
                     f" ({kind} {version})" if kind or version else "")

        elif channel == "telemetry":
            entry = self.nodes.setdefault(node_id, {"telemetry": {}})
            entry["last_seen"] = time.time()
            try:
                entry["telemetry"] = json.loads(text)
            except json.JSONDecodeError:
                entry["telemetry"] = {"raw": text}
            await self.db.upsert_node(node_id, online=True)

    @staticmethod
    def _parse_status(text: str) -> tuple[bool, str | None, str | None, str | None]:
        """status payload: düz "online"/"offline" (LWT) veya zengin JSON."""
        if text.startswith("{"):
            try:
                obj = json.loads(text)
                online = str(obj.get("state", "online")).lower() == "online"
                kind = obj.get("kind")
                version = obj.get("version")
                meta = {k: v for k, v in obj.items()
                        if k not in ("state", "kind", "version")}
                return online, kind, version, (json.dumps(meta) if meta else None)
            except json.JSONDecodeError:
                pass
        return text.lower() == "online", None, None, None

    async def send_command(self, node_id: str, command: dict) -> None:
        """`<prefix>/<id>/cmd`'ye JSON komut yayınla. Bağlı değilse ConnectionError."""
        if not self.connected or self._client is None:
            raise ConnectionError("MQTT broker'a bağlı değil")
        await self._client.publish(
            f"{self.prefix}/{node_id}/cmd",
            json.dumps(command, ensure_ascii=False),
            qos=1,
        )
        log.info("node %s: cmd %s", node_id, command.get("action", command))

    def snapshot(self) -> list[dict]:
        """API için anlık görünüm (in-memory; DB'deki kalıcı kayıtla birleşmez)."""
        return [
            {"node_id": node_id, **{k: v for k, v in entry.items()}}
            for node_id, entry in sorted(self.nodes.items())
        ]
