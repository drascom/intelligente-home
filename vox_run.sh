#!/bin/sh
# Dev TTS service: vox (VoxCPM2 bridge, Mac/MPS), port 8808.
# Kendi alt-projesinde çalışır: vox/.venv + vox/.env.
cd "$(dirname "$0")/vox"
set -a; [ -f .env ] && . ./.env; set +a
export VOX_STANDARD_VOICE="${VOX_STANDARD_VOICE:-nese}"
# Sesli asistan gecikmesi: küçük parça = ilk ses daha erken başlar
# (varsayılan 300 karakterde tüm cevap tek parça üretiliyordu).
export VOX_MAX_CHARS="${VOX_MAX_CHARS:-120}"
exec .venv/bin/python server.py
