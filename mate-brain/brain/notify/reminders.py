"""Zamanlı hatırlatmalar: scheduler + proaktif bildirim.

Kullanıcı kararı (firm): asistan araya GİRMEZ. Vakti gelen bir görev için bir
uyarı sesi (chime) çalınır + telefonlara sessiz sinyal push'u gider; içerik
söylenmez. Kullanıcı "candan" deyince, bir sonraki turda o kullanıcının bekleyen
hatırlatmaları cevaba eklenerek teslim edilir (chime → uyandır → teslim).

İki parça:
  * ReminderScheduler — arka plan döngüsü, vakti gelen görevleri yakalar → chime.
  * take_due_deliveries / delivery_text — tur akışında teslim (voice.py + satellite.py).
"""

import asyncio
import json
import logging
import math
import struct
import time

log = logging.getLogger("brain.notify.reminders")


def chime_pcm(rate: int = 16000) -> bytes:
    """Kısa, yumuşak iki-notalı bir bildirim sesi (s16le, mono). TTS değil — saf ton,
    böylece oda sohbetine içerik sızdırmadan "bir şey var" sinyali verir."""
    notes = [(880.0, 0.18), (1175.0, 0.22)]  # A5 → D6, hafif yükselen
    out = bytearray()
    amp = 0.28 * 32767
    for freq, dur in notes:
        n = int(rate * dur)
        for i in range(n):
            # baş/sona doğru zarf (tık-pop olmasın)
            env = min(1.0, i / (rate * 0.01), (n - i) / (rate * 0.02))
            s = int(amp * env * math.sin(2 * math.pi * freq * i / rate))
            out += struct.pack("<h", s)
    return bytes(out)


def _signal_text(count: int) -> str:
    """Telefon push'u: yalnızca sinyal (içerik DEĞİL) — teslim uyandırmadan sonra."""
    if count == 1:
        return "🔔 Bekleyen hatırlatman var — 'candan' de."
    return f"🔔 {count} bekleyen hatırlatman var — 'candan' de."


def delivery_text(tasks: list[dict]) -> str:
    """Bekleyen hatırlatmaları temiz, tek başına Türkçe teslim metnine çevir
    (LLM cevabıyla karışmaz — çağıran tarafta LLM turu atlanır)."""
    if not tasks:
        return ""
    if len(tasks) == 1:
        return f"Hatırlatma: {tasks[0]['text']}."
    items = " ".join(f"{i + 1}) {t['text']}" for i, t in enumerate(tasks))
    return f"{len(tasks)} hatırlatman var: {items}."


# Kullanıcı bildirim sonrası "şu an meşgulüm / sonra" derse teslimi ERTELE
# (hatırlatma pending kalır → bir sonraki olumlu turda teslim edilir).
_DEFER_PATTERNS = (
    "meşgul", "müsait değil", "müsait degil", "sonra konuş", "sonra bak",
    "şimdi olmaz", "simdi olmaz", "şimdi değil", "simdi degil", "uğraşamam",
    "vaktim yok", "müsait olunca", "daha sonra", "sonra söyle", "sonra soyle",
    "boş değil", "bos degil", "sonra anlat",
)

DEFER_ACK = "Tamam, müsait olduğunda hatırlatırım."


def is_defer(text: str) -> bool:
    """Kullanıcı 'şu an meşgulüm / sonra konuşalım' gibi bir şey dediyse True →
    teslim ertelenir, hatırlatma pending kalır."""
    t = text.casefold()
    return any(p in t for p in _DEFER_PATTERNS)


async def peek_deliveries(
    db, user_id: int | None, device_id: str | None = None
) -> list[dict]:
    """Bekleyen teslimleri DÖNDÜR ama done İŞARETLEME — önce kullanıcının yanıtına
    bakılır (olumlu → teslim et; meşgul/sonra → ertele). Tanınan kullanıcıya göre;
    kişi tanınmadıysa chime'ın gittiği cihaza (presence) göre yedekle."""
    if user_id is not None:
        return await db.pending_deliveries(user_id)
    if device_id:
        return await db.pending_deliveries_for_device(device_id)
    return []


async def consume_deliveries(db, tasks: list[dict]) -> None:
    """Teslim edilen hatırlatmaları done işaretle."""
    for t in tasks:
        await db.complete_task(t["id"])
    if tasks:
        log.info("hatırlatma teslim edildi: n=%d", len(tasks))


async def take_due_deliveries(
    db, user_id: int | None, device_id: str | None = None
) -> list[dict]:
    """peek + consume (geriye dönük kısayol). Erteleme mantığı çağıranda."""
    tasks = await peek_deliveries(db, user_id, device_id)
    await consume_deliveries(db, tasks)
    return tasks


class ReminderScheduler:
    """Vakti gelen zamanlı görevleri yoklayıp chime çalan arka plan döngüsü.

    app.state'i çalışma anında okur (satellites/ws_clients/fcm/db/bus lifespan'da
    kurulur), bu yüzden oluşturma sırası önemli değil."""

    def __init__(self, app, settings):
        self.app = app
        self.settings = settings

    async def run(self) -> None:
        while True:
            try:
                await self._tick()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("reminder scheduler tick failed: %s", e)
            await asyncio.sleep(self.settings.reminder_poll_seconds)

    async def _tick(self) -> None:
        db = self.app.state.db
        due = await db.due_tasks(time.time())
        if not due:
            return
        for t in due:
            await db.mark_task_notified(t["id"])
        log.info("reminder: %d görevin vakti geldi → chime", len(due))
        await self._notify(due)

    async def _notify(self, due: list[dict]) -> None:
        """Vakti gelen görevleri kullanıcıya göre grupla; her kullanıcının EN SON
        konuştuğu cihaza chime yönlendir. Presence yoksa / cihaz bağlı değilse o
        görevler broadcast'e (tüm cihazlar) düşer."""
        app = self.app
        db = app.state.db
        pcm = chime_pcm()

        by_user: dict[int | None, list[dict]] = {}
        for t in due:
            by_user.setdefault(t["user_id"], []).append(t)

        routed: list[str] = []
        unrouted = 0   # presence'ı çözülemeyen görev sayısı → broadcast
        for user_id, tasks in by_user.items():
            device_id = await db.get_presence(user_id) if user_id is not None else None
            if device_id and await self._send_to_device(device_id, pcm, len(tasks)):
                routed.append(f"{device_id}×{len(tasks)}")
            else:
                unrouted += len(tasks)

        if unrouted:
            await self._broadcast(pcm, unrouted)

        # Dashboard (monitor) + bus: her zaman, toplam sayıyla.
        ws_sent = 0
        for ws in list(getattr(app.state, "ws_clients", set())):
            try:
                await ws.send_json({"type": "chime", "reason": "reminder", "count": len(due)})
                ws_sent += 1
            except Exception:
                pass
        bus = getattr(app.state, "bus", None)
        if bus:
            bus.emit("reminder", "scheduler",
                     f"{len(due)} hatırlatmanın vakti geldi (chime)",
                     payload={"count": len(due), "routed": routed,
                              "broadcast": unrouted, "ws_clients": ws_sent})
        log.info("reminder chime: routed=%s broadcast=%d ws=%d", routed, unrouted, ws_sent)

    async def _send_to_device(self, device_id: str, pcm: bytes, count: int) -> bool:
        """device_id'yi canlı bir cihaza çöz ve chime gönder. False = ulaşılamadı."""
        kind, _, ref = device_id.partition(":")
        if kind == "satellite":
            sat = next((s for s in getattr(self.app.state, "satellites", [])
                        if s.name == ref), None)
            return await sat.play_pcm(pcm) if sat is not None else False
        if kind == "client":
            if not ref.isdigit():
                return False
            cid = int(ref)
            # Önce canlı voice WS (bağlı uygulama lokal ton çalar); yoksa FCM push.
            if await self._chime_voice_ws(cid):
                return True
            fcm = getattr(self.app.state, "fcm", None)
            if fcm is None:
                return False
            client = await self.app.state.db.client_with_fcm(cid)
            if not client:
                return False
            return await fcm.broadcast([client], "Candan", _signal_text(count)) > 0
        return False

    async def _chime_voice_ws(self, client_id: int) -> bool:
        """Bağlı voice-bridge istemcisine WS üzerinden chime yolla (lokal ton). False
        = bağlı değil."""
        conns = getattr(self.app.state, "voice_clients", {}).get(client_id)
        if not conns:
            return False
        payload = json.dumps({"type": "chime", "reason": "reminder"})
        sent = False
        for ws in list(conns):
            try:
                await ws.send_text(payload)
                sent = True
            except Exception:
                pass
        return sent

    async def _broadcast(self, pcm: bytes, count: int) -> None:
        """Yedek: presence bilinmiyorsa tüm satellite'lara ton + tüm telefonlara push."""
        app = self.app
        sats = getattr(app.state, "satellites", [])
        if sats:
            await asyncio.gather(*(s.play_pcm(pcm) for s in sats), return_exceptions=True)
        fcm = getattr(app.state, "fcm", None)
        if fcm is not None:
            clients = await app.state.db.clients_with_fcm()
            await fcm.broadcast(clients, "Candan", _signal_text(count))
