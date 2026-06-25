#!/usr/bin/env bash
# oracle-stage (public VPS 132.145.24.135) deploy — SADECE brain + LiveKit.
# .25'in STT/TTS/LLM servislerine ASLA DOKUNMAZ (onlar deploy-gpu.sh ile, ayrı host).
# Tetikleyici: .github/workflows/deploy.yml `deploy-stage` job → bulut runner SSH ile
# `ubuntu@132.145.24.135` üzerinde `sudo deploy/deploy-stage.sh`. Manuel de çalışır.
# git reset --hard origin/main → değişen brain bağımlılıkları → systemd unit sync →
# (gerekirse) livekit restart → brain restart → /api/health (başarısız=exit 1, CI kırmızı).
set -euo pipefail
REPO=/opt/intelligente-home
cd "$REPO"

BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
git fetch -q origin main
git reset --hard -q origin/main   # mate-brain/.env dev'e döner ama EnvironmentFile ezer; venv'ler gitignore'da
AFTER=$(git rev-parse HEAD)
echo "deploy-stage: ${BEFORE:0:7} -> ${AFTER:0:7}"

changed() { [ "$BEFORE" = none ] || git diff --name-only "$BEFORE" "$AFTER" | grep -q "$1"; }

# brain python bağımlılıkları değiştiyse kur
if changed 'mate-brain/brain/requirements.txt'; then
  echo "→ brain requirements değişti, kuruluyor"; mate-brain/.venv/bin/pip install -q -r mate-brain/brain/requirements.txt
fi
# LLM istemcisi (pi/Codex subprocess brain İÇİNDE çalışır; model .25'te ama RPC client burada)
if changed 'mate-brain/package.json'; then
  echo "→ pi/npm bağımlılıkları değişti, kuruluyor"; (cd mate-brain && npm install --no-audit --no-fund -s)
fi

# systemd unit'leri senkronla (brain + livekit bu sunucuda)
if changed 'deploy/systemd/'; then
  echo "→ systemd unit'leri güncelleniyor"; cp deploy/systemd/*.service /etc/systemd/system/ 2>/dev/null || true; systemctl daemon-reload
fi

# LiveKit: yalnız systemd unit'i değişince restart (config /etc/livekit/livekit.yaml repo DIŞI → manuel)
if changed 'deploy/systemd/livekit.service'; then
  echo "→ livekit restart (unit değişti)"; systemctl restart livekit || true
fi

# brain her deploy'da restart (kod değişmiş olabilir)
echo "→ brain restart"; systemctl restart brain

# Sağlık kontrolü
echo "→ health bekleniyor..."
for i in $(seq 1 30); do
  if curl -fsS http://localhost:8800/api/health >/dev/null 2>&1; then
    echo "✓ health OK"; curl -s http://localhost:8800/api/health; echo; exit 0
  fi
  sleep 2
done
echo "✗ health FAILED"; systemctl status brain --no-pager | tail -25; exit 1
