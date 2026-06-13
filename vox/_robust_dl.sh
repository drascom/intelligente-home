#!/bin/bash
# Robustly download VoxCPM2: retry on stall/failure, resume from .incomplete each time.
source /Users/drascom/work/voxcpm2/.venv/bin/activate
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=0
export HF_HUB_DOWNLOAD_TIMEOUT=30   # fail fast on stalled sockets so we can retry

for i in $(seq 1 100); do
  echo "[attempt $i] $(date '+%H:%M:%S') starting hf download..."
  hf download openbmb/VoxCPM2 && { echo "DOWNLOAD COMPLETE"; exit 0; }
  echo "[attempt $i] interrupted/stalled, resuming in 3s..."
  sleep 3
done
echo "GAVE UP after 100 attempts"
exit 1
