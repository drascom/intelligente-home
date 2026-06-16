#!/usr/bin/env bash
# Test sunucusunda idempotent deploy. CI (self-hosted runner) push'ta sudo ile çağırır.
# git reset --hard ile origin/main'e hizalar, değişen bağımlılıkları kurar,
# systemd unit'leri günceller, brain'i (gerekirse vox/whisper) restart eder,
# /api/health ile doğrular (başarısızsa exit 1 → CI kırmızı yanar).
set -euo pipefail
REPO=/opt/intelligente-home
cd "$REPO"

BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
git fetch -q origin main
git reset --hard -q origin/main   # mate-brain/.env dev'e döner ama EnvironmentFile ezer; venv'ler gitignore'da
AFTER=$(git rev-parse HEAD)
echo "deploy: ${BEFORE:0:7} -> ${AFTER:0:7}"

changed() { [ "$BEFORE" = none ] || git diff --name-only "$BEFORE" "$AFTER" | grep -q "$1"; }

# Bağımlılık değişimi → ilgili venv'e kur
if changed 'mate-brain/brain/requirements.txt'; then
  echo "→ brain requirements değişti, kuruluyor"; mate-brain/.venv/bin/pip install -q -r mate-brain/brain/requirements.txt
fi
if changed 'vox/requirements.txt'; then
  echo "→ vox requirements değişti, kuruluyor"; vox/.venv/bin/pip install -q -r vox/requirements.txt
fi
if changed 'mate-brain/package.json'; then
  echo "→ pi/npm bağımlılıkları değişti, kuruluyor"; (cd mate-brain && npm install --no-audit --no-fund -s)
fi

# Dashboard (mate-dash) kaynağı değiştiyse derle + servis restart
if changed 'mate-dash/'; then
  echo "→ mate-dash değişti, derleniyor"
  (cd mate-dash && npm install --no-audit --no-fund -s && npm run build)
  systemctl restart mate-dash || true
fi

# systemd unit'leri değiştiyse senkronla
if changed 'deploy/systemd/'; then
  echo "→ systemd unit'leri güncelleniyor"; cp deploy/systemd/*.service /etc/systemd/system/; systemctl daemon-reload
fi

# Restart: brain her zaman; vox/whisper kodu değişince; vLLM yalnızca unit'i değişince
systemctl restart brain
changed 'vox/' && { echo "→ vox restart"; systemctl restart vox; } || true
changed 'deploy/systemd/whisper.service' && systemctl restart whisper || true
changed 'deploy/systemd/vllm.service' && { echo "→ vllm restart (model/arg değişti)"; systemctl restart vllm; } || true

# Sağlık kontrolü
echo "→ health bekleniyor..."
for i in $(seq 1 30); do
  if curl -fsS http://localhost:8800/api/health >/dev/null 2>&1; then
    echo "✓ health OK"; curl -s http://localhost:8800/api/health; echo; exit 0
  fi
  sleep 2
done
echo "✗ health FAILED"; systemctl status brain --no-pager | tail -25; exit 1
