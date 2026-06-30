#!/usr/bin/env bash
# Test sunucusu (Ubuntu 24.04 LXC, GPU host'tan bind-mount) TEK SEFERLİK kurulum.
# root olarak çalıştır. Idempotent (tekrar çalıştırılabilir).
#
#   curl -fsSL https://raw.githubusercontent.com/drascom/intelligente-home/main/deploy/server-bootstrap.sh | bash
#   (ya da repo klonluyken: bash deploy/server-bootstrap.sh)
set -euo pipefail
REPO=/opt/intelligente-home
ETC=/etc/intelligente-home
export DEBIAN_FRONTEND=noninteractive

echo "==> 1) apt bağımlılıkları"
apt-get update -qq
apt-get install -y -qq python3-venv python3-dev build-essential git ffmpeg libsndfile1 curl tmux

echo "==> 2) repo"
if [ -d "$REPO/.git" ]; then (cd "$REPO" && git fetch -q && git reset --hard -q origin/main); else
  git clone -q https://github.com/drascom/intelligente-home "$REPO"; fi
cd "$REPO"

echo "==> 3) venv'ler + bağımlılıklar (uzun sürer)"
python3 -m venv /opt/whisper-venv && /opt/whisper-venv/bin/pip install -qU pip \
  && /opt/whisper-venv/bin/pip install -q wyoming-faster-whisper nvidia-cublas-cu12 nvidia-cudnn-cu12
python3 -m venv vox/.venv && vox/.venv/bin/pip install -qU pip \
  && vox/.venv/bin/pip install -q -r vox/requirements.txt
python3 -m venv /opt/vllm-venv && /opt/vllm-venv/bin/pip install -qU pip \
  && /opt/vllm-venv/bin/pip install -q vllm

echo "==> 4) systemd unit'leri"
mkdir -p "$ETC"
cp deploy/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable vllm whisper vox

echo "==> BİTTİ. Başlat: systemctl start vllm whisper vox"
echo "   İlk vLLM başlatması model indirir (~birkaç dk)."
