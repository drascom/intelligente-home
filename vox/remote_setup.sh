#!/usr/bin/env bash
# remote_setup.sh — VPS'te (Debian 12 + RTX 3090) çalışır. deploy.sh tetikler.
# Idempotent: tekrar tekrar çalıştırılabilir.
set -euo pipefail

DEST="${VOX_DEST:-/opt/vox}"
cd "$DEST"

echo "==> Sistem paketleri (python venv/pip)"
if ! dpkg -s python3-venv >/dev/null 2>&1 || ! dpkg -s python3-pip >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y python3-venv python3-pip
fi

echo "==> venv"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip wheel

echo "==> PyTorch (CUDA) — driver CUDA 13 ile uyumlu cu124 wheel"
python -c "import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null \
  || pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu124

echo "==> Uygulama bağımlılıkları"
# requirements.txt'teki torch pini (Mac sürümü) ve gradio (sunucuda gereksiz)
# CUDA torch'unu ezmesin diye filtrelenir; gerisi pinli kurulur.
if [ -f requirements.txt ]; then
  grep -viE '^[[:space:]]*(torch|torchaudio|gradio)([=<>!~ ].*)?$' requirements.txt > /tmp/req.server.txt
  pip install -r /tmp/req.server.txt
else
  pip install voxcpm soundfile fastapi "uvicorn[standard]" numpy pydantic
fi

echo "==> Modeli önceden indir (huggingface, Xet kapalı)"
export HF_HUB_DISABLE_XET=1 HF_HUB_ENABLE_HF_TRANSFER=0 HF_HUB_DOWNLOAD_TIMEOUT=30
if ! python - <<'PY' 2>/dev/null
from huggingface_hub import snapshot_download
import os
# Yalnızca tamamen inmişse hızlı geçer; eksikse indirir (yeniden denemeli).
snapshot_download("openbmb/VoxCPM2")
PY
then
  for i in $(seq 1 30); do
    echo "[model indirme denemesi $i]"
    python - <<'PY' && break
from huggingface_hub import snapshot_download
snapshot_download("openbmb/VoxCPM2")
PY
    sleep 3
  done
fi

echo "==> systemd servisi"
cp -f vox-tts.service /etc/systemd/system/vox-tts.service
sed -i "s#__DEST__#$DEST#g" /etc/systemd/system/vox-tts.service
systemctl daemon-reload
systemctl enable vox-tts
systemctl restart vox-tts
sleep 2
systemctl --no-pager status vox-tts | head -15 || true
