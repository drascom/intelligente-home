"""Speaker-ID (voice-ID) birim testleri.

- DB CRUD: speakers + speaker_samples + messages.speaker (model gerektirmez).
- identify/reload saf numpy mantığı: eşik, marj kuralı, model_id uyuşmazlığı
  (onnx modeli YÜKLEMEDEN — object.__new__ ile, CI-güvenli).
- Model dosyası varsa gerçek embed self-match smoke testi (yoksa atlanır).

Run: .venv/bin/python -m brain.tests.test_speaker
"""

import asyncio
import os

import numpy as np

from brain.voice.speaker import SpeakerID, emb_to_bytes, pcm_to_f32


def _emb(v) -> bytes:
    return emb_to_bytes(np.array(v, dtype=np.float32))


def _fake_id(dim=4, threshold=0.6, margin=0.05) -> SpeakerID:
    """SpeakerID — onnx modeli yüklemeden (reload/identify saf numpy)."""
    sp = object.__new__(SpeakerID)
    sp.dim = dim
    sp.model_id = "test"
    sp.threshold = threshold
    sp.margin = margin
    sp._names = []
    sp._centroids = np.zeros((0, dim), dtype=np.float32)
    return sp


def test_identify_logic() -> int:
    n = 0
    sp = _fake_id()
    sp.reload([
        {"name": "anne", "model_id": "test", "embeddings": [_emb([1, 0, 0, 0]), _emb([0.9, 0.1, 0, 0])]},
        {"name": "baba", "model_id": "test", "embeddings": [_emb([0, 1, 0, 0])]},
    ])
    assert sp.num_speakers() == 2; n += 1

    # anne'ye yakın → anne
    name, score = sp.identify(np.array([1, 0, 0, 0], dtype=np.float32))
    assert name == "anne" and score > 0.9, (name, score); n += 1

    # diğer eksene dik → eşik altı → unknown
    name, score = sp.identify(np.array([0, 0, 1, 0], dtype=np.float32))
    assert name is None, (name, score); n += 1

    # anne ile baba'ya eşit uzaklık → marj kuralı → unknown
    name, score = sp.identify(np.array([1, 1, 0, 0], dtype=np.float32))
    assert name is None, (name, score); n += 1

    # boş küme → unknown
    empty = _fake_id()
    assert empty.identify(np.array([1, 0, 0, 0], dtype=np.float32)) == (None, 0.0); n += 1

    # model_id uyuşmazlığı → kişi atlanır
    sp.reload([{"name": "x", "model_id": "OTHER", "embeddings": [_emb([1, 0, 0, 0])]}])
    assert sp.num_speakers() == 0; n += 1

    # dim uyuşmazlığı → örnek atlanır (kişi de düşer)
    sp.reload([{"name": "y", "model_id": "test", "embeddings": [_emb([1, 0, 0, 0, 0])]}])
    assert sp.num_speakers() == 0; n += 1
    return n


def test_pcm_conversion() -> int:
    n = 0
    b = np.array([0, 16384, -16384, 32767], dtype="<i2").tobytes()
    out = pcm_to_f32(b, 2, 1)
    assert np.allclose(out, [0.0, 0.5, -0.5, 1.0], atol=1e-3), out; n += 1
    # stereo → mono ortalama
    st = np.array([0, 32767, 0, -32768], dtype="<i2").tobytes()  # 2 frame, 2 kanal
    mono = pcm_to_f32(st, 2, 2)
    assert mono.shape == (2,), mono.shape; n += 1
    # f32le geçişi
    f = np.array([0.25, -0.5], dtype="<f4").tobytes()
    assert np.allclose(pcm_to_f32(f, 4, 1), [0.25, -0.5]); n += 1
    return n


async def test_db() -> int:
    from brain.db import Database

    path = "/tmp/brain-speaker-test.db"
    if os.path.exists(path):
        os.remove(path)
    db = Database(path)
    await db.connect()
    n = 0

    anne = await db.create_speaker("anne")
    sid = anne["id"]
    s1 = await db.add_speaker_sample(sid, _emb([1, 0, 0, 0]), dim=4, model_id="test", source="mac")
    await db.add_speaker_sample(sid, _emb([0.9, 0.1, 0, 0]), dim=4, model_id="test", source="ios")

    row = await db.get_speaker(sid)
    assert row["sample_count"] == 2 and row["dim"] == 4 and row["model_id"] == "test", row; n += 1

    embs = await db.speaker_embeddings(sid)
    assert len(embs) == 2 and isinstance(embs[0], (bytes, bytearray)), embs; n += 1

    allsp = await db.all_speaker_embeddings()
    assert len(allsp) == 1 and len(allsp[0]["embeddings"]) == 2, allsp; n += 1

    # messages.speaker session içinde yazılıyor
    sess = await db.resolve_session("user-1", user_id=1)
    await db.add_message(sess, "user", "merhaba", speaker="anne")
    cur = await db._db.execute("SELECT speaker FROM messages WHERE session_id=?", (sess,))
    assert (await cur.fetchone())["speaker"] == "anne"; n += 1
    # aynı scope tekrar çözülünce aynı oturum (yeni oturum açılmaz)
    assert await db.resolve_session("user-1") == sess; n += 1

    # örnek sil → sayaç düşer
    await db.delete_speaker_sample(sid, s1)
    assert (await db.get_speaker(sid))["sample_count"] == 1; n += 1

    # kişi sil → örnekler de gider
    await db.delete_speaker(sid)
    assert await db.list_speakers() == [] and await db.speaker_embeddings(sid) == []; n += 1

    await db.close()
    return n


def test_real_model() -> int:
    """Model dosyası + sherpa varsa: gerçek embed + self-match smoke testi."""
    from brain.config import settings

    if not os.path.exists(settings.speaker_model_path):
        print("test_speaker: gerçek-model smoke ATLANDI (model dosyası yok)")
        return 0
    try:
        import sherpa_onnx  # noqa: F401
    except Exception:
        print("test_speaker: gerçek-model smoke ATLANDI (sherpa-onnx yok)")
        return 0

    sp = SpeakerID(settings.speaker_model_path, "campplus_test", 0.5, 0.0)
    assert sp.dim == 192, sp.dim
    # 2sn deterministik sinüs
    t = np.arange(16000 * 2) / 16000.0
    sig = (0.3 * np.sin(2 * np.pi * 180 * t)).astype(np.float32)
    e = sp.embed_samples(sig, 16000)
    assert e.shape == (192,), e.shape
    # kendini enroll → kendini tanı
    sp.reload([{"name": "sine", "model_id": "campplus_test", "embeddings": [emb_to_bytes(e)]}])
    name, score = sp.identify(e)
    assert name == "sine" and score > 0.99, (name, score)
    print(f"test_speaker: gerçek-model smoke OK (dim={sp.dim}, self-score={score:.3f})")
    return 3


async def run() -> None:
    total = 0
    total += test_identify_logic()
    total += test_pcm_conversion()
    total += await test_db()
    total += test_real_model()
    print(f"test_speaker: {total} assertion OK")


def main() -> None:
    asyncio.run(run())


if __name__ == "__main__":
    main()
