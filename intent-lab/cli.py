"""Tek cümle için niyet sınıflandırma.

Kullanım:
    python cli.py "salondaki ışığı aç"        # hibrit (varsayılan)
    python cli.py --mode e5 "hava nasıl?"     # saf E5 karşılaştırma
"""

from __future__ import annotations

import argparse
import sys

from classifier import IntentClassifier
from hybrid import HybridClassifier
from intents import INTENTS

REJECT_BELOW = 0.01


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=("hybrid", "e5"), default="hybrid")
    ap.add_argument("text", nargs="+")
    args = ap.parse_args()

    text = " ".join(args.text).strip()
    if not text:
        print("boş metin", file=sys.stderr); return 1

    clf = HybridClassifier() if args.mode == "hybrid" else IntentClassifier()
    clf.fit(INTENTS)
    pred = clf.classify(text, reject_below_margin=REJECT_BELOW)

    print(f"metin       : {text}")
    print(f"mod         : {args.mode}")
    print(f"niyet       : {pred.label}  (skor {pred.score:.3f})"
          + ("  [BELİRSİZ]" if pred.abstain else ""))
    print(f"runner-up   : {pred.runner_up}  (skor {pred.runner_up_score:.3f})")
    print(f"fark        : {pred.margin:.3f}")
    print(f"detay       : {pred.nearest_example}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
