"""EventBus birim testleri: emit→ring, abone teslim, QueueFull düşürme, backfill.

Run: .venv/bin/python -m brain.tests.test_monitor
"""

import asyncio


async def run() -> None:
    from brain.monitor.bus import EventBus, emit_turn

    # 1) emit → ring'e düşer, alanlar doğru
    bus = EventBus(ring_size=3, queue_max=2)
    bus.emit("intent", "intent", "sohbet", payload={"label": "sohbet"})
    log = bus.backlog()
    assert len(log) == 1 and log[0]["type"] == "intent", log
    assert log[0]["source"] == "intent" and isinstance(log[0]["id"], int), log[0]
    assert log[0]["payload"] == {"label": "sohbet"}, log[0]
    first_id = log[0]["id"]

    # 2) ring maxlen: en eski düşer, id monoton +1 artar (zaman tabanlı tohum)
    for i in range(5):
        bus.emit("reply", "agent", f"r{i}")
    log = bus.backlog()
    assert len(log) == 3, log                      # ring_size=3
    # 6 olay üretildi (id: first..first+5), son 3 kaldı, ardışık artan
    assert [e["id"] for e in log] == [first_id + 3, first_id + 4, first_id + 5], log

    # 3) abone canlı olay alır
    with bus.subscribe() as q:
        bus.emit("tool_call", "agent", "call_service")
        ev = q.get_nowait()
        assert ev["type"] == "tool_call", ev

    # 4) abonelik bitince temizlenir (yeni emit eski queue'ya gitmez)
    assert len(bus._subscribers) == 0

    # 5) QueueFull → düşür, emit patlamaz (queue_max=2)
    with bus.subscribe() as q:
        for i in range(5):
            bus.emit("telemetry", "nodes", f"t{i}")  # 5 olay, queue 2 alır
        got = []
        while not q.empty():
            got.append(q.get_nowait())
        assert len(got) == 2, got                    # fazlası sessizce düştü

    # 6) emit_turn: utterance + reply iki olay; bus None ise no-op
    bus2 = EventBus()
    emit_turn(bus2, "client-1", 1, "ışığı aç", "tamam, açtım")
    types = [e["type"] for e in bus2.backlog()]
    assert types == ["utterance", "reply"], types
    emit_turn(None, "client-1", 1, "x", "y")          # no-op, patlamamalı

    # 7) emit_turn boş metinleri atlar
    bus3 = EventBus()
    emit_turn(bus3, None, None, "soru?", "")
    assert [e["type"] for e in bus3.backlog()] == ["utterance"], bus3.backlog()

    print("test_monitor: 7/7 OK")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
