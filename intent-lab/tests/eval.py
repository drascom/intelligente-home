"""Batch değerlendirme — dataset.json üzerinde E5 + intent-lab.

900 sentetik cümle (baba/anne/kız × eylem/soru/sohbet) üzerinde doğruluk.
Persona ve intent kırılımları ayrı raporlanır.

Kullanım:
    python tests/eval.py                  # tüm dataset
    python tests/eval.py --persona kiz    # sadece kız
    python tests/eval.py --intent sohbet  # sadece sohbet
    python tests/eval.py --errors         # sadece hatalı sınıflandırmaları göster
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from classifier import IntentClassifier, Prediction  # noqa: E402
from hybrid import HybridClassifier  # noqa: E402
from intents import INTENTS  # noqa: E402

DATASET_PATH = Path(__file__).resolve().parent.parent / "dataset.json"
# 0.03 eşiği eval'da %50+ abstain üretiyordu — 900 utterance'ın yarısına
# "belirsiz" demek production'da kötü UX. 0.01 daha gerçekçi: gerçek
# margin çakışmalarını yakalar, gürültüye değil.
DEFAULT_REJECT_BELOW = 0.01


def load_dataset(
    persona_filter: str | None = None,
    intent_filter: str | None = None,
) -> list[dict]:
    with open(DATASET_PATH, encoding="utf-8") as f:
        data = json.load(f)
    rows = data["utterances"]
    if persona_filter:
        rows = [r for r in rows if r["persona"] == persona_filter]
    if intent_filter:
        rows = [r for r in rows if r["intent"] == intent_filter]
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--persona", choices=("baba", "anne", "kiz"))
    ap.add_argument("--intent", choices=("eylem", "soru", "sohbet"))
    ap.add_argument("--errors", action="store_true",
                    help="sadece yanlış sınıflandırılan satırları göster")
    ap.add_argument("--show", type=int, default=0,
                    help="ilk N satırı detaylı yazdır (default: 0)")
    ap.add_argument("--threshold", type=float, default=DEFAULT_REJECT_BELOW,
                    help=f"abstain margin eşiği (default: {DEFAULT_REJECT_BELOW})")
    ap.add_argument("--mode", choices=("hybrid", "e5"), default="hybrid",
                    help="hybrid (default) = E5 + Türkçe kurallar; "
                         "e5 = saf E5 (karşılaştırma için)")
    args = ap.parse_args()

    print(f"Sınıflandırıcı yükleniyor (mod: {args.mode})...")
    if args.mode == "hybrid":
        clf = HybridClassifier()
    else:
        clf = IntentClassifier()
    clf.fit(INTENTS)
    print(f"  training: {sum(len(v) for v in INTENTS.values())} örnek, "
          f"{len(INTENTS)} sınıf")

    rows = load_dataset(args.persona, args.intent)
    print(f"  eval: {len(rows)} cümle "
          f"(persona={args.persona or 'all'}, intent={args.intent or 'all'})")
    print()

    # Stats
    correct = 0
    abstained = 0
    by_persona: dict[str, list[int]] = defaultdict(lambda: [0, 0])  # [correct, total]
    by_intent: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    confusion: dict[tuple[str, str], int] = defaultdict(int)  # (true, pred) -> count
    errors: list[tuple[dict, Prediction]] = []

    for i, row in enumerate(rows):
        text = row["text"]
        truth = row["intent"]
        persona = row["persona"]

        pred = clf.classify(text, reject_below_margin=args.threshold)
        ok = pred.label == truth

        correct += int(ok)
        abstained += int(pred.abstain)
        by_persona[persona][0] += int(ok)
        by_persona[persona][1] += 1
        by_intent[truth][0] += int(ok)
        by_intent[truth][1] += 1
        confusion[(truth, pred.label)] += 1

        if not ok:
            errors.append((row, pred))

        if args.show and i < args.show:
            mark = "✓" if ok else "✗"
            tag = " [?]" if pred.abstain else ""
            print(f"{mark} {truth:6s} → {pred.label:6s} "
                  f"s={pred.score:.2f} m={pred.margin:+.2f}{tag}  "
                  f"[{persona}] {text}")

    n = len(rows)
    if n == 0:
        print("Eval boş — filtre çok dar mı?")
        return 1

    print("=" * 80)
    print(f"GENEL DOĞRULUK: {correct}/{n} = {correct/n:.1%}  "
          f"(abstain: {abstained})")
    print()

    print("PERSONA BAZINDA:")
    for p, (c, t) in sorted(by_persona.items()):
        print(f"  {p:5s}: {c}/{t} = {c/t:.1%}")
    print()

    print("INTENT BAZINDA:")
    for i, (c, t) in sorted(by_intent.items()):
        print(f"  {i:6s}: {c}/{t} = {c/t:.1%}")
    print()

    print("CONFUSION MATRIX (satır=gerçek, sütun=tahmin):")
    intents = sorted({k[0] for k in confusion.keys()} | {k[1] for k in confusion.keys()})
    header = " " * 10 + "  ".join(f"{i:>7s}" for i in intents)
    print(header)
    for true in intents:
        row = f"  {true:6s}  " + "  ".join(
            f"{confusion.get((true, pred), 0):>7d}" for pred in intents
        )
        print(row)
    print()

    if errors and (args.errors or len(errors) <= 30):
        print(f"HATALAR ({len(errors)}):")
        for row, pred in errors:
            print(f"  exp={row['intent']:6s} got={pred.label:6s} "
                  f"s={pred.score:.2f} m={pred.margin:+.2f}  "
                  f"[{row['persona']}] {row['text']}")
    elif errors:
        print(f"({len(errors)} hata var — '--errors' ile detayı göster)")

    return 0 if correct == n else 1


if __name__ == "__main__":
    sys.exit(main())
