#!/bin/bash
# Veröffentlicht eine neue Version auf GitHub – die Quelle für den Auto-Updater der App.
#
#   scripts/release.sh 0.3.0 ["Was ist neu"]
#
# Setzt VERSION, committet und taggt (v0.3.0), baut die App, packt sie als
# Virtual-0.3.0.zip und legt damit ein GitHub-Release an (gh CLI).
# Ohne Notizen erzeugt GitHub sie aus den Commits seit dem letzten Release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Aufruf: scripts/release.sh <version> [notizen]}"
NOTES="${2:-}"
cd "$ROOT"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version im Format 1.2.3 angeben."; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Nur von main veröffentlichen."; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Erst alle Änderungen committen."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION gibt es schon."; exit 1; fi
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI fehlt:  brew install gh"; exit 1; }

echo "==> Version $VERSION"
echo "$VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -q -m "Version $VERSION"
git tag -a "v$VERSION" -m "Virtual $VERSION"

WINMAC_BUNDLE_ENGINE=1 ./build-app.sh
ZIP="build/Virtual-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/Virtual.app" "$ZIP"

echo "==> Push und Release"
git push -q origin main "v$VERSION"
if [ -n "$NOTES" ]; then
    gh release create "v$VERSION" "$ZIP" --title "Virtual $VERSION" --notes "$NOTES"
else
    gh release create "v$VERSION" "$ZIP" --title "Virtual $VERSION" --generate-notes
fi
