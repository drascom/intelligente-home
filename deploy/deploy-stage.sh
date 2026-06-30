#!/usr/bin/env bash
# oracle-stage (public VPS 132.145.24.135) deploy — SADECE LiveKit.
# .25'in STT/TTS/LLM servislerine ASLA DOKUNMAZ (onlar deploy-gpu.sh ile, ayrı host).
# (Brain decommission edildi — Hermes-only; HA artık hermes-homeassistant plugin'inde.)
# Tetikleyici: .github/workflows/deploy.yml `deploy-stage` job → bulut runner SSH ile
# `ubuntu@132.145.24.135` üzerinde `sudo deploy/deploy-stage.sh`. Manuel de çalışır.
# git reset --hard origin/main → systemd unit sync → (gerekirse) livekit restart.
set -euo pipefail
REPO=/opt/intelligente-home
cd "$REPO"

BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
git fetch -q origin main
git reset --hard -q origin/main   # venv'ler gitignore'da
AFTER=$(git rev-parse HEAD)
echo "deploy-stage: ${BEFORE:0:7} -> ${AFTER:0:7}"

changed() { [ "$BEFORE" = none ] || git diff --name-only "$BEFORE" "$AFTER" | grep -q "$1"; }

# systemd unit'leri senkronla (livekit bu sunucuda)
if changed 'deploy/systemd/'; then
  echo "→ systemd unit'leri güncelleniyor"; cp deploy/systemd/*.service /etc/systemd/system/ 2>/dev/null || true; systemctl daemon-reload
fi

# LiveKit: yalnız systemd unit'i değişince restart (config /etc/livekit/livekit.yaml repo DIŞI → manuel)
if changed 'deploy/systemd/livekit.service'; then
  echo "→ livekit restart (unit değişti)"; systemctl restart livekit || true
fi

echo "✓ deploy-stage bitti"
