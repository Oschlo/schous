#!/bin/zsh
# ./release.sh 0.2.0 — tagg, bygg, og legg .app-en ut som en GitHub-release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "bruk: ./release.sh 0.2.0"; exit 1 }
[[ -z "$(git status --porcelain)" ]] || { echo "arbeidstreet er skittent — commit først"; exit 1 }

# Taggen MÅ settes før bundle.sh kjører: den stempler versjonen fra `git describe`,
# så en app bygget før taggen fikk den forrige versjonen inn i Info.plist og ville
# meldt om en oppdatering til seg selv i all evighet.
git tag "v$VERSION"
./bundle.sh

# Release-buildet må kjøres her, på maskinen med «Schous Dev»-identiteten. En
# GitHub Action ville signert ad-hoc, og da nullstilles mikrofon-, lydopptaks- og
# HF_TOKEN-tilgangen for hver eneste oppdatering. Se «Signering» i CLAUDE.md.
# -dvv, ikke -dv: Authority-linjen kommer først på nivå to. Med én v er utskriften
# tom for Authority uansett hvem som signerte, og sjekken ville stoppet hver release.
if ! codesign -dvv Schous.app 2>&1 | grep -q 'Authority=Schous Dev'; then
  echo "avbryter: Schous.app er ikke signert med «Schous Dev» — se CLAUDE.md."
  git tag -d "v$VERSION"
  exit 1
fi

# ditto, ikke zip: zip mister symlinker og utvidede attributter i bundlen, og da
# er signaturen ugyldig når mottakeren pakker ut.
rm -f Schous.zip
ditto -c -k --keepParent Schous.app Schous.zip

git push origin HEAD "v$VERSION"
gh release create "v$VERSION" Schous.zip --generate-notes --title "v$VERSION"
rm -f Schous.zip
echo "ok: v$VERSION lagt ut"
