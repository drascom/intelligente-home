#!/usr/bin/env python3
"""
audiobook.py — Convert a long text file (e.g. a Turkish book) into a single
audiobook .wav using VoxCPM2.

VoxCPM2 supports Turkish natively (no language tag needed). Because the model
works best on sentence-/paragraph-sized inputs, this script splits the book
into chunks, synthesizes each one, and concatenates the result.

Usage:
    # Default voice
    python audiobook.py book.txt -o book.wav

    # Clone a reference voice (record/keep a short clean clip, ~5-15s)
    python audiobook.py book.txt -o book.wav --reference voice.wav --ref-text "Bu kayıttaki konuşmanın metni."

    # Tuning
    python audiobook.py book.txt -o book.wav --cfg 2.0 --timesteps 10
"""
import argparse
import re
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from voxcpm import VoxCPM


def split_text(text: str, max_chars: int = 300):
    """Split text into chunks at sentence boundaries, keeping each chunk
    under max_chars. Falls back to splitting very long sentences on commas."""
    # Normalize whitespace, keep paragraph breaks as sentence boundaries.
    text = text.replace("\r\n", "\n")
    # Split into sentences on ., !, ?, … and newlines, keeping it simple.
    pieces = re.split(r"(?<=[.!?…])\s+|\n+", text)
    pieces = [p.strip() for p in pieces if p.strip()]

    chunks = []
    buf = ""
    for piece in pieces:
        # If a single sentence is huge, hard-split it on commas/spaces.
        if len(piece) > max_chars:
            sub = re.split(r"(?<=[,;:])\s+", piece)
            for s in sub:
                if len(buf) + len(s) + 1 <= max_chars:
                    buf = (buf + " " + s).strip()
                else:
                    if buf:
                        chunks.append(buf)
                    buf = s
            continue
        if len(buf) + len(piece) + 1 <= max_chars:
            buf = (buf + " " + piece).strip()
        else:
            if buf:
                chunks.append(buf)
            buf = piece
    if buf:
        chunks.append(buf)
    return chunks


def main():
    ap = argparse.ArgumentParser(description="Convert a text file to an audiobook with VoxCPM2.")
    ap.add_argument("input", help="Path to the input .txt file (UTF-8).")
    ap.add_argument("-o", "--output", default="audiobook.wav", help="Output .wav path.")
    ap.add_argument("--reference", help="Optional reference .wav for voice cloning.")
    ap.add_argument("--ref-text", help="Transcript of the reference audio (improves cloning).")
    ap.add_argument("--cfg", type=float, default=2.0, help="cfg_value (default 2.0).")
    ap.add_argument("--timesteps", type=int, default=10, help="inference_timesteps (default 10).")
    ap.add_argument("--max-chars", type=int, default=300, help="Max characters per chunk (default 300).")
    ap.add_argument("--gap-ms", type=int, default=300, help="Silence between chunks in ms (default 300).")
    args = ap.parse_args()

    text = Path(args.input).read_text(encoding="utf-8")
    chunks = split_text(text, max_chars=args.max_chars)
    if not chunks:
        sys.exit("No text found in input file.")
    print(f"Split into {len(chunks)} chunks.")

    print("Loading VoxCPM2 (first run downloads ~3 GB)...")
    model = VoxCPM.from_pretrained("openbmb/VoxCPM2", load_denoiser=False)
    sr = model.tts_model.sample_rate

    gen_kwargs = dict(cfg_value=args.cfg, inference_timesteps=args.timesteps)
    if args.reference:
        gen_kwargs["reference_wav_path"] = args.reference
        if args.ref_text:
            gen_kwargs["reference_text"] = args.ref_text

    gap = np.zeros(int(sr * args.gap_ms / 1000), dtype=np.float32)
    audio_parts = []
    t0 = time.time()
    for i, chunk in enumerate(chunks, 1):
        print(f"[{i}/{len(chunks)}] {chunk[:60]!r}...")
        wav = model.generate(text=chunk, **gen_kwargs)
        audio_parts.append(np.asarray(wav, dtype=np.float32))
        audio_parts.append(gap)

    full = np.concatenate(audio_parts)
    sf.write(args.output, full, sr)
    mins = len(full) / sr / 60
    print(f"\nDone in {time.time()-t0:.0f}s. Wrote {args.output} "
          f"({mins:.1f} min of audio at {sr} Hz).")


if __name__ == "__main__":
    main()
