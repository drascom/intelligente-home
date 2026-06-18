#!/bin/sh
# mate-livekit-mac (LiveKit "VoiceAgent") — derle + çalışan ESKİ kopyayı kapat + başlat.
#
# Xcode projesi repoda committed ve "synchronized folders" kullanır → VoiceAgent/
# altına eklenen yeni .swift dosyaları otomatik derlenir; xcodegen GEREKMEZ.
# Sunucu URL + token gitignore'lu VoiceAgent/Secrets.swift'ten gelir.
#
#   ./build.sh             Debug derle → çalışanı kapat → başlat
#   ./build.sh --release   Release derle (+ başlat)
#   ./build.sh --build     sadece derle, başlatma
#   ./build.sh --clean     clean build (önce derived data temizliği)
#   ./build.sh --open      yeniden derlemeden sadece mevcut .app'i başlat
# Bayraklar birlikte verilebilir, ör: ./build.sh --clean --release
#
# NOT: `open` çalışan bir kopya varsa onu yalnızca ÖNE getirir, yeni binary'yi
# yüklemez. Bu script bu yüzden başlatmadan önce eski süreci mutlaka kapatır.
set -e
cd "$(dirname "$0")"

CONFIG="Debug"; RUN=1; CLEAN=""; ONLY_OPEN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="Release" ;;
    --build)   RUN=0 ;;
    --clean)   CLEAN="clean" ;;
    --open)    ONLY_OPEN=1 ;;
    *) echo "Bilinmeyen argüman: $arg" >&2; exit 2 ;;
  esac
done

DD=".build/dd"
APP="$DD/Build/Products/$CONFIG/VoiceAgent.app"

if [ "$ONLY_OPEN" -eq 0 ]; then
  echo "→ $CONFIG derleniyor (macOS)..."
  # shellcheck disable=SC2086
  xcodebuild -project VoiceAgent.xcodeproj -scheme VoiceAgent -configuration "$CONFIG" \
    -destination 'platform=macOS' -derivedDataPath "$DD" $CLEAN build \
    | grep -E "error:|warning: Could|BUILD SUCCEEDED|BUILD FAILED" || true
fi

if [ ! -d "$APP" ]; then
  echo "HATA: build çıktısı bulunamadı: $APP" >&2
  exit 1
fi
echo "✓ Hazır: $PWD/$APP"

if [ "$RUN" -eq 1 ]; then
  # Bellekteki ESKİ kopyayı kapat — yoksa `open` taze binary yerine eskiyi öne getirir.
  pkill -9 -f "VoiceAgent.app/Contents/MacOS/VoiceAgent" 2>/dev/null || true
  sleep 1
  open -n "$APP"
  echo "✓ Başlatıldı (taze süreç): $APP"
fi
