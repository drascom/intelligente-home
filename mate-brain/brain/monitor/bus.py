"""Süreç-içi olay veriyolu: braine gelip giden bilgi akışını dashboard'a akıtır.

Tasarım kuralı: `emit()` SENKRON, hiç await etmez, hiç exception sızdırmaz —
bir sohbet turn'ünü asla bloke etmez veya kırmaz. Ring buffer'a ekler ve her
abonenin bounded queue'suna `put_nowait` eder; queue doluysa o frame'i sessizce
düşürür (yavaş bir dashboard producer'ı geri basınçlamasın). Olay yine ring'de
kaldığı için yeniden bağlanan client son durumu backfill ile toparlar.

Olay şeması (düz dict, JSON-serializable, ileri-uyumlu — yeni alanlar nullable
eklenir, migration gerekmez):
    { "id": int, "ts": float, "type": str, "source": str, "summary": str,
      "payload": dict, "conversation_id": str|None, "client_id": int|None }
"""

import asyncio
import collections
import contextlib
import logging
import time

log = logging.getLogger("brain.monitor")

RING_SIZE = 500
QUEUE_MAX = 256


class EventBus:
    def __init__(self, ring_size: int = RING_SIZE, queue_max: int = QUEUE_MAX):
        self._ring: collections.deque = collections.deque(maxlen=ring_size)
        self._subscribers: set[asyncio.Queue] = set()
        self._queue_max = queue_max
        # id'leri zaman tabanlı tohumla: brain restart'ında 1'e dönüp açık duran
        # dashboard'ın eski id'lerle çakışmasını (olayı 'görülmüş' sayıp elemesini)
        # önler. Monoton artan, restart'lar arası benzersiz.
        self._seq = int(time.time() * 1000)

    def emit(
        self,
        type: str,
        source: str,
        summary: str,
        payload: dict | None = None,
        conversation_id: str | None = None,
        client_id: int | None = None,
    ) -> None:
        """Bir olayı yayınla. Senkron, await yok, exception sızdırmaz."""
        self._seq += 1
        event = {
            "id": self._seq,
            "ts": time.time(),
            "type": type,
            "source": source,
            "summary": summary,
            "payload": payload or {},
            "conversation_id": conversation_id,
            "client_id": client_id,
        }
        self._ring.append(event)
        for q in self._subscribers:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                pass  # yavaş tüketici: bu frame'i düşür (olay ring'de kalır)

    def backlog(self) -> list[dict]:
        """Yeni bağlanan abone için ring snapshot'ı (en eski → en yeni)."""
        return list(self._ring)

    @contextlib.contextmanager
    def subscribe(self):
        """Bounded bir queue kaydet; çıkışta otomatik temizle (disconnect)."""
        q: asyncio.Queue = asyncio.Queue(maxsize=self._queue_max)
        self._subscribers.add(q)
        try:
            yield q
        finally:
            self._subscribers.discard(q)


def emit_turn(
    bus: EventBus | None,
    conversation_id: str | None,
    client_id: int | None,
    user_text: str,
    answer: str,
) -> None:
    """Bir sohbet turn'ünün iki ucunu (utterance + reply) tek çağrıda yayınla.
    `bus` None ise no-op (çıplak-app testleri ve MQTT/HA gibi düzlemsiz yollar)."""
    if bus is None:
        return
    if user_text:
        bus.emit(
            "utterance", "agent", _clip(user_text),
            payload={"text": user_text},
            conversation_id=conversation_id, client_id=client_id,
        )
    if answer:
        bus.emit(
            "reply", "agent", _clip(answer),
            payload={"text": answer},
            conversation_id=conversation_id, client_id=client_id,
        )


def _clip(text: str, limit: int = 140) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"
