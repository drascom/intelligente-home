"""Speaker-ID (voice-ID): sherpa-onnx ile ses parmak-izinden kişi tanıma.

Kapalı küme (ev: birkaç kişi) + "unknown" reddi. Embedding çıkarımı sherpa-onnx
`SpeakerEmbeddingExtractor` ile; eşleştirme burada elle (kosinüs + eşik + marj
kuralı) yapılır — `SpeakerEmbeddingManager.search` skor döndürmediği için marj
kuralını (en iyi eşleşme 2.'yi `margin` kadar geçmeli) uygulayamıyoruz.

Embedding'ler DB'de HAM float32 baytlar olarak saklanır; normalize etme burada,
bellekteki centroid kurulumunda ve sorgu anında yapılır.

sherpa-onnx kurulu değilse / model yoksa / kapalıysa `build_speaker_id` None döner
ve çağıran taraf speaker-ID'yi atlar (intent fast-path gibi graceful degrade).
"""

import logging
import threading

import numpy as np

log = logging.getLogger("brain.voice.speaker")


def _l2(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def pcm_to_f32(pcm: bytes, width: int, channels: int) -> np.ndarray:
    """Ham PCM baytlarını [-1,1] float32 mono diziye çevir (s16le veya f32le)."""
    if width == 2:
        a = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 4:
        a = np.frombuffer(pcm, dtype="<f4").astype(np.float32)
    else:
        raise ValueError(f"desteklenmeyen örnek genişliği: {width}")
    if channels > 1:
        a = a.reshape(-1, channels).mean(axis=1)
    return np.ascontiguousarray(a)


def emb_to_bytes(emb: np.ndarray) -> bytes:
    return emb.astype("<f4").tobytes()


class SpeakerID:
    """Tek bir embedding modelini sarar; enroll edilmiş kişilere karşı tanır."""

    def __init__(
        self,
        model_path: str,
        model_id: str,
        threshold: float = 0.6,
        margin: float = 0.05,
        num_threads: int = 1,
    ):
        import sherpa_onnx

        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=model_path, num_threads=num_threads, provider="cpu"
        )
        self._ex = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
        self.dim: int = self._ex.dim
        self.model_id = model_id
        self.threshold = threshold
        self.margin = margin
        self._lock = threading.Lock()  # extractor stream'i seri kullanılsın
        self._names: list[str] = []
        self._centroids = np.zeros((0, self.dim), dtype=np.float32)  # L2-normalize
        self._name_to_id: dict[str, int] = {}  # session routing için (user-<id>)

    # ---- embedding ----

    def embed_samples(self, samples: np.ndarray, sample_rate: int) -> np.ndarray:
        """float32 mono dalga → ham embedding (normalize edilmemiş). sherpa,
        sample_rate 16k değilse içeride resample eder."""
        with self._lock:
            stream = self._ex.create_stream()
            stream.accept_waveform(sample_rate=sample_rate, waveform=samples)
            stream.input_finished()
            return np.array(self._ex.compute(stream), dtype=np.float32)

    def embed_pcm(self, pcm: bytes, sample_rate: int, width: int, channels: int) -> np.ndarray:
        return self.embed_samples(pcm_to_f32(pcm, width, channels), sample_rate)

    # ---- tanıma ----

    def identify(self, emb: np.ndarray) -> tuple[str | None, float]:
        """En iyi eşleşmeyi döndür. Eşik altı VEYA 2.'yi marj kadar geçmiyorsa
        (None, skor) = unknown."""
        if self._centroids.shape[0] == 0:
            return None, 0.0
        q = _l2(np.asarray(emb, dtype=np.float32))
        sims = self._centroids @ q  # centroid'ler zaten L2-normalize
        order = np.argsort(sims)[::-1]
        ranking = [(self._names[i], float(sims[i])) for i in order]
        # Teşhis: her kişinin skoru (eşik/marj ayarı için) — wake-gated, düşük hacim.
        log.info("speaker-ID skorlar: %s (eşik=%.2f marj=%.2f)",
                 ", ".join(f"{n}={s:.3f}" for n, s in ranking),
                 self.threshold, self.margin)
        best = ranking[0][1]
        second = ranking[1][1] if len(ranking) > 1 else -1.0
        if best < self.threshold or (best - second) < self.margin:
            return None, best
        return ranking[0][0], best

    def num_speakers(self) -> int:
        return len(self._names)

    def id_for(self, name: str | None) -> int | None:
        """Tanınan ismin DB speaker id'si (session'ı user-<id>'ye yönlendirmek için)."""
        return self._name_to_id.get(name) if name else None

    def reload(self, speakers: list[dict]) -> None:
        """DB'deki kişileri belleğe al. Her kişi: örnek embedding'leri normalize
        et, ortala, normalize et = centroid. model_id/dim uyuşmayan kişiyi atla
        (tutarlılık kilidi)."""
        names: list[str] = []
        cents: list[np.ndarray] = []
        name_to_id: dict[str, int] = {}
        for sp in speakers:
            if sp.get("model_id") and sp["model_id"] != self.model_id:
                log.warning(
                    "speaker %r model_id uyuşmuyor (%s != %s) — atlanıyor",
                    sp.get("name"), sp["model_id"], self.model_id,
                )
                continue
            embs = []
            for b in sp.get("embeddings", []):
                v = np.frombuffer(b, dtype="<f4").astype(np.float32)
                if v.shape[0] != self.dim:
                    continue
                embs.append(_l2(v))
            if not embs:
                continue
            cents.append(_l2(np.mean(np.stack(embs), axis=0)))
            names.append(sp["name"])
            if sp.get("id") is not None:
                name_to_id[sp["name"]] = sp["id"]
        self._names = names
        self._name_to_id = name_to_id
        self._centroids = (
            np.stack(cents) if cents else np.zeros((0, self.dim), dtype=np.float32)
        )
        log.info("speaker-ID: %d kişi yüklendi (%s)", len(names), ", ".join(names) or "—")


def build_speaker_id(settings) -> "SpeakerID | None":
    """Ayarlara göre SpeakerID kur; kapalı/eksikse None (graceful degrade)."""
    if not getattr(settings, "speaker_id_enabled", False):
        return None
    if not settings.speaker_model_path:
        log.warning("SPEAKER_ID_ENABLED açık ama SPEAKER_MODEL_PATH boş — kapalı")
        return None
    try:
        sp = SpeakerID(
            settings.speaker_model_path,
            settings.speaker_model_id,
            settings.speaker_threshold,
            settings.speaker_margin,
        )
        log.info(
            "speaker-ID etkin: %s (dim=%d, eşik=%.2f, marj=%.2f)",
            settings.speaker_model_path, sp.dim, sp.threshold, sp.margin,
        )
        return sp
    except Exception as e:
        log.warning("speaker-ID başlatılamadı (%s) — kapalı", e)
        return None
