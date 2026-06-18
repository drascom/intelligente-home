#!/usr/bin/env python3
"""Wyoming STT sunucusu — NVIDIA Nemotron 3.5 ASR Streaming (cache-aware) sarmalayıcı.

Beyin (mate-brain) STT'yi Wyoming protokolüyle konuşur: `transcribe` + `audio-start`
(rate/width/channels) + `audio-chunk`(PCM) + `audio-stop` gönderir, sonra TEK bir
`transcript` olayı bekler (bkz. mate-brain/brain/voice/services.py WhisperSession).
Bu servis wyoming-faster-whisper ile AYNI sunucu protokolünü konuşur → farklı portta
(10301) birebir drop-in. Whisper (10300) CANLI; bu servis YAN portta, varsayılan DEĞİL.

Davranış: gelen PCM parçalarını biriktir, `audio-stop`'ta TEK bir Nemotron transkripsiyonu
çalıştır (16k mono, sonda toplu) ve tek bir `transcript` yay.

ÖNEMLİ — çalışan çıkarım yolu (Faz 0'da doğrulandı):
  Naif `model.transcribe([wav], target_lang=...)` bu commit'te BOZUK ('Unknown prompt key').
  Bunun yerine cache-aware STREAMING döngüsü kullanılır (conformer_stream_step + cache),
  dil `set_inference_prompt(<lang>)` ile zorlanır ve `<tr-TR>` dil etiketi çıktıdan silinir.
  Gerçek insan konuşmasında (FLEURS tr) bu yol neredeyse kusursuz Türkçe üretir.
"""

import argparse
import asyncio
import logging
import os
from functools import partial

import numpy as np
import torch
from omegaconf import open_dict

from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioChunkConverter, AudioStart, AudioStop
from wyoming.event import Event
from wyoming.server import AsyncEventHandler, AsyncServer

_LOGGER = logging.getLogger("nemotron")

# Model 16k mono bekler; gelen ses ne olursa olsun buna indirgenir.
TARGET_RATE = 16000
TARGET_WIDTH = 2  # int16
TARGET_CHANNELS = 1


class NemotronTranscriber:
    """Nemotron modelini bir kez yükler ve birikmiş PCM'i tek seferde yazıya döker.

    Model thread-safe değildir; tüm transkripsiyonlar tek bir kilitle sıraya alınır
    (beyin zaten aynı anda tek bir konuşma gönderir).
    """

    def __init__(self, model_ref: str, device: str, language: str) -> None:
        import nemo.collections.asr as nemo_asr
        from nemo.collections.asr.parts.utils.streaming_utils import (
            CacheAwareStreamingAudioBuffer,
        )
        from nemo.collections.asr.parts.utils.rnnt_utils import Hypothesis

        self._buffer_cls = CacheAwareStreamingAudioBuffer
        self._hyp_cls = Hypothesis
        self.device = device
        self._lock = asyncio.Lock()

        _LOGGER.info("Nemotron modeli yükleniyor: %s (device=%s)", model_ref, device)
        if model_ref.endswith(".nemo") or os.path.exists(model_ref):
            model = nemo_asr.models.ASRModel.restore_from(model_ref, map_location=device)
        else:
            model = nemo_asr.models.ASRModel.from_pretrained(model_ref, map_location=device)

        # RNNT greedy + fused_batch_size=-1 (streaming çıkarım örneğindeki gibi)
        dec = model.cfg.decoding
        with open_dict(dec):
            dec.strategy = "greedy"
            dec.fused_batch_size = -1
        model.change_decoding_strategy(dec)

        # Dil-prompt (langID) zorla + çıktıdaki <xx-XX> dil etiketini sil.
        resolved = self._resolve_lang(model, language)
        _LOGGER.info("Dil-prompt zorlanıyor: %r -> %r", language, resolved)
        model.set_inference_prompt(resolved)
        model.decoding.set_strip_lang_tags(True)

        model.eval()
        self.model = model
        self.language = resolved
        _LOGGER.info("Nemotron hazır.")

    @staticmethod
    def _resolve_lang(model, language: str) -> str:
        """'tr' gibi kısa kodu modelin prompt sözlüğündeki anahtara ('tr-TR') eşler."""
        try:
            prompt_dict = model.cfg.model_defaults.prompt_dictionary
        except Exception:
            return language
        if language in prompt_dict:
            return language
        for key in prompt_dict:
            if str(key).lower().startswith(language.lower() + "-"):
                return key
        return "auto" if "auto" in prompt_dict else language

    def _transcribe_sync(self, audio_f32: "np.ndarray") -> str:
        """Biriken dalga biçimini cache-aware streaming döngüsüyle yazıya döker."""
        model = self.model
        buf = self._buffer_cls(
            model=model, online_normalization=False, pad_and_drop_preencoded=False
        )
        # Ham 16k mono float32 dalga biçimini doğrudan tampona ver (dosya gerekmez).
        buf.append_audio(audio_f32, stream_id=-1)

        cache_last_channel, cache_last_time, cache_last_channel_len = (
            model.encoder.get_initial_cache_state(batch_size=len(buf.streams_length))
        )
        prev_hyp = pred_out = txts = None
        for step, (chunk_audio, chunk_len) in enumerate(buf):
            drop = 0 if step == 0 else model.encoder.streaming_cfg.drop_extra_pre_encoded
            with torch.inference_mode(), torch.no_grad():
                (
                    pred_out,
                    txts,
                    cache_last_channel,
                    cache_last_time,
                    cache_last_channel_len,
                    prev_hyp,
                ) = model.conformer_stream_step(
                    processed_signal=chunk_audio,
                    processed_signal_length=chunk_len,
                    cache_last_channel=cache_last_channel,
                    cache_last_time=cache_last_time,
                    cache_last_channel_len=cache_last_channel_len,
                    keep_all_outputs=buf.is_buffer_empty(),
                    previous_hypotheses=prev_hyp,
                    previous_pred_out=pred_out,
                    drop_extra_pre_encoded=drop,
                    return_transcription=True,
                )
        if not txts:
            return ""
        first = txts[0]
        text = first.text if isinstance(first, self._hyp_cls) else first
        return (text or "").strip()

    async def transcribe(self, pcm_bytes: bytes) -> str:
        """16k/mono/16-bit PCM bayt → metin. GPU işi thread'e taşınır, kilitle sıralanır."""
        if not pcm_bytes:
            return ""
        audio_f32 = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        async with self._lock:
            return await asyncio.to_thread(self._transcribe_sync, audio_f32)


class NemotronEventHandler(AsyncEventHandler):
    """Tek bağlantı: chunk'ları biriktir, audio-stop'ta yazıya dök, transcript yay."""

    def __init__(self, transcriber: NemotronTranscriber, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.transcriber = transcriber
        self._audio = bytearray()
        # Her parçayı 16k/mono/16-bit'e indirgeyen dönüştürücü (her bağlantıya özel).
        self._converter = AudioChunkConverter()
        self._converter.rate = TARGET_RATE
        self._converter.width = TARGET_WIDTH
        self._converter.channels = TARGET_CHANNELS

    async def handle_event(self, event: Event) -> bool:
        if Transcribe.is_type(event.type):
            # Dil isteği bilgi amaçlı; servis başlangıçta sabit dile ayarlı.
            self._audio = bytearray()
            return True

        if AudioStart.is_type(event.type):
            self._audio = bytearray()
            return True

        if AudioChunk.is_type(event.type):
            chunk = self._converter.convert(AudioChunk.from_event(event))
            self._audio.extend(chunk.audio)
            return True

        if AudioStop.is_type(event.type):
            text = await self.transcriber.transcribe(bytes(self._audio))
            self._audio = bytearray()
            _LOGGER.debug("transcript: %r", text)
            await self.write_event(
                Transcript(text=text, language=self.transcriber.language).event()
            )
            return True

        return True


async def main() -> None:
    parser = argparse.ArgumentParser(description="Wyoming Nemotron STT sunucusu")
    parser.add_argument(
        "--uri", default=os.getenv("NEMOTRON_URI", "tcp://0.0.0.0:10301"),
        help="Wyoming sunucu URI'si (vars. tcp://0.0.0.0:10301)",
    )
    parser.add_argument(
        "--model",
        default=os.getenv("NEMOTRON_MODEL", "nvidia/nemotron-3.5-asr-streaming-0.6b"),
        help=".nemo yolu veya HF model adı (HF_HOME önbelleğinden çözülür)",
    )
    parser.add_argument(
        "--device", default=os.getenv("NEMOTRON_DEVICE", "cuda"),
        help="cuda veya cpu",
    )
    parser.add_argument(
        "--language", default=os.getenv("NEMOTRON_LANGUAGE", "tr"),
        help="Zorlanan dil (kısa kod 'tr' otomatik 'tr-TR'ye eşlenir)",
    )
    parser.add_argument("--debug", action="store_true", help="Ayrıntılı log")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    # Ağır model yüklemesi BİR KEZ; tüm bağlantılar paylaşır.
    transcriber = NemotronTranscriber(args.model, args.device, args.language)

    server = AsyncServer.from_uri(args.uri)
    _LOGGER.info("Nemotron Wyoming sunucusu dinliyor: %s", args.uri)
    await server.run(partial(NemotronEventHandler, transcriber))


if __name__ == "__main__":
    asyncio.run(main())
