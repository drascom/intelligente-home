#!/bin/sh
# Dev STT service for the Mac: wyoming-faster-whisper on CPU, port 10300.
# Runtime mate-brain/'de (.venv + .whisper-data).
# (On the Linux server this runs as a GPU container — see deploy/.)
cd "$(dirname "$0")/mate-brain"
exec .venv/bin/python -m wyoming_faster_whisper \
  --model "${WHISPER_MODEL:-large-v3-turbo}" \
  --language "${WHISPER_LANGUAGE:-tr}" \
  --uri tcp://0.0.0.0:10300 \
  --data-dir .whisper-data
