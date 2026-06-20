#!/bin/bash
# mate-livekit-mac birleşik (os_log) loglarını okur. Log.swift subsystem'i: candan.livekit
#
#   ./logs.sh             son 5 dk, tüm kategoriler (default+info+debug)
#   ./logs.sh -f          CANLI akış (Ctrl-C ile çık)
#   ./logs.sh -m 30m      son 30 dk (veya 2h, 90s ...)
#   ./logs.sh Wake        sadece Wake kategorisi (son 5 dk)
#   ./logs.sh -f Wake     canlı + sadece Wake
#
# Kategoriler ([Etiket]'ten türetilir): Wake Mic Coord Cue App
set -e

SUB="candan.livekit"
LIVE=0
SINCE="5m"
CAT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) LIVE=1; shift ;;
    -m|--since)  SINCE="$2"; shift 2 ;;
    -*) echo "Bilinmeyen bayrak: $1" >&2; exit 2 ;;
    *)  CAT="$1"; shift ;;
  esac
done

PRED="subsystem == \"$SUB\""
[ -n "$CAT" ] && PRED="$PRED AND category == \"$CAT\""

if [ "$LIVE" -eq 1 ]; then
  echo "→ canlı akış: $PRED  (Ctrl-C ile çık)"
  exec log stream --predicate "$PRED" --level debug --style compact
else
  echo "→ son $SINCE: $PRED"
  log show --predicate "$PRED" --last "$SINCE" --info --debug --style compact \
    | sed -E 's/^([0-9-]+ [0-9:.]+) [A-Za-z]+ VoiceAgent\[[0-9:a-z]+\] //'
fi
