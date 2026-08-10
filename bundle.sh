#!/bin/zsh
# Bygg MacTranscribe.app. Ingen Xcode nødvendig — swift build + manuell bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="MacTranscribe.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MacTranscribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacTranscribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# ponytail: ad-hoc signering. Notarisering når appen faktisk skal distribueres.
codesign --force --sign - "$APP"
echo "ok: $APP"
