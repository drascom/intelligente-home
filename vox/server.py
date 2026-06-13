#!/usr/bin/env python3
"""
server.py — VoxCPM2 için OpenAI-uyumlu TTS sunucusu (FastAPI).

mate-ios bu sözleşmeyi konuşur (APIClient.swift):
    GET  /v1/voices              -> [{"display_name": ..., "filename": ...}]
    POST /v1/audio/speech        -> WAV byte'ları
        gövde: {"model","input","voice","response_format","language"}

Çalıştır:
    source .venv/bin/activate
    uvicorn server:app --host 0.0.0.0 --port 8808
    # veya:  python server.py

Ortam değişkenleri:
    VOX_DEVICE      cuda | mps | cpu   (boşsa otomatik seçilir)
    VOX_API_KEY     boş değilse Bearer token zorunlu olur
    VOX_VOICES_DIR  ses referansları dizini (varsayılan: ./voices)
    VOX_CFG         cfg_value (varsayılan 2.0)
    VOX_TIMESTEPS   inference_timesteps (varsayılan 10)
    VOX_MAX_CHARS   parça başına maks. karakter (varsayılan 300)
    VOX_GAP_MS      parçalar arası sessizlik ms (varsayılan 150)
    VOX_OPTIMIZE    1 ise torch.compile (yalnız CUDA, ilk istek yavaş)

Gerçek zamanlı köprü (bkz. ../BRIDGE_PROTOCOL.md):
    WS   /ws                      -> {"type":"speak"|"cancel"|"ping"} alır,
                                      audio_start/binary PCM/audio_end yollar.

Bağımlılıklar (WebSocket için):
    fastapi, uvicorn[standard], starlette, anyio  (uvicorn[standard] websockets
    veya wsproto sürücüsünü getirir; düz uvicorn'da WS çalışmaz).
    requirements.txt ile birlikte gelir.
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import queue
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, Header, HTTPException, Response, WebSocket, WebSocketDisconnect
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool
from starlette.websockets import WebSocketState

from audiobook import split_text

# --- Yapılandırma -----------------------------------------------------------
VOICES_DIR = Path(os.environ.get("VOX_VOICES_DIR", Path(__file__).parent / "voices"))
API_KEY = os.environ.get("VOX_API_KEY", "").strip()
DEFAULT_CFG = float(os.environ.get("VOX_CFG", "2.0"))
DEFAULT_TIMESTEPS = int(os.environ.get("VOX_TIMESTEPS", "10"))
DEFAULT_MAX_CHARS = int(os.environ.get("VOX_MAX_CHARS", "300"))
DEFAULT_GAP_MS = int(os.environ.get("VOX_GAP_MS", "150"))


def pick_device() -> str:
    dev = os.environ.get("VOX_DEVICE", "").strip().lower()
    if dev:
        return dev
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


# --- Model (tek sefer yüklenir, bellekte sıcak tutulur) ---------------------
_MODEL = None
_SR = None
_DEVICE = pick_device()
# VoxCPM.generate GPU'da thread-safe değil; çağrıları serialize ediyoruz.
_GEN_LOCK = threading.Lock()


def get_model():
    global _MODEL, _SR
    if _MODEL is None:
        from voxcpm import VoxCPM
        optimize = os.environ.get("VOX_OPTIMIZE", "").strip() in {"1", "true", "yes"}
        print(f"[vox] VoxCPM2 yükleniyor (device={_DEVICE}, optimize={optimize})...", flush=True)
        t0 = time.time()
        _MODEL = VoxCPM.from_pretrained(
            "openbmb/VoxCPM2",
            load_denoiser=False,
            optimize=optimize,
            device=_DEVICE,
        )
        _SR = _MODEL.tts_model.sample_rate
        print(f"[vox] Model hazır ({time.time()-t0:.0f} sn, sr={_SR}).", flush=True)
    return _MODEL, _SR


# --- Ses profilleri ---------------------------------------------------------
def list_voice_files() -> list[Path]:
    if not VOICES_DIR.exists():
        return []
    return sorted(VOICES_DIR.glob("*.wav"))


def resolve_voice(voice: str | None):
    """voice adına karşılık (reference_wav_path, reference_text) döndürür.
    Eşleşme yoksa (None, None) — VoxCPM2 varsayılan sesiyle üretir."""
    if not voice:
        return None, None
    wav = VOICES_DIR / f"{voice}.wav"
    if not wav.exists():
        return None, None
    txt = VOICES_DIR / f"{voice}.txt"
    ref_text = txt.read_text(encoding="utf-8").strip() if txt.exists() else None
    return str(wav), ref_text


# --- Sabit ses: prompt_cache bir kez kurulur, hep aynı ses ------------------
# Standart sesin referansı BİR KEZ encode edilip prompt_cache olarak saklanır.
# Böylece (a) her istekte referans yeniden encode edilmez (hız), (b) ref_audio_feat
# sabit kaldığı için ÇIKAN SES HER ZAMAN AYNI olur — generate() her çağrıda referansı
# yeniden encode ettiği (VAE stokastik) için ses her sefer değişiyordu.
STANDARD_VOICE = os.environ.get("VOX_STANDARD_VOICE", "deneme").strip()
_PROMPT_CACHES: dict[str, object] = {}


def get_prompt_cache(model, voice: str | None):
    """voice için prompt_cache döndürür (bir kez kurar, bellekte saklar). voice'ın
    referansı yoksa STANDARD_VOICE'a düşer; o da yoksa None (zero-shot)."""
    ref_wav, _ = resolve_voice(voice)
    if ref_wav is None:
        ref_wav, _ = resolve_voice(STANDARD_VOICE)
    if ref_wav is None:
        return None
    cache = _PROMPT_CACHES.get(ref_wav)
    if cache is None:
        cache = model.tts_model.build_prompt_cache(reference_wav_path=ref_wav)
        _PROMPT_CACHES[ref_wav] = cache
        print(f"[vox] prompt_cache kuruldu: {ref_wav}", flush=True)
    return cache


def _generate_array(model, text: str, prompt_cache) -> np.ndarray:
    """Sabit prompt_cache ile tam (retry_badcase=True) ses üretir → float32 1D dizi.
    generate()'in iç yolu; prompt_cache reference modunda salt-okunur kullanılır."""
    gen = model.tts_model._generate_with_prompt_cache(
        target_text=text,
        prompt_cache=prompt_cache,
        min_len=2,
        max_len=4096,
        inference_timesteps=DEFAULT_TIMESTEPS,
        cfg_value=DEFAULT_CFG,
        retry_badcase=True,
        retry_badcase_max_times=3,
        retry_badcase_ratio_threshold=6.0,
        streaming=False,
    )
    wav_np = None
    for wav, _, _ in gen:  # streaming=False → tek sonuç
        wav_np = wav.squeeze(0).detach().cpu().numpy()
    if wav_np is None:
        raise RuntimeError("Üretim boş sonuç döndü.")
    return np.asarray(wav_np, dtype="<f4").reshape(-1)


# --- Seslendirme (bloklayıcı; threadpool'da çağrılır) -----------------------
def synthesize_wav(text: str, voice: str | None) -> bytes:
    model, sr = get_model()
    chunks = split_text(text, max_chars=DEFAULT_MAX_CHARS)
    if not chunks:
        raise HTTPException(status_code=400, detail="Metinden cümle çıkarılamadı.")

    gap = np.zeros(int(sr * DEFAULT_GAP_MS / 1000), dtype=np.float32)
    parts: list[np.ndarray] = []
    t0 = time.time()
    with _GEN_LOCK:
        pc = get_prompt_cache(model, voice)
        for i, chunk in enumerate(chunks):
            parts.append(_generate_array(model, chunk, pc))
            if i < len(chunks) - 1:
                parts.append(gap)

    full = np.concatenate(parts)
    buf = io.BytesIO()
    sf.write(buf, full, sr, format="WAV", subtype="PCM_16")
    dur = len(full) / sr
    print(f"[vox] {len(chunks)} parça · {dur:.1f}s ses · {time.time()-t0:.1f}s üretim "
          f"· voice={voice or 'standart'}", flush=True)
    return buf.getvalue()


# --- API --------------------------------------------------------------------
app = FastAPI(title="VoxCPM2 TTS")


class SpeechRequest(BaseModel):
    input: str
    model: str | None = "tts-1"
    voice: str | None = None
    response_format: str | None = "wav"
    language: str | None = "tr"


def check_auth(authorization: str | None):
    if not API_KEY:
        return
    expected = f"Bearer {API_KEY}"
    if authorization != expected:
        raise HTTPException(status_code=401, detail="Geçersiz API anahtarı.")


@app.get("/health")
def health():
    return {"status": "ok", "device": _DEVICE, "model_loaded": _MODEL is not None}


@app.get("/v1/voices")
def voices(authorization: str | None = Header(default=None)):
    check_auth(authorization)
    # "default" → voices/ içinde dosya yok; resolve_voice (None,None) döner =
    # VoxCPM2 varsayılan sesi. Her zaman en az bir seçenek olsun diye başa eklenir.
    out = [{"display_name": "Varsayılan", "filename": "default"}]
    for wav in list_voice_files():
        name = wav.stem
        out.append({"display_name": name.capitalize(), "filename": name})
    return out


@app.post("/v1/audio/speech")
async def speech(req: SpeechRequest, authorization: str | None = Header(default=None)):
    check_auth(authorization)
    text = (req.input or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Boş metin.")
    fmt = (req.response_format or "wav").lower()
    if fmt != "wav":
        raise HTTPException(status_code=400, detail=f"Desteklenmeyen format: {fmt} (yalnız wav).")

    from starlette.concurrency import run_in_threadpool
    data = await run_in_threadpool(synthesize_wav, text, req.voice)
    return Response(content=data, media_type="audio/wav")


# --- Gerçek zamanlı WebSocket köprüsü --------------------------------------
# Sözleşme: ../BRIDGE_PROTOCOL.md
#   İstemci → {"type":"speak","id","text","voice"} | {"type":"cancel","id"} | {"type":"ping"}
#   Sunucu  → {"type":"audio_start","id","sample_rate","channels":1,"format":"pcm_f32le"}
#             <binary float32 LE parçalar...>
#             {"type":"audio_end","id"} | {"type":"error","id","message"} | {"type":"pong"}

# generate_streaming bloklayan bir generator; üretilen parçaları bu sayısal
# değerle thread'den asyncio tarafına aktarırken kuyruğun sonunu işaretliyoruz.
_STREAM_DONE = object()


def check_ws_token(token: str | None) -> bool:
    """WS auth: VOX_API_KEY boşsa serbest; doluysa token birebir eşleşmeli.
    HTTP tarafındaki 'Bearer <key>' yerine WS'te çıplak token taşınır."""
    if not API_KEY:
        return True
    return token == API_KEY


# ~0.125s @ 48kHz: akıcı teslim için frame boyutu (örnek sayısı, float32).
_FRAME_SAMPLES = 6000
# İstemci (iOS) bazen son ~150-200ms'yi kesebiliyor; sona sessizlik ekleyerek
# kesilen kısmın konuşma değil sessizlik olmasını sağlıyoruz (sunucu tarafı sigortası).
TAIL_SILENCE_MS = int(os.environ.get("VOX_TAIL_SILENCE_MS", "500"))


def _stream_worker(
    chunks: list[str],
    voice: str | None,
    out_q: "queue.Queue",
    cancel: threading.Event,
) -> None:
    """Ayrı thread: parçaları sabit prompt_cache ile üretir, ham float32 bytes'ları
    out_q'ya iter. İptal kooperatif: frame'ler arası cancel'a bakar. GPU _GEN_LOCK ile serialize.

    NOT: generate_streaming streaming modda retry_badcase=False'a düşüyor ve üretimi
    erken bitiriyor (~%30 tail kaybı). Bu yüzden tam ve güvenilir ses için sabit
    prompt_cache + _generate_with_prompt_cache kullanıp frame'lere bölerek teslim ediyoruz."""
    try:
        with _GEN_LOCK:
            model = get_model()[0]
            pc = get_prompt_cache(model, voice)
            for chunk in chunks:
                if cancel.is_set():
                    break
                arr = _generate_array(model, chunk, pc)
                for start in range(0, arr.size, _FRAME_SAMPLES):
                    if cancel.is_set():
                        break
                    out_q.put(arr[start:start + _FRAME_SAMPLES].tobytes())
        # Sona sessizlik ekle: istemci son birkaç frame'i kesse bile konuşma değil
        # sessizlik kesilsin.
        if not cancel.is_set() and TAIL_SILENCE_MS > 0:
            pad = np.zeros(int(get_model()[1] * TAIL_SILENCE_MS / 1000), dtype="<f4")
            for start in range(0, pad.size, _FRAME_SAMPLES):
                out_q.put(pad[start:start + _FRAME_SAMPLES].tobytes())
    except Exception as exc:  # üretim hatasını async tarafa taşı
        out_q.put(exc)
    finally:
        out_q.put(_STREAM_DONE)


async def _run_speak(ws: WebSocket, msg_id, text: str, voice: str | None,
                     cancel: threading.Event) -> None:
    """Tek bir 'speak' isteğini işler: audio_start → binary parçalar → audio_end.
    cancel set edilirse (yeni speak/cancel/disconnect) erken çıkar."""
    text = (text or "").strip()
    if not text:
        await ws.send_text(json.dumps({"type": "error", "id": msg_id, "message": "Boş metin."}))
        return

    chunks = split_text(text, max_chars=DEFAULT_MAX_CHARS)
    if not chunks:
        await ws.send_text(json.dumps(
            {"type": "error", "id": msg_id, "message": "Metinden cümle çıkarılamadı."}))
        return

    # Modeli (gerekiyorsa) yükle ve sr'i al — audio_start'tan önce lazım.
    try:
        _, sr = await run_in_threadpool(get_model)
    except Exception as exc:
        await ws.send_text(json.dumps(
            {"type": "error", "id": msg_id, "message": f"Model yüklenemedi: {exc}"}))
        return

    await ws.send_text(json.dumps({
        "type": "audio_start", "id": msg_id,
        "sample_rate": sr, "channels": 1, "format": "pcm_f32le",
    }))

    out_q: "queue.Queue" = queue.Queue(maxsize=64)
    worker = threading.Thread(
        target=_stream_worker, args=(chunks, voice, out_q, cancel), daemon=True)
    t0 = time.time()
    worker.start()

    sent = 0
    err: Exception | None = None
    completed = False  # worker doğal olarak (_STREAM_DONE) bitti mi?
    cancelled = False  # dış kaynaklı iptal (barge-in / cancel / disconnect) oldu mu?
    try:
        while True:
            # Bloklayan kuyruk get'i threadpool'da: event loop'u tıkamaz.
            item = await run_in_threadpool(out_q.get)
            # Her adımda dış iptali kontrol et: worker bir sonraki parçada duracak.
            if cancel.is_set():
                cancelled = True
                break
            if item is _STREAM_DONE:
                completed = True
                break
            if isinstance(item, Exception):
                err = item
                break
            await ws.send_bytes(item)
            sent += 1
    finally:
        # Erken çıktıysak (cancel/hata) worker hâlâ üretiyor olabilir: durdur ve
        # _STREAM_DONE gelene dek kuyruğu boşalt — aksi halde worker bloklanır.
        cancel.set()
        if not completed:
            await run_in_threadpool(_drain_queue, out_q)

    # Bağlantı koptuysa hiçbir şey gönderme.
    if ws.application_state != WebSocketState.CONNECTED:
        return

    if err is not None:
        await ws.send_text(json.dumps(
            {"type": "error", "id": msg_id, "message": str(err)}))
        return

    if cancelled:
        # İptal edildi: audio_end gönderme (sözleşme: kalan parçalar + bitiş yok).
        print(f"[vox/ws] speak id={msg_id} İPTAL · {sent} frame gönderildi", flush=True)
        return

    await ws.send_text(json.dumps({"type": "audio_end", "id": msg_id}))
    print(f"[vox/ws] speak id={msg_id} · {len(chunks)} parça · {sent} frame "
          f"· {time.time()-t0:.1f}s · voice={voice or 'default'}", flush=True)


def _drain_queue(q: "queue.Queue") -> None:
    """Worker thread'i bitene kadar kuyruğu boşalt (deadlock'u önler)."""
    while True:
        item = q.get()
        if item is _STREAM_DONE:
            return


@app.websocket("/ws")
async def ws_bridge(ws: WebSocket):
    # Auth: ?token=... query ya da ilk mesajdaki "token" alanı.
    token = ws.query_params.get("token")
    await ws.accept()

    if API_KEY and token is not None and not check_ws_token(token):
        await ws.close(code=1008)
        return

    authed = check_ws_token(token)  # token query'de geldiyse burada doğrulanmış olur

    # Bağlantı başına tek aktif üretim: mevcut görevi ve onun cancel event'ini tut.
    active_task: asyncio.Task | None = None
    active_cancel: threading.Event | None = None

    def stop_active():
        nonlocal active_task, active_cancel
        if active_cancel is not None:
            active_cancel.set()  # kooperatif iptal — worker bir sonraki parçada durur

    try:
        while True:
            raw = await ws.receive_text()
            try:
                data = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                await ws.send_text(json.dumps(
                    {"type": "error", "id": None, "message": "Geçersiz JSON."}))
                continue

            mtype = data.get("type")

            # İlk mesajda token gelebilir (query'de yoksa).
            if not authed:
                if API_KEY and not check_ws_token(data.get("token")):
                    await ws.close(code=1008)
                    return
                authed = True

            if mtype == "ping":
                await ws.send_text(json.dumps({"type": "pong"}))
                continue

            if mtype == "cancel":
                # Barge-in: aktif üretimi durdur.
                stop_active()
                continue

            if mtype == "speak":
                # Yeni speak gelirse önceki üretimi iptal et (barge-in).
                stop_active()
                if active_task is not None:
                    await active_task  # önceki görevin temiz kapanmasını bekle
                    active_task = None

                msg_id = data.get("id")
                active_cancel = threading.Event()
                active_task = asyncio.create_task(
                    _run_speak(ws, msg_id, data.get("text"), data.get("voice"), active_cancel))
                continue

            await ws.send_text(json.dumps(
                {"type": "error", "id": data.get("id"),
                 "message": f"Bilinmeyen tip: {mtype}"}))
    except WebSocketDisconnect:
        pass
    finally:
        # Bağlantı kopunca üretimi iptal et; model bellekte sıcak kalır.
        stop_active()
        if active_task is not None:
            try:
                await active_task
            except Exception:
                pass


@app.on_event("startup")
def warmup():
    """Sunucu açılışında modeli + standart ses prompt_cache'ini yükle — ilk istek beklemesin."""
    if os.environ.get("VOX_WARMUP", "1").strip() in {"1", "true", "yes"}:
        model, _ = get_model()
        with _GEN_LOCK:
            try:
                get_prompt_cache(model, None)  # standart ses cache'ini ısıt
            except Exception as exc:
                print(f"[vox] standart ses prompt_cache ısıtılamadı: {exc}", flush=True)


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("VOX_PORT", "8808"))
    uvicorn.run("server:app", host="0.0.0.0", port=port, workers=1)
