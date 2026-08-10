#!/bin/zsh
# Bygg Schous.app. Ingen Xcode nødvendig — swift build + manuell bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Schous.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Schous"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Schous"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ikonet bygges fra pikselrutenettet i icon.py, så .icns er et byggeartefakt
# og ikke en binærblob i git.
/usr/bin/python3 icon.py >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

# ponytail: ad-hoc signering. Notarisering når appen faktisk skal distribueres.
codesign --force --sign - "$APP"

# Spotlight finner apper på navn, og «Schous» sier ingenting om hva den gjør.
# Søkeord MÅ settes som utvidet attributt — kMDItemKeywords i Info.plist leses
# aldri for app-bundles (verifisert: mdls gir null).
KEYWORDS=$(/usr/bin/python3 -c "import plistlib,sys; sys.stdout.write(plistlib.dumps(
  ['transkribering','transkribere','transcribe','transcription',
   'diarization','diarisering','taler','speaker','undertekst','srt'],
  fmt=plistlib.FMT_BINARY).hex())")
xattr -wx com.apple.metadata:kMDItemKeywords "$KEYWORDS" "$APP"
mdimport "$APP" 2>/dev/null || true

echo "ok: $APP"
