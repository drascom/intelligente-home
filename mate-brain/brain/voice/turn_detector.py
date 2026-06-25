"""Smart Turn v3 — SES-tabanlı konuşma-sonu (end-of-utterance / EOU) dedektörü.

Konuşmacının turunu BİTİRİP bitirmediğini ham utterance sesinden (16 kHz mono
s16le) tahmin eder — sabit bir sessizlik zamanlayıcısından tahmin etmek yerine.
Böylece LiveKit ajanı cümle ortası duraksamalarda (özellikle Türkçe fiil-sonu
yan cümleler) kullanıcıyı KESMEZ; tam bir düşünce bitince de hemen yanıt verir.

Neden SES-tabanlı (LiveKit'in METİN-tabanlı MultilingualModel'i DEĞİL): bizim
Wyoming STT'imiz finish-only (utterance ortasında ara/partial transcript
üretmez) → metin EOU modelinin tur ortasında üzerinde çalışacağı metni yok.
Smart Turn ise zaten biriktirdiğimiz PCM tamponu üzerinde çalışır.

Model: pipecat-ai/smart-turn-v3 (Whisper-tiny encoder + lineer kafa, ~8 MB ONNX,
BSD-2, CPU). Tembel yüklenir, FAIL-OPEN: herhangi bir yükleme/çıkarım hatasında
turu "tamamlandı" sayar → çağıran saf-sessizlik zamanlayıcısına düşer; ses yolu
asla kırılmaz. Önişleme smart-turn `inference.py` ile birebir (WhisperFeature-
Extractor, son 8 sn'ye kırp, max_length=8*16000 doldur).
"""

import asyncio
import logging

import numpy as np

log = logging.getLogger("brain.voice.turn_detector")

_SAMPLE_RATE = 16000
_MAX_SECONDS = 8
_MAX_SAMPLES = _MAX_SECONDS * _SAMPLE_RATE
# Bu kadar saniyeden kısa ses → modeli çalıştırma; endpointing'i sessizliğe bırak
# (kısa komutlar "saat kaç?" zaten sessizlik eşiğiyle hızlı biter).
_MIN_SECONDS = 0.2


class SmartTurnDetector:
    """Tembel-yüklenen, fail-open smart-turn v3 sarmalayıcısı."""

    def __init__(self, repo: str, model_file: str, threshold: float = 0.5):
        self.repo = repo
        self.model_file = model_file
        self.threshold = threshold
        self._session = None        # onnxruntime.InferenceSession
        self._feat = None           # transformers.WhisperFeatureExtractor
        self._failed = False        # bir kez yükleme başarısız olursa tekrar deneme

    def _ensure_loaded(self) -> None:
        if self._session is not None or self._failed:
            return
        try:
            import onnxruntime as ort
            from huggingface_hub import hf_hub_download
            from transformers import WhisperFeatureExtractor

            path = hf_hub_download(self.repo, self.model_file)
            so = ort.SessionOptions()
            so.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
            so.inter_op_num_threads = 1
            so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            self._session = ort.InferenceSession(path, sess_options=so)
            # Whisper-tiny → 80 mel; smart-turn varsayılan WhisperFeatureExtractor
            # kullanır (preprocessor_config.json yok), bu yüzden açıkça kuruyoruz.
            self._feat = WhisperFeatureExtractor(
                feature_size=80, sampling_rate=_SAMPLE_RATE
            )
            log.info("smart-turn yüklendi (%s/%s, eşik=%.2f)",
                     self.repo, self.model_file, self.threshold)
        except Exception as e:
            self._failed = True
            log.warning(
                "smart-turn yüklenemedi → sessizlik zamanlayıcısına düşülüyor: %r", e
            )

    def _predict_sync(self, audio_f32: np.ndarray) -> float:
        # Son _MAX_SECONDS saniyeye kırp (smart-turn: ses vektörün SONUNDA olmalı).
        if audio_f32.shape[0] > _MAX_SAMPLES:
            audio_f32 = audio_f32[-_MAX_SAMPLES:]
        # do_normalize=True ŞART (smart-turn inference.py ile birebir): model
        # zero-mean/unit-var normalize edilmiş feature'larla eğitildi. Atlanırsa
        # (transformers varsayılanı False) cümle-ortası duraksamalar p≈0.6 ile
        # yanlışlıkla "tamam" sayılır → kullanıcı KESİLİR. True ile aynı duraksama
        # p≈0.27 ("devam") olur. Türkçe fiil-sonu yan cümleleri için kritik.
        feats = self._feat(
            audio_f32,
            sampling_rate=_SAMPLE_RATE,
            return_tensors="np",
            padding="max_length",
            max_length=_MAX_SAMPLES,
            truncation=True,
            do_normalize=True,
        )
        input_features = feats["input_features"].squeeze(0).astype(np.float32)
        input_features = np.expand_dims(input_features, axis=0)
        outputs = self._session.run(None, {"input_features": input_features})
        return float(outputs[0][0].item())

    async def is_complete(self, pcm_s16le: bytes) -> bool:
        """True = konuşmacı turunu bitirdi (yanıt verilebilir).

        Fail-open: model yok / yetersiz ses / hata → True (çağıran sessizlik
        zamanlayıcısına güvenir). Çıkarım ayrı thread'de (event loop'u bloklamaz)."""
        self._ensure_loaded()
        if self._session is None:
            return True
        try:
            audio = np.frombuffer(pcm_s16le, dtype=np.int16).astype(np.float32) / 32768.0
            if audio.shape[0] < int(_MIN_SECONDS * _SAMPLE_RATE):
                return True
            prob = await asyncio.to_thread(self._predict_sync, audio)
            complete = prob >= self.threshold
            # GEÇİCİ (doğrulama): canlı testte p= görebilmek için INFO. Eşik
            # ayarı netleşince log.debug'a geri al.
            log.info("smart-turn p=%.3f → %s", prob,
                     "tamam" if complete else "devam")
            return complete
        except Exception as e:
            log.warning("smart-turn tahmini başarısız → tamam sayıldı: %r", e)
            return True
