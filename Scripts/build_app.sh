#!/bin/bash
# Baut „Display Manager.app“ (Universal: Apple Silicon + Intel) und ein ZIP für Releases.
#   ./Scripts/build_app.sh [VERSION] [BUILDNUMMER]
# Optional: SIGN_IDENTITY=<SHA-1 oder Name des Zertifikats> für eine feste Signatur.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0}"
BUILD="${2:-1}"
APP_NAME="Display Manager"
OUT="build"
APP="$OUT/$APP_NAME.app"

echo "▶︎ Kompiliere Version $VERSION ($BUILD) …"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "▶︎ Erzeuge App-Paket …"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DisplayManager" "$APP/Contents/MacOS/DisplayManager"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▶︎ Signiere …"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  # Ohne Zertifikat: Ad-hoc-Signatur, aber mit fester Signatur-Anforderung (nur Bundle-ID).
  # Normalerweise wäre sie an den Prüfwert (cdhash) gebunden, der sich mit jedem Build ändert –
  # dann verliert macOS nach jedem Update die Bedienungshilfen-Freigabe.
  echo "  (kein Zertifikat – Ad-hoc-Signatur mit fester Anforderung)"
  codesign --force --sign - \
    --requirements '=designated => identifier "io.github.ziege1988.displaymanager"' "$APP"
fi
codesign --verify --verbose=2 "$APP"
codesign -dr - "$APP" 2>&1 | tail -n 1

echo "▶︎ Packe ZIP …"
(cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "Display-Manager.zip")
(cd "$OUT" && shasum -a 256 "Display-Manager.zip" > "Display-Manager.zip.sha256")
cat "$OUT/Display-Manager.zip.sha256"
echo "✔︎ Fertig: $APP"
