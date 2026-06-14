"""Intent fast-path: classify the utterance before the LLM tool loop.

High-confidence `sohbet` (chitchat) skips the device tools entirely — one
plain LLM call instead of the multi-round tool loop. Everything else
(eylem/soru/abstain) takes the full agent path.

The E5 model (~470MB, CPU) loads in the background at startup; until it's
ready — or if sentence-transformers isn't installed — `classify` returns
None and every utterance routes to the full agent. Vendored from
`intent-lab/` (see docs/PRIOR_WORK.md); the lab keeps the eval harness.
"""

import asyncio
import logging

log = logging.getLogger("brain.intent")


class IntentRouter:
    def __init__(self, reject_below_margin: float = 0.03, bus=None):
        self.reject_below_margin = reject_below_margin
        self._clf = None
        self.bus = bus  # EventBus or None (izleme düzlemi)

    @property
    def ready(self) -> bool:
        return self._clf is not None

    async def start(self) -> None:
        """Load model + fit examples off the event loop. Safe to fire-and-forget."""
        try:
            self._clf = await asyncio.to_thread(self._build)
            log.info("intent fast-path ready (multilingual-e5-small)")
        except ImportError:
            log.warning(
                "sentence-transformers not installed — intent fast-path disabled, "
                "all utterances take the full agent path"
            )
        except Exception:
            log.exception("intent classifier failed to load — fast-path disabled")

    @staticmethod
    def _build():
        from brain.intent.examples import INTENTS
        from brain.intent.rules import HybridClassifier

        clf = HybridClassifier()
        clf.fit(INTENTS)
        return clf

    def classify(self, text: str):
        """Prediction or None (not ready / unavailable)."""
        if self._clf is None or not text.strip():
            return None
        pred = self._clf.classify(text, reject_below_margin=self.reject_below_margin)
        log.info(
            "intent %r -> %s (score=%.3f margin=%.3f%s)",
            text, pred.label, pred.score, pred.margin,
            " ABSTAIN" if pred.abstain else "",
        )
        if self.bus:
            label = "abstain" if pred.abstain else pred.label
            self.bus.emit("intent", "intent", f"{label} ({pred.score:.2f})",
                          payload={"text": text, "label": pred.label,
                                   "score": pred.score, "margin": pred.margin,
                                   "abstain": pred.abstain})
        return pred
