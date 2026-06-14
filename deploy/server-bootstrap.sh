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
python3 -m venv mate-brain/.venv && mate-brain/.venv/bin/pip install -qU pip \
  && mate-brain/.venv/bin/pip install -q -r mate-brain/brain/requirements.txt
python3 -m venv /opt/whisper-venv && /opt/whisper-venv/bin/pip install -qU pip \
  && /opt/whisper-venv/bin/pip install -q wyoming-faster-whisper nvidia-cublas-cu12 nvidia-cudnn-cu12
python3 -m venv vox/.venv && vox/.venv/bin/pip install -qU pip \
  && vox/.venv/bin/pip install -q -r vox/requirements.txt
python3 -m venv /opt/vllm-venv && /opt/vllm-venv/bin/pip install -qU pip \
  && /opt/vllm-venv/bin/pip install -q vllm

echo "==> 4) prod env iskeleti"
mkdir -p "$ETC"
if [ ! -f "$ETC/brain.env" ]; then
  cp deploy/brain.env.example "$ETC/brain.env"
  # Repo'daki dev .env'den gerçek HA/MQTT değerlerini taşı (varsa)
  DEV=mate-brain/.env
  if [ -f "$DEV" ]; then
    for k in HA_TOKEN MQTT_PASSWORD; do
      v=$(grep -E "^$k=" "$DEV" | head -1 | cut -d= -f2-)
      [ -n "$v" ] && sed -i "s|^$k=CHANGE_ME|$k=$v|" "$ETC/brain.env"
    done
  fi
  # Rastgele admin token
  sed -i "s|^BRAIN_ADMIN_TOKEN=CHANGE_ME|BRAIN_ADMIN_TOKEN=$(openssl rand -hex 24)|" "$ETC/brain.env"
  echo "   → $ETC/brain.env oluşturuldu (CHANGE_ME kalanları doldur)"
fi

echo "==> 5) systemd unit'leri"
cp deploy/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable vllm whisper vox brain

echo "==> BİTTİ. Başlat: systemctl start vllm whisper vox brain"
echo "   İlk vLLM başlatması model indirir (~birkaç dk). Sağlık: curl localhost:8800/api/health"
