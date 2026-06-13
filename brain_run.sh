#!/bin/sh
# Dev brain service: FastAPI app (HA mirror + agent + voice bridge), port 8800.
# Runtime mate-brain/'de (paket + .venv + .env + db + node/pi). .env yüklenir.
cd "$(dirname "$0")/mate-brain"
set -a; [ -f .env ] && . ./.env; set +a
exec .venv/bin/python -m brain.main
