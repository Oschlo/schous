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

# Versjonen stemples fra git, ikke vedlikeholdt for hånd i Info.plist — det er den
# samme strengen «Se etter oppdateringer» sammenligner med taggen på GitHub, så en
# glemt håndredigering ville fått appen til å melde om oppdatering til seg selv.
# Bare kopien i bundlen endres; Resources/Info.plist blir aldri skitten i git.
# Uten tagger feiler git describe («No names found», ingen --always her), VERSION blir
# tom, og 0.1.0 fra Info.plist står — sjekken sammenligner mot den til første
# `./release.sh`.
VERSION=$(git describe --tags --match 'v[0-9]*' --dirty 2>/dev/null | sed 's/^v//' || true)
if [[ -n "$VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

# Ikonet bygges fra pikselrutenettet i icon.py, så .icns er et byggeartefakt
# og ikke en binærblob i git.
/usr/bin/python3 icon.py >/dev/null
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

# Signering med den lokale «Schous Dev»-identiteten når den finnes, ellers ad-hoc.
#
# Dette er ikke pynt. Ad-hoc-signatur gir `designated => cdhash H"…"`, som endrer
# seg ved hver eneste build — og både TCC (mikrofon, lydopptak) og Keychain-ACL-en
# på HF_TOKEN er nøklet på nettopp den strengen. Ad-hoc betyr derfor at hver
# rebuild krever at du godkjenner alt på nytt for hånd, midt i en test. Med
# sertifikatet blir kravet `identifier "co.oschlo.schous" and certificate leaf =
# H"…"`, som står stille for alltid. Se «Signering» i CLAUDE.md for oppsettet.
#
# ponytail: fortsatt lokalt selvsignert. Notarisering når appen skal distribueres.
#
# `find-identity`, ikke `find-certificate`: codesign trenger privatnøkkelen også,
# og et sertifikat uten nøkkel ville passert sjekken, fått codesign til å feile og
# `set -e` til å stoppe buildet med en usignert app — altså aldri nådd ad-hoc-
# fallbacken under. Uten `-v`, som filtrerer bort alt som ikke er trust'et.
#
# `--options runtime` hører med til den stabile signaturen, ikke ved siden av den.
# Uten hardened runtime laster appen hva som helst via DYLD_INSERT_LIBRARIES, og
# når signaturen over gjør TCC-granten permanent, blir det en permanent vei inn til
# mikrofonen, systemlyden og HF_TOKEN. Hardened runtime stenger til gjengjeld
# mikrofonen uansett hva TCC har sagt ja til, så den må entitles eksplisitt — se
# Resources/Schous.entitlements. Library validation følger med på kjøpet, men alt
# binæren lenker mot ligger i /usr/lib og /System (`otool -L`), så det koster null.
SIGN=(--force --options runtime --entitlements Resources/Schous.entitlements)
if security find-identity -p codesigning | grep -q '"Schous Dev"'; then
  codesign "${SIGN[@]}" --sign "Schous Dev" "$APP"
else
  echo "advarsel: fant ikke «Schous Dev» — ad-hoc-signerer, og da må du godkjenne"
  echo "         mikrofon, lydopptak og Keychain på nytt etter hver build."
  codesign "${SIGN[@]}" --sign - "$APP"
fi

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
