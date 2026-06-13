#!/bin/sh
# macOS istemcisini derleyip başlatır.
# Kullanım: ./run.sh            → build + aç
#           ./run.sh --regen    → önce xcodegen (yeni dosya eklendiyse)
set -e
cd "$(dirname "$0")"

if [ "$1" = "--regen" ] || [ ! -d MateMac.xcodeproj ]; then
  xcodegen
fi

# Sabit derivedData → app yolu tahmin edilebilir olur.
xcodebuild -project MateMac.xcodeproj -scheme MateMac -configuration Debug \
  -derivedDataPath .build build | grep -E "error:|warning: Could|BUILD" || true

APP=".build/Build/Products/Debug/Mate.app"
if [ ! -d "$APP" ]; then
  echo "HATA: build çıktısı bulunamadı: $APP" >&2
  exit 1
fi

# Eski kopya açıksa kapat, yenisini başlat.
pkill -f "$PWD/$APP" 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Başlatıldı: $APP"
