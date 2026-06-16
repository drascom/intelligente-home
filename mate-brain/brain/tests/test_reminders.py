"""Zamanlı hatırlatma testleri: DB (due/notified/delivery) + scheduler chime +
teslim yardımcıları.

Run: .venv/bin/python -m brain.tests.test_reminders
"""

import asyncio
import os
import time
from types import SimpleNamespace


class FakeSat:
    """play_pcm'i kaydeden sahte satellite."""

    def __init__(self, name="salon"):
        self.name = name
        self.calls = []

    async def play_pcm(self, pcm, rate=16000):
        self.calls.append((len(pcm), rate))
        return True


class FakeFcm:
    """broadcast'i kaydeden sahte FCM."""

    def __init__(self):
        self.sent = []

    async def broadcast(self, clients, title, body):
        self.sent.append((len(clients), title, body))
        return len(clients)


class FakeWS:
    """send_text'i kaydeden sahte voice-bridge WebSocket."""

    def __init__(self):
        self.frames = []

    async def send_text(self, text):
        self.frames.append(text)


async def test_db_lifecycle() -> int:
    from brain.db import Database

    path = "/tmp/brain-reminders-test.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    now = time.time()
    past = await db.create_task("annemi ara", user_id=1, due_at=now - 5)
    future = await db.create_task("doktoru ara", user_id=1, due_at=now + 3600)
    await db.create_task("zamansız not", user_id=1)  # due_at yok → scheduler görmez

    due = await db.due_tasks(now)
    assert [t["id"] for t in due] == [past["id"]], due; n += 1  # sadece geçmiş zamanlı

    # chime çal → notified işaretle → bir daha due listesine düşmez
    await db.mark_task_notified(past["id"])
    assert await db.due_tasks(now) == []; n += 1

    # teslim bekleyenler: notified + pending, kişiye göre
    pend = await db.pending_deliveries(1)
    assert [t["id"] for t in pend] == [past["id"]], pend; n += 1
    assert await db.pending_deliveries(2) == []; n += 1  # başka kullanıcıya sızmaz

    # teslim = done → bir daha teslim bekleyenlerde çıkmaz
    await db.complete_task(past["id"])
    assert await db.pending_deliveries(1) == []; n += 1

    # gelecekteki görev hâlâ pending ve bekleyen-teslimde değil
    assert await db.due_tasks(now + 4000)  # vakti gelince yakalanır
    n += 1
    await db.close()
    return n


async def test_delivery_helpers() -> int:
    from brain.db import Database
    from brain.notify.reminders import delivery_text, take_due_deliveries

    path = "/tmp/brain-reminders-deliver.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    now = time.time()
    t = await db.create_task("ekmek al", user_id=7, due_at=now - 1)
    await db.mark_task_notified(t["id"])

    # tanınmayan kullanıcı + cihaz yok → teslim yok
    assert await take_due_deliveries(db, None) == []; n += 1

    # tanınmayan kullanıcı AMA cihaz presence biliniyor → cihaza göre teslim
    await db.set_presence(7, "client:9")
    dev = await take_due_deliveries(db, None, device_id="client:9")
    assert [x["id"] for x in dev] == [t["id"]], dev; n += 1
    # teslim edildi → tanınan kullanıcı çağrısı da artık boş
    assert await take_due_deliveries(db, 7) == []; n += 1

    # yeni bekleyen + tanınan kullanıcı yolu
    t2 = await db.create_task("süt al", user_id=7, due_at=now - 1)
    await db.mark_task_notified(t2["id"])
    got = await take_due_deliveries(db, 7)
    assert [x["id"] for x in got] == [t2["id"]]; n += 1
    assert await take_due_deliveries(db, 7) == []; n += 1
    # yanlış cihaza teslim sızmaz
    assert await db.pending_deliveries_for_device("client:999") == []; n += 1

    assert delivery_text([]) == ""; n += 1
    assert delivery_text([{"text": "ekmek al"}]) == "Hatırlatma: ekmek al."; n += 1
    two = delivery_text([{"text": "a"}, {"text": "b"}])
    assert two.startswith("2 hatırlatman var:") and "1) a" in two and "2) b" in two, two; n += 1

    await db.close()
    return n


async def test_scheduler_tick() -> int:
    from brain.config import Settings
    from brain.db import Database
    from brain.notify.reminders import ReminderScheduler, chime_pcm

    pcm = chime_pcm()
    assert len(pcm) > 0 and len(pcm) % 2 == 0  # geçerli s16le

    path = "/tmp/brain-reminders-sched.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    now = time.time()
    t = await db.create_task("toplantı", user_id=3, due_at=now - 2)

    sat = FakeSat()
    app = SimpleNamespace(state=SimpleNamespace(
        db=db, satellites=[sat], ws_clients=set(), fcm=None, bus=None,
    ))
    sched = ReminderScheduler(app, Settings())

    await sched._tick()
    assert len(sat.calls) == 1, sat.calls; n += 1            # chime çaldı
    assert await db.due_tasks(now) == []; n += 1             # notified işaretlendi
    assert [x["id"] for x in await db.pending_deliveries(3)] == [t["id"]]; n += 1

    # ikinci tick: yeni vakti gelen yok → chime yok
    await sched._tick()
    assert len(sat.calls) == 1, sat.calls; n += 1

    await db.close()
    return n


async def test_presence_routing() -> int:
    """Chime, kullanıcının EN SON konuştuğu cihaza gider; diğerleri çalmaz."""
    from brain.config import Settings
    from brain.db import Database
    from brain.notify.reminders import ReminderScheduler

    path = "/tmp/brain-reminders-presence.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    # presence set/get round-trip + upsert (en sonu kazanır)
    await db.set_presence(5, "satellite:salon")
    assert await db.get_presence(5) == "satellite:salon"; n += 1
    await db.set_presence(5, "satellite:mutfak")
    assert await db.get_presence(5) == "satellite:mutfak"; n += 1
    assert await db.get_presence(999) is None; n += 1

    now = time.time()
    await db.create_task("ilaç al", user_id=5, due_at=now - 1)

    salon, mutfak = FakeSat("salon"), FakeSat("mutfak")
    fcm = FakeFcm()
    app = SimpleNamespace(state=SimpleNamespace(
        db=db, satellites=[salon, mutfak], ws_clients=set(), fcm=fcm, bus=None,
    ))
    await ReminderScheduler(app, Settings())._tick()
    # yalnızca son cihaz (mutfak) chime aldı; salon almadı; telefona push gitmedi
    assert len(mutfak.calls) == 1 and salon.calls == [], (mutfak.calls, salon.calls); n += 1
    assert fcm.sent == [], fcm.sent; n += 1

    # presence telefonu gösterirse → o client'a FCM push (satellite ton değil)
    await db.set_presence(5, "client:42")
    # client 42'yi fcm token ile oluştur, sonra token ata
    await db._db.execute(
        "INSERT INTO clients (id, name, token, fcm_token, created_at) VALUES (42, 'tel', 'tk', 'fcmtok', ?)",
        (now,),
    )
    await db._db.commit()
    t2 = await db.create_task("toplantı 2", user_id=5, due_at=now - 1)  # noqa: F841
    salon.calls.clear(); mutfak.calls.clear()
    await ReminderScheduler(app, Settings())._tick()
    assert salon.calls == [] and mutfak.calls == [], (salon.calls, mutfak.calls); n += 1
    assert len(fcm.sent) == 1 and fcm.sent[0][0] == 1, fcm.sent; n += 1

    # canlı voice WS varsa → chime WS'e gider, FCM'e DÜŞMEZ
    ws = FakeWS()
    app.state.voice_clients = {42: {ws}}
    fcm.sent.clear()
    await db.create_task("toplantı 3", user_id=5, due_at=now - 1)
    await ReminderScheduler(app, Settings())._tick()
    assert len(ws.frames) == 1 and '"chime"' in ws.frames[0], ws.frames; n += 1
    assert fcm.sent == [], fcm.sent; n += 1

    await db.close()
    return n


async def run() -> None:
    total = await test_db_lifecycle()
    total += await test_delivery_helpers()
    total += await test_scheduler_tick()
    total += await test_presence_routing()
    print(f"test_reminders: {total} assertion OK")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
