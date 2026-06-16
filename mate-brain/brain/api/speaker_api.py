"""Speaker-ID (voice-ID) enrollment + yönetim API'si (admin).

Kişi oluştur → birkaç kısa ses örneği yükle (wav) → embedding çıkarılıp saklanır.
Çalışma anındaki tanıma `voice.py` içinde; bu API sadece kayıt/yönetim.

Enrollment gecikme-duyarlı değil → basit REST multipart wav upload.
"""

import io
import logging

import numpy as np
from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile
from pydantic import BaseModel

from brain.api.auth import current_client
from brain.voice.speaker import emb_to_bytes

log = logging.getLogger("brain.api.speaker")

router = APIRouter(prefix="/api/speakers")


def _require_speaker(request: Request):
    sp = getattr(request.app.state, "speaker", None)
    if sp is None:
        raise HTTPException(503, "speaker-ID kapalı (SPEAKER_ID_ENABLED + model gerekli)")
    return sp


async def _read_wav_mono(file: UploadFile) -> tuple[np.ndarray, int]:
    """Yüklenen ses dosyasını float32 mono diziye + örnekleme hızına çevir."""
    import soundfile as sf

    raw = await file.read()
    if not raw:
        raise HTTPException(400, "boş dosya")
    try:
        data, sr = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    except Exception as e:
        raise HTTPException(400, f"ses çözülemedi (wav/flac bekleniyor): {e}")
    samples = data.mean(axis=1)  # mono'ya indir
    return np.ascontiguousarray(samples), int(sr)


async def _reload(request: Request) -> None:
    sp = request.app.state.speaker
    sp.reload(await request.app.state.db.all_speaker_embeddings())


class NewSpeaker(BaseModel):
    name: str
    user_id: int | None = None


@router.post("")
async def create_speaker(
    body: NewSpeaker, request: Request, _: dict = Depends(current_client)
):
    _require_speaker(request)
    name = body.name.strip()
    if not name:
        raise HTTPException(400, "name boş")
    return await request.app.state.db.create_speaker(name, body.user_id)


@router.get("")
async def list_speakers(request: Request, _: dict = Depends(current_client)):
    return await request.app.state.db.list_speakers()


@router.post("/{speaker_id}/samples")
async def add_sample(
    speaker_id: int,
    request: Request,
    file: UploadFile,
    source: str | None = None,
    _: dict = Depends(current_client),
):
    sp = _require_speaker(request)
    db = request.app.state.db
    if await db.get_speaker(speaker_id) is None:
        raise HTTPException(404, "kişi yok")
    samples, sr = await _read_wav_mono(file)
    import asyncio

    emb = await asyncio.to_thread(sp.embed_samples, samples, sr)
    sample_id = await db.add_speaker_sample(
        speaker_id, emb_to_bytes(emb), sp.dim, sp.model_id, source
    )
    await _reload(request)
    return {"sample_id": sample_id, "seconds": round(len(samples) / sr, 2), "dim": sp.dim}


@router.delete("/{speaker_id}")
async def delete_speaker(
    speaker_id: int, request: Request, _: dict = Depends(current_client)
):
    if await request.app.state.db.get_speaker(speaker_id) is None:
        raise HTTPException(404, "kişi yok")
    await request.app.state.db.delete_speaker(speaker_id)
    await _reload(request)
    return {"ok": True}


@router.delete("/{speaker_id}/samples/{sample_id}")
async def delete_sample(
    speaker_id: int, sample_id: int, request: Request, _: dict = Depends(current_client)
):
    await request.app.state.db.delete_speaker_sample(speaker_id, sample_id)
    await _reload(request)
    return {"ok": True}


@router.post("/identify")
async def identify(
    request: Request, file: UploadFile, _: dict = Depends(current_client)
):
    """DEBUG: bir ses yükle → {name, score}. Eşik/marj ayarı için."""
    sp = _require_speaker(request)
    samples, sr = await _read_wav_mono(file)
    import asyncio

    emb = await asyncio.to_thread(sp.embed_samples, samples, sr)
    name, score = sp.identify(emb)
    return {"speaker": name, "score": round(score, 4), "enrolled": sp.num_speakers()}
