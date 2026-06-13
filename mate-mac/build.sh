#!/bin/sh
# mate-mac'i RELEASE olarak derleyip kullanıma hazır bir .app üretir.
# Çıktı sabit bir konuma kopyalanır (dist/Mate.app) — Xcode DerivedData'ya
# bağlı kalmadan çift tıklayıp çalıştırabilirsin.
#
#   ./build.sh                Release derle → dist/Mate.app
#   ./build.sh --regen        önce xcodegen (yeni kaynak dosyası eklendiyse)
#   ./build.sh --install      ayrıca /Applications'a kopyala
#   ./build.sh --open         derleme sonrası app'i aç
#   ./build.sh --adhoc        team sertifikası olmadan ad-hoc imzala
# Bayraklar birlikte verilebilir, ör: ./build.sh --regen --install --open
set -e
cd "$(dirname "$0")"

REGEN=0; INSTALL=0; OPEN=0; ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --regen)   REGEN=1 ;;
    --install) INSTALL=1 ;;
    --open)    OPEN=1 ;;
    --adhoc)   ADHOC=1 ;;
    *) echo "Bilinmeyen argüman: $arg" >&2; exit 2 ;;
  esac
done

DIST="dist"
APP_NAME="Mate.app"
PRODUCT=".build/Build/Products/Release/$APP_NAME"

# Yeni dosya eklendiyse projeyi yeniden üret
if [ "$REGEN" -eq 1 ] || [ ! -d MateMac.xcodeproj ]; then
  echo "→ xcodegen ile proje üretiliyor"
  xcodegen
fi

# İmzalama seçenekleri: varsayılan proje ayarları (Automatic + team),
# --adhoc ise sertifikasız ad-hoc imza.
SIGN_ARGS=""
if [ "$ADHOC" -eq 1 ]; then
  echo "→ ad-hoc imzalama modu (team sertifikası kullanılmıyor)"
  SIGN_ARGS="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES"
fi

echo "→ Release derleniyor..."
# shellcheck disable=SC2086
xcodebuild -project MateMac.xcodeproj -scheme MateMac -configuration Release \
  -derivedDataPath .build $SIGN_ARGS clean build \
  | grep -E "error:|warning: Could|BUILD" || true

if [ ! -d "$PRODUCT" ]; then
  echo "HATA: build çıktısı bulunamadı: $PRODUCT" >&2
  exit 1
fi

# Ad-hoc seçildiyse, kopyalamadan önce .app'i kesin olarak yeniden imzala
if [ "$ADHOC" -eq 1 ]; then
  echo "→ .app ad-hoc yeniden imzalanıyor"
  codesign --force --deep -s - "$PRODUCT"
fi

# Sabit dist konumuna kopyala (eskiyi temizle)
mkdir -p "$DIST"
rm -rf "$DIST/$APP_NAME"
cp -R "$PRODUCT" "$DIST/$APP_NAME"
SIZE=$(du -sh "$DIST/$APP_NAME" | cut -f1)
echo "✓ Hazır: $PWD/$DIST/$APP_NAME ($SIZE)"

# İsteğe bağlı: /Applications'a kur
if [ "$INSTALL" -eq 1 ]; then
  echo "→ /Applications'a kuruluyor"
  # Çalışan kopya varsa kapat
  pkill -f "/Applications/$APP_NAME/Contents/MacOS/Mate" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME"
  cp -R "$DIST/$APP_NAME" "/Applications/$APP_NAME"
  echo "✓ Kuruldu: /Applications/$APP_NAME"
fi

# İsteğe bağlı: aç
if [ "$OPEN" -eq 1 ]; then
  TARGET="$DIST/$APP_NAME"
  [ "$INSTALL" -eq 1 ] && TARGET="/Applications/$APP_NAME"
  pkill -f "$PWD/$TARGET/Contents/MacOS/Mate" 2>/dev/null || true
  sleep 0.5
  open "$TARGET"
  echo "✓ Açıldı: $TARGET"
fi
