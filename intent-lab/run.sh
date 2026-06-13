#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$0")"

if [ ! -d ".venv" ]; then
  echo "[intent-lab] .venv oluşturuluyor..."
  python3 -m venv .venv
fi

source .venv/bin/activate

if ! python -c "import sentence_transformers" 2>/dev/null; then
  echo "[intent-lab] bağımlılıklar kuruluyor..."
  pip install --quiet --upgrade pip
  pip install --quiet -r requirements.txt
fi

# İlk argüman --flag ise eval'a yönlendir (örn. --errors, --persona kiz).
# Çıplak metin ise CLI'a yönlendir (örn. "salondaki ışığı aç").
# Argüman yoksa eval'ı varsayılan çalıştır.
if [ $# -eq 0 ]; then
  echo "[intent-lab] eval batch çalıştırılıyor..."
  exec python tests/eval.py
elif [ "${1#--}" != "$1" ]; then
  echo "[intent-lab] eval (flag'lar ile) çalıştırılıyor..."
  exec python tests/eval.py "$@"
else
  exec python cli.py "$@"
fi
