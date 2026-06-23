"""LiveKit wake-gate testi: utterance BAŞINDA awake=1 görünse bile, söz
BİTERKEN istemci uykudaysa (awake=0) utterance düşmeli.

Düzeltilen bug: brain `candan.awake`'i yalnız utterance başında okuyordu; istemci
uykuya geçtikten hemen sonra başlayan söz, attribute henüz brain'e yayılmadığı için
stale awake=1 okuyup cevaplanıyordu. Fix: bitişte awake yeniden okunur, başta VE
bitişte uyanıksa işlenir (livekit_agent.py `_consume_track`).

_consume_track bir utterance boyunca `self._attrs(participant)` tam İKİ kez okur:
(1) başta (ilk kare, stt is None), (2) bitişte (still_awake). Sahte bir rtc stream
+ mock WhisperSession ile yarışı deterministik kurarız.

Run: .venv/bin/python -m brain.tests.test_livekit_gate
"""

import asyncio
from types import SimpleNamespace

import brain.voice.livekit_agent as lka
from brain.voice.livekit_agent import LiveKitAgent

SPEECH = b"\x10\x27" * 320  # 320 örnek (20ms) gürültülü s16 kare (0x2710 = 10000)
SILENCE = b"\x00\x00" * 320  # 20ms sessizlik


class FakeStream:
    """async-iterable: önce konuşma sonra sessizlik kareleri yayar (utterance biter)."""

    def __init__(self, payloads):
        self._events = [SimpleNamespace(frame=SimpleNamespace(data=p)) for p in payloads]
        self._i = 0

    def __aiter__(self):
        return self

    async def __anext__(self):
        if self._i >= len(self._events):
            raise StopAsyncIteration
        ev = self._events[self._i]
        self._i += 1
        return ev

    async def aclose(self):
        pass


class FakeWhisper:
    def __init__(self, *a, **k):
        pass

    async def start(self, **k):
        pass

    async def feed(self, event):
        pass

    async def finish(self):
        return "ışıkları aç"  # boş-olmayan → gate geçerse işlenirdi

    async def abort(self):
        pass


def _make_agent(awake_reads):
    """awake_reads: _attrs'ın sırayla döndüreceği candan.awake değerleri ('1'/'0')."""
    agent = object.__new__(LiveKitAgent)
    agent.settings = SimpleNamespace(
        resolve_stt_engine=lambda name: ("whisper", "127.0.0.1", 10300),
        stt_language="tr",
    )
    agent._tts_task = None
    agent._active_stream = None
    reads = list(awake_reads)
    calls = {"n": 0}

    def fake_attrs(participant):
        i = min(calls["n"], len(reads) - 1)
        calls["n"] += 1
        return {"candan.awake": reads[i], "stt_engine": "whisper", "language": "tr"}

    agent._attrs = fake_attrs
    agent._set_agent_state = lambda state: None
    captured = {}

    async def fake_handle(stt, pcm=b"", participant=None, track=None, awake=True):
        captured["awake"] = awake

    agent._handle_utterance = fake_handle
    return agent, captured, calls


async def _run_one_utterance(agent):
    # ~0.5s konuşma + ~1.4s sessizlik → SILENCE_AFTER_S (1.0s) aşılır, utterance biter
    payloads = [SPEECH] * 25 + [SILENCE] * 70
    fake_rtc = SimpleNamespace(
        AudioStream=SimpleNamespace(from_track=lambda **kw: FakeStream(payloads))
    )
    await agent._consume_track(fake_rtc, track=object(), participant=object())


async def main():
    lka.WhisperSession = FakeWhisper  # mock: gerçek STT'ye bağlanma

    # 1) BUG senaryosu: başta awake=1 (stale), bitişte awake=0 → DÜŞMELİ
    agent, captured, calls = _make_agent(["1", "0"])
    await _run_one_utterance(agent)
    # En az 2 okuma: başta + bitişte (artakalan sessizlik 2. bir sözü başlatıp
    # fazladan okuyabilir ama o söz konuşma içermediğinden işlenmez — zararsız).
    assert calls["n"] >= 2, f"_attrs en az 2 kez okunmalıydı, {calls['n']} oldu"
    assert captured.get("awake") is False, (
        f"uyku-sonrası sızan utterance düşmeliydi (awake=False), "
        f"ama awake={captured.get('awake')!r}"
    )
    print("PASS — başta awake=1 / bitişte awake=0 → utterance düştü (awake=False)")

    # 2) Regresyon: boyunca awake=1 → meşru komut İŞLENMELİ
    agent, captured, calls = _make_agent(["1", "1"])
    await _run_one_utterance(agent)
    assert captured.get("awake") is True, (
        f"uyanık komut işlenmeliydi (awake=True), ama awake={captured.get('awake')!r}"
    )
    print("PASS — başta awake=1 / bitişte awake=1 → komut işlendi (awake=True)")

    # 3) Baştan uyku: başta awake=0 → zaten düşer (start-gate)
    agent, captured, calls = _make_agent(["0", "0"])
    await _run_one_utterance(agent)
    assert captured.get("awake") is False, (
        f"baştan uyku düşmeliydi (awake=False), ama awake={captured.get('awake')!r}"
    )
    print("PASS — başta awake=0 → utterance düştü (awake=False)")

    print("\nTÜM GATE TESTLERİ GEÇTİ ✅")


if __name__ == "__main__":
    asyncio.run(main())
