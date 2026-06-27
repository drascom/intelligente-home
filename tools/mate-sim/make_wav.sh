#!/usr/bin/env bash
# Türkçe test cümlesinden 48kHz mono 16-bit WAV üretir (macOS native: say + afconvert).
# Kullanım: ./make_wav.sh "Candan, merhaba, bugün nasılsın?" prompt.wav
set -euo pipefail
TEXT="${1:-Candan, merhaba, bugün nasılsın?}"
OUT="${2:-prompt.wav}"
DIR="$(cd "$(dirname "$0")" && pwd)"
AIFF="$(mktemp -t matesim).aiff"
# Yelda = tr_TR sesi (yoksa default sese düşülür)
say -v Yelda -o "$AIFF" "$TEXT" 2>/dev/null || say -o "$AIFF" "$TEXT"
afconvert -f WAVE -d LEI16@48000 -c 1 "$AIFF" "$DIR/$OUT"
rm -f "$AIFF"
echo "wrote $DIR/$OUT"
