#!/bin/sh
# mate-livekit-mac (LiveKit "VoiceAgent") — derle + çalışan ESKİ kopyayı kapat + başlat.
#
# Xcode projesi repoda committed ve "synchronized folders" kullanır → VoiceAgent/
# altına eklenen yeni .swift dosyaları otomatik derlenir; xcodegen GEREKMEZ.
# Sunucu URL + token gitignore'lu VoiceAgent/Secrets.swift'ten gelir.
#
#   ./build.sh                  Debug derle → çalışanı kapat → başlat
#   ./build.sh --regen --open   taze: app ürününü silip yeniden derle + başlat
#                               (eski versiyon gelmesin diye; SDK cache'i korunur)
#   ./build.sh --release        Release derle (+ başlat)
#   ./build.sh --clean          tam clean build (SDK dahil; yavaş)
#   ./build.sh --build          sadece derle, başlatma
# Bayraklar birlikte verilebilir, ör: ./build.sh --regen --release
#
# NOT: `open` çalışan bir kopya varsa onu yalnızca ÖNE getirir, yeni binary'yi
# yüklemez. Bu script bu yüzden başlatmadan önce eski süreci mutlaka kapatır.
# --regen ayrıca .app ürününü silerek başlatılan binary'nin kesin yeni olmasını
# garanti eder (xcodegen YOK; committed xcodeproj için "regen" = taze app ürünü).
set -e
cd "$(dirname "$0")"

CONFIG="Debug"; RUN=1; CLEAN=""; REGEN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="Release" ;;
    --build)   RUN=0 ;;
    --clean)   CLEAN="clean" ;;
    --regen)   REGEN=1 ;;
    --open)    RUN=1 ;;   # mate-mac uyumu: "derleyip aç" (zaten varsayılan)
    *) echo "Bilinmeyen argüman: $arg" >&2; exit 2 ;;
  esac
done

DD=".build/dd"
APP="$DD/Build/Products/$CONFIG/VoiceAgent.app"

# --regen: eski .app ürününü sil → başlatılan binary kesinlikle yeni olur
# (tam clean'in aksine SDK paket cache'ini korur, hızlı kalır).
if [ "$REGEN" -eq 1 ]; then
  echo "→ regen: eski app ürünü siliniyor"
  rm -rf "$APP"
fi

echo "→ $CONFIG derleniyor (macOS)..."
# shellcheck disable=SC2086
xcodebuild -project VoiceAgent.xcodeproj -scheme VoiceAgent -configuration "$CONFIG" \
  -destination 'platform=macOS' -derivedDataPath "$DD" $CLEAN build \
  | grep -E "error:|warning: Could|BUILD SUCCEEDED|BUILD FAILED" || true

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
