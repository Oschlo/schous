#!/bin/zsh
# ./release.sh 0.2.0 — tagg, bygg, og legg .app-en ut som en GitHub-release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
# «v0.2.0» er den naturlige skrivefeilen, og den er ikke uskyldig: taggen blir
# «vv0.2.0», som bundle.sh sitt `--match 'v[0-9]*'` ikke ser. Appen ville blitt
# stemplet med forrige versjon og masset om en oppdatering til seg selv for alltid.
VERSION="${VERSION#v}"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]] || { echo "bruk: ./release.sh 0.2.0"; exit 1 }
[[ -z "$(git status --porcelain)" ]] || { echo "arbeidstreet er skittent — commit først"; exit 1 }
[[ "$(git branch --show-current)" == main ]] || { echo "tagg bare fra main"; exit 1 }

PUSHED=0
abort() {
  echo "avbryter: $1"
  git tag -d "v$VERSION" >/dev/null 2>&1 || true
  # Etter push finnes taggen — og kanskje et halvferdig utkast — på GitHub. Uten at
  # begge ryddes bort, står en tagg som peker på en utgivelse som ikke finnes, og
  # neste `./release.sh` med samme versjon dør på at taggen er tatt.
  # `--cleanup-tag` tar taggen sammen med utkastet; finnes det ingen release ennå,
  # feiler kommandoen og fjernaggen slettes direkte i stedet.
  if (( PUSHED )); then
    gh release delete "v$VERSION" --yes --cleanup-tag >/dev/null 2>&1 \
      || git push --delete origin "v$VERSION" >/dev/null 2>&1 || true
    echo "ryddet bort taggen og eventuelt utkast på GitHub — commiten står igjen på main."
  fi
  exit 1
}

# Taggen MÅ settes før bundle.sh kjører: den stempler versjonen fra `git describe`,
# så en app bygget før taggen fikk den forrige versjonen inn i Info.plist og ville
# meldt om en oppdatering til seg selv i all evighet. Trap-en finnes fordi taggen
# da er satt før noe kan feile — uten den dør neste forsøk på «tag already exists».
git tag "v$VERSION"
trap 'abort "kommandoen over feilet"' ZERR
./bundle.sh

# At taggen ble satt er ikke det samme som at den ble stemplet: ligger det allerede
# en annen matchende tagg på samme commit, velger `git describe` sin egen. Dette er
# den ene sjekken som faktisk måler det appen kommer til å sammenligne med.
STAMPED=$(plutil -extract CFBundleShortVersionString raw Schous.app/Contents/Info.plist)
[[ "$STAMPED" == "$VERSION" ]] || abort "appen ble stemplet $STAMPED, ikke $VERSION"

# ditto, ikke zip: zip mister symlinker og utvidede attributter i bundlen, og da
# er signaturen ugyldig når mottakeren pakker ut.
ditto -c -k --keepParent Schous.app Schous.zip

# Vakten kjøres på det utpakkede arkivet, ikke på Schous.app: det er den kopien
# brukeren får, og den eneste måten å se at ditto ikke mistet noe på veien.
#
# `--verify --strict`, ikke `codesign -dvv | grep Authority`. `-d` viser bare hva
# signaturen *sier* om seg selv og validerer ingenting — målt: legg én byte til i
# Contents/Resources/MenuBarIcon.png, og `-dvv` skriver fortsatt «Authority=Schous
# Dev» mens `--verify --strict` sier «a sealed resource is missing or invalid».
# Grep-varianten ville altså lagt ut en bundle Gatekeeper avviser.
#
# Kravet er pinnet mot leaf-hashen, ikke mot CN-en: det er hashen TCC (mikrofon,
# lydopptak) og Keychain-ACL-en på HF_TOKEN er nøklet på, og et nytt selvsignert
# sertifikat med samme navn ville nullstilt alle tre hos hver bruker uten at noe
# her merket det. Se «Signering» i CLAUDE.md. Bytter du sertifikat, er det denne
# linja som skal oppdateres — og at den stopper deg er poenget.
rm -rf .release-verify
ditto -x -k Schous.zip .release-verify
codesign --verify --strict -R \
  '=identifier "co.oschlo.schous" and certificate leaf = H"b300de7a202552c6323463dc139682eee3f704cb"' \
  .release-verify/Schous.app \
  || abort "signaturen i arkivet holder ikke — se «Signering» i CLAUDE.md."
rm -rf .release-verify

git push origin HEAD "v$VERSION"
PUSHED=1

# Utkast først, publiser etterpå: `gh release create` er flere API-kall (opprett,
# last opp arkivet, publiser), og feiler opplastingen midtveis ville en publisert
# release ligget ute uten Schous.zip — README-en peker rett på den. Som utkast er
# den usynlig til arkivet er oppe, og trap-en rydder den bort med `--cleanup-tag`.
gh release create "v$VERSION" Schous.zip --generate-notes --draft
gh release edit "v$VERSION" --draft=false >/dev/null
rm -f Schous.zip
echo "ok: v$VERSION lagt ut"
