#!/bin/sh
# Brain'i ve sesli yol bağımlılıklarını (STT + TTS) tek komutla kaldırır.
# Servis scriptleri root'ta: whisper_run.sh, vox_run.sh, brain_run.sh.
#
#   ./start.sh          Ayakta olan brain/STT/TTS'i KAPATIR, sonra üçünü
#                       taze başlatır: STT + vox arka planda, brain ön planda
#                       (Ctrl-C durdurur).
#   ./start.sh --stop   Brain dahil tüm servisleri durdur (port bazlı).
#   ./start.sh --status Tüm halkaların durumunu yaz, hiçbir şey başlatma.
#
# Her çalıştırmada temiz restart: önce portları boşaltır, sonra başlatır.
# Arka plan logları .logs/. Brain ön planda kalır ki logları görüp Ctrl-C ile
# temiz kapatabilesin.
set -e
cd "$(dirname "$0")"

LOGS=".logs"
mkdir -p "$LOGS"

# .env yükle (BRAIN_PORT, portlar vb. için) — runtime mate-brain/'de
set -a; [ -f mate-brain/.env ] && . ./mate-brain/.env; set +a
BRAIN_PORT="${BRAIN_PORT:-8800}"
STT_PORT="${STT_PORT:-10300}"
VOX_PORT="${VOX_PORT:-8808}"

# --- yardımcılar ---------------------------------------------------------

# port_up <port> → 0 (açık) / 1 (kapalı). Darwin nc, 1 sn timeout.
port_up() { nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1; }

# kill_port <ad> <port> → portu dinleyen her süreci sonlandır (kim başlatmış olursa olsun)
kill_port() {
  name="$1"; port="$2"
  pids=$(lsof -ti "tcp:$port" 2>/dev/null || true)
  [ -z "$pids" ] && return 0
  echo "→ $name kapatılıyor (:$port, pid: $(echo "$pids" | tr '\n' ' '))"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  # 5 sn nazik bekle, hâlâ duruyorsa zorla
  i=0
  while [ "$i" -lt 5 ] && port_up "$port"; do sleep 1; i=$((i + 1)); done
  if port_up "$port"; then
    pids=$(lsof -ti "tcp:$port" 2>/dev/null || true)
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    sleep 1
  fi
}

# yeşil/kırmızı işaretle durum yaz
mark() { if port_up "$2"; then printf "  \033[32m●\033[0m %-12s :%s\n" "$1" "$2"; else printf "  \033[31m○\033[0m %-12s :%s (kapalı)\n" "$1" "$2"; fi; }

status() {
  echo "Servis durumu:"
  mark "brain"   "$BRAIN_PORT"
  mark "whisper" "$STT_PORT"
  mark "vox TTS" "$VOX_PORT"
  # Brain ayaktaysa HA/MQTT bağlantısını da göster
  if port_up "$BRAIN_PORT"; then
    health=$(curl -s -m 3 "http://127.0.0.1:$BRAIN_PORT/api/health" 2>/dev/null || true)
    [ -n "$health" ] && echo "  health: $health"
  fi
}

# bir bağımlılığı taze başlat (varsa önce kapat)
start_dep() { # <ad> <port> <başlatma scripti> <logdosyası>
  name="$1"; port="$2"; cmd="$3"; logf="$4"
  kill_port "$name" "$port"
  echo "→ $name başlatılıyor (:$port), log: $logf"
  # shellcheck disable=SC2086
  ( exec $cmd ) >"$logf" 2>&1 &
  echo "$!" > "$LOGS/$name.pid"
  # 30 sn boyunca portun açılmasını bekle (model yüklemesi yavaş olabilir)
  i=0
  while [ "$i" -lt 30 ]; do
    if port_up "$port"; then echo "✓ $name hazır"; return 0; fi
    sleep 1; i=$((i + 1))
  done
  echo "⚠ $name 30 sn'de açılmadı — log: $logf (yine de devam)" >&2
}

stop_all() {
  kill_port brain   "$BRAIN_PORT"
  kill_port whisper "$STT_PORT"
  kill_port vox     "$VOX_PORT"
  rm -f "$LOGS/whisper.pid" "$LOGS/vox.pid"
  echo "✓ tüm servisler durduruldu"
}

# --- komut işleme --------------------------------------------------------

case "$1" in
  --status) status; exit 0 ;;
  --stop)   stop_all; exit 0 ;;
esac

# Önkoşullar (runtime mate-brain/'de)
[ -d mate-brain/.venv ] || { echo "HATA: mate-brain/.venv yok — önce sanal ortamı kur." >&2; exit 1; }
[ -f mate-brain/.env ]  || { echo "HATA: mate-brain/.env yok." >&2; exit 1; }

echo "=== Bağımlılıklar (taze başlatılıyor) ==="
start_dep whisper "$STT_PORT" "./whisper_run.sh" "$LOGS/whisper.log"
start_dep vox     "$VOX_PORT" "./vox_run.sh"     "$LOGS/vox.log"

echo
echo "=== Brain (ön planda — Ctrl-C ile durdur) ==="
kill_port brain "$BRAIN_PORT"
echo "Not: STT/TTS arka planda kalır; hepsini durdurmak için ./start.sh --stop"
echo
exec ./brain_run.sh
