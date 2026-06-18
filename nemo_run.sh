#!/bin/sh
# Dev STT yan-servisi (Nemotron 3.5 ASR Streaming), port 10301.
# Whisper'a (10300) dokunmaz; drop-in test için ayrı port.
# (Linux sunucusunda systemd ile /opt/nemo-venv'den çalışır — bkz. deploy/systemd/nemotron.service.)
cd "$(dirname "$0")"
exec "${NEMO_VENV:-/opt/nemo-venv}/bin/python" deploy/nemotron/server.py \
  --uri "tcp://0.0.0.0:${NEMOTRON_PORT:-10301}" \
  --device "${NEMOTRON_DEVICE:-cuda}" \
  --language "${NEMOTRON_LANGUAGE:-tr}"
