#!/usr/bin/env bash
# deploy.sh — vox/ projesini rsync ile VPS'e gönderip kurulumu tetikler.
# Mac'ten çalıştır:  bash deploy.sh
set -euo pipefail

HOST="${VOX_HOST:-root@192.168.0.150}"
DEST="${VOX_DEST:-/opt/vox}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> rsync $HERE/ -> $HOST:$DEST/"
rsync -az --delete \
  --exclude '.venv/' \
  --exclude '__pycache__/' \
  --exclude '.gradio/' \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude '.env' \
  --exclude '*.pyc' \
  --exclude 'turkce_test.wav' \
  --exclude 'zaman_sample.wav' \
  --exclude 'zaman_sample.txt' \
  --exclude 'zaman_uzerine_full.txt' \
  "$HERE/" "$HOST:$DEST/"

echo "==> VPS'te kurulum + servis (remote_setup.sh)"
ssh "$HOST" "cd $DEST && bash remote_setup.sh"

echo "==> Bitti. Sağlık kontrolü:"
ssh "$HOST" "curl -s http://127.0.0.1:8808/health || true"
echo
