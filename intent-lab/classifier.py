"""multilingual-e5-small tabanlı niyet sınıflandırıcı.

Mantık:
1. Her sınıfın örnek cümleleri E5 ile vektöre çevrilir (normalize edilmiş).
2. Yeni bir cümle geldiğinde aynı şekilde vektöre çevrilir.
3. Her sınıf için, sınıfın örnekleri ile en yüksek cosine benzerliği bulunur.
4. En yüksek skorlu sınıf seçilir; ikincisiyle arasındaki fark "güven payı"dır.

E5 modelleri, asimetrik retrieval için "query: " / "passage: " önekleri ister.
Bizim görev simetrik (cümle-cümle benzerliği) — bu durumda her iki tarafta da
"query: " kullanmak best practice (E5 paper, sec. 3.2).

Model ilk kullanımda HuggingFace'ten indirilir (~470MB, ~/.cache/huggingface/).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

import numpy as np
from sentence_transformers import SentenceTransformer

DEFAULT_MODEL = "intfloat/multilingual-e5-small"
QUERY_PREFIX = "query: "


@dataclass
class Prediction:
    label: str
    score: float
    runner_up: str
    runner_up_score: float
    nearest_example: str
    abstain: bool = False  # True ise margin eşiğin altında — "belirsiz"

    @property
    def margin(self) -> float:
        return self.score - self.runner_up_score


class IntentClassifier:
    def __init__(self, model_name: str = DEFAULT_MODEL) -> None:
        self.model = SentenceTransformer(model_name)
        self._class_embeddings: dict[str, np.ndarray] = {}
        self._class_examples: dict[str, list[str]] = {}

    def _encode(self, texts: Iterable[str]) -> np.ndarray:
        prefixed = [f"{QUERY_PREFIX}{t}" for t in texts]
        return self.model.encode(
            prefixed,
            normalize_embeddings=True,
            convert_to_numpy=True,
            show_progress_bar=False,
        )

    def fit(self, examples_by_class: dict[str, list[str]]) -> None:
        for cls, texts in examples_by_class.items():
            if not texts:
                raise ValueError(f"'{cls}' sınıfı için örnek yok")
            self._class_examples[cls] = list(texts)
            self._class_embeddings[cls] = self._encode(texts)

    def classify(
        self,
        text: str,
        reject_below_margin: float | None = None,
    ) -> Prediction:
        """Cümleyi sınıflandır.

        reject_below_margin verilirse, top ile runner-up arasındaki fark bu
        eşiğin altında kaldığında Prediction.abstain=True olarak işaretlenir
        (label yine en yüksek skorlu sınıftır — çağıran karar verir).
        """
        if not self._class_embeddings:
            raise RuntimeError("Önce fit() çağırmalısın")

        q = self._encode([text])[0]

        scored: list[tuple[str, float, str]] = []
        for cls, emb in self._class_embeddings.items():
            sims = emb @ q  # normalize edildiği için cosine = dot product
            best_idx = int(np.argmax(sims))
            scored.append((cls, float(sims[best_idx]), self._class_examples[cls][best_idx]))

        scored.sort(key=lambda x: -x[1])
        top_cls, top_score, nearest = scored[0]
        runner_cls, runner_score, _ = scored[1] if len(scored) > 1 else (top_cls, 0.0, "")

        pred = Prediction(
            label=top_cls,
            score=top_score,
            runner_up=runner_cls,
            runner_up_score=runner_score,
            nearest_example=nearest,
        )
        if reject_below_margin is not None and pred.margin < reject_below_margin:
            pred.abstain = True
        return pred
