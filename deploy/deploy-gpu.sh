#!/usr/bin/env bash
# .25 (ev LAN GPU box 192.168.0.25, hostname "ollama") deploy — SADECE STT/TTS/LLM
# + dashboard. brain/LiveKit'e ASLA DOKUNMAZ (onlar oracle-stage'de, deploy-stage.sh).
#
# .25 self-hosted CI runner KALDIRILDI (2026-06-25) → bu script MANUEL çalışır.
# Ev LAN'ından:
#   ssh root@192.168.0.25 'cd /opt/intelligente-home && sudo deploy/deploy-gpu.sh'
#
# git reset --hard origin/main → değişen vox bağımlılıkları → dashboard build →
# systemd unit sync → değişen STT/TTS/LLM servislerini restart. brain YOK → health yok.
set -euo pipefail
REPO=/opt/intelligente-home
cd "$REPO"

BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
git fetch -q origin main
git reset --hard -q origin/main
AFTER=$(git rev-parse HEAD)
echo "deploy-gpu: ${BEFORE:0:7} -> ${AFTER:0:7}"

changed() { [ "$BEFORE" = none ] || git diff --name-only "$BEFORE" "$AFTER" | grep -q "$1"; }

# vox (TTS) python bağımlılıkları
if changed 'vox/requirements.txt'; then
  echo "→ vox requirements değişti, kuruluyor"; vox/.venv/bin/pip install -q -r vox/requirements.txt
fi

# dashboard (mate-dash) kaynağı değiştiyse derle + restart
if systemctl cat mate-dash.service >/dev/null 2>&1 && changed 'mate-dash/'; then
  echo "→ mate-dash değişti, derleniyor"
  (cd mate-dash && npm install --no-audit --no-fund -s && npm run build)
  systemctl restart mate-dash || true
fi

# systemd unit'leri senkronla (whisper/vox/vllm/nemotron bu sunucuda)
if changed 'deploy/systemd/'; then
  echo "→ systemd unit'leri güncelleniyor"; cp deploy/systemd/*.service /etc/systemd/system/ 2>/dev/null || true; systemctl daemon-reload
fi

# TTS (vox 8808): kod değişince
changed 'vox/' && { echo "→ vox restart"; systemctl restart vox; } || true
# STT (whisper 10300): unit değişince
changed 'deploy/systemd/whisper.service' && { echo "→ whisper restart"; systemctl restart whisper; } || true
# LLM (vllm): model/arg (unit) değişince
changed 'deploy/systemd/vllm.service' && { echo "→ vllm restart (model/arg değişti)"; systemctl restart vllm; } || true
# Nemotron yan-STT (10301): unit veya server.py değişince. Whisper'a (10300) DOKUNMAZ.
if changed 'deploy/systemd/nemotron.service' || changed 'deploy/nemotron/'; then
  echo "→ nemotron enable+restart"; systemctl enable nemotron >/dev/null 2>&1 || true; systemctl restart nemotron || true
fi

echo "✓ .25 (STT/TTS/LLM/dash) deploy tamam"
