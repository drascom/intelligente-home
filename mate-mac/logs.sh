#!/bin/bash
# mate-mac birleşik (os_log) loglarını okur. Log.swift subsystem'i: uk.drascom.mate
#
#   ./logs.sh                son 5 dk, tüm kategoriler (default+info+debug)
#   ./logs.sh -f             CANLI akış (Ctrl-C ile çık)
#   ./logs.sh -m 30m         son 30 dk (veya 2h, 90s ...)
#   ./logs.sh BargeIn        sadece BargeIn kategorisi (son 5 dk)
#   ./logs.sh -f BargeIn     canlı + sadece BargeIn
#   ./logs.sh -m 1h Bridge   son 1 saat, sadece Bridge
#
# Kategoriler (Log.swift, [Etiket]'ten türetilir):
#   BargeIn Flow VAD STT LiveSTT Wake Chime FollowUp Bridge Session Route
#   Pipeline Player Recorder Cue MacAudio App
set -e

SUB="uk.drascom.mate"
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
    | sed -E 's/^([0-9-]+ [0-9:.]+) [A-Za-z]+ Mate\[[0-9:a-z]+\] //'
fi
