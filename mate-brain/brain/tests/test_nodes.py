"""MQTT node yönetim düzlemi birim testleri (broker'sız — handle_message
doğrudan çağrılır, komut yayını stub client ile doğrulanır).

Run: .venv/bin/python -m brain.tests.test_nodes
"""

import asyncio
import json
import os


async def run() -> None:
    os.environ.setdefault("BRAIN_DB_PATH", "/tmp/brain-nodes-test.db")
    if os.path.exists("/tmp/brain-nodes-test.db"):
        os.remove("/tmp/brain-nodes-test.db")

    from brain.config import settings
    from brain.db import Database
    from brain.nodes.manager import NodeManager

    db = Database("/tmp/brain-nodes-test.db")
    await db.connect()
    mgr = NodeManager(settings, db)
    prefix = mgr.prefix

    # 1) Düz LWT "online"
    await mgr.handle_message(f"{prefix}/kitchen/status", b"online")
    rows = await db.list_nodes()
    assert len(rows) == 1 and rows[0]["node_id"] == "kitchen" and rows[0]["online"] == 1, rows

    # 2) Zengin JSON status (kind/version/meta)
    await mgr.handle_message(
        f"{prefix}/hall/status",
        json.dumps({"state": "online", "kind": "satellite", "version": "1.2",
                    "ip": "192.168.0.55"}).encode(),
    )
    rows = {r["node_id"]: r for r in await db.list_nodes()}
    hall = rows["hall"]
    assert hall["kind"] == "satellite" and hall["version"] == "1.2", hall
    assert json.loads(hall["meta"]) == {"ip": "192.168.0.55"}, hall

    # 3) LWT offline — kind/version korunur (COALESCE)
    await mgr.handle_message(f"{prefix}/hall/status", b"offline")
    rows = {r["node_id"]: r for r in await db.list_nodes()}
    assert rows["hall"]["online"] == 0 and rows["hall"]["kind"] == "satellite", rows["hall"]

    # 4) Telemetry → in-memory snapshot
    await mgr.handle_message(f"{prefix}/kitchen/telemetry", b'{"temp": 21.5}')
    snap = {n["node_id"]: n for n in mgr.snapshot()}
    assert snap["kitchen"]["telemetry"] == {"temp": 21.5}, snap

    # 5) Geçersiz topic sessizce atlanır
    await mgr.handle_message("baska/agac/status", b"online")
    assert len(await db.list_nodes()) == 2

    # 6) Bağlı değilken komut → ConnectionError
    try:
        await mgr.send_command("kitchen", {"action": "restart"})
        raise AssertionError("ConnectionError beklenirdi")
    except ConnectionError:
        pass

    # 7) Stub client ile komut yayını
    published: list[tuple] = []

    class StubClient:
        async def publish(self, topic, payload, qos=0):
            published.append((topic, payload, qos))

    mgr._client = StubClient()
    mgr.connected = True
    await mgr.send_command("kitchen", {"action": "restart", "delay": 5})
    assert published == [
        (f"{prefix}/kitchen/cmd", json.dumps({"action": "restart", "delay": 5}, ensure_ascii=False), 1)
    ], published

    # 8) Bozuk telemetry JSON'u raw olarak saklanır
    await mgr.handle_message(f"{prefix}/kitchen/telemetry", b"not-json")
    snap = {n["node_id"]: n for n in mgr.snapshot()}
    assert snap["kitchen"]["telemetry"] == {"raw": "not-json"}, snap

    await db.close()
    print("test_nodes: 8/8 OK")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
