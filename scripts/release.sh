#!/bin/bash
# Veröffentlicht eine neue Version auf GitHub – die Quelle für den Auto-Updater der App.
#
#   scripts/release.sh 0.8.0 ["Was ist neu"]
#
# Setzt VERSION, committet und taggt (v0.8.0) und baut alles in build/release; die installierte
# build/Virtual.app bleibt unberührt. Das Release enthält:
#   Virtual-0.8.0.zip         die App ohne Engine (klein)
#   engine.json               Engine-Version, Download-Adresse, Größe und SHA-256
#   Virtual-Engine-<id>.zip   nur, wenn sich die Engine seit dem letzten Release geändert hat;
#                             sonst zeigt engine.json auf die Engine eines früheren Releases
# Geprüft wird das vollständige Bundle (App + Engine), so wie es nach dem Update beim Nutzer liegt.
# Der Updater lädt die Engine nur, wenn sie sich von der installierten unterscheidet.
# Ohne Notizen erzeugt GitHub sie aus den Commits seit dem letzten Release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Aufruf: scripts/release.sh <version> [notizen]}"
NOTES="${2:-}"
REPO=nyra-grz/Virtual
cd "$ROOT"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version im Format 1.2.3 angeben."; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Nur von main veröffentlichen."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Erst alle Änderungen committen."; exit 1; }
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then echo "Tag v$VERSION gibt es schon."; exit 1; fi
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI fehlt:  brew install gh"; exit 1; }
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || { echo "Release benötigt mingw-w64 für die Windows-Helfer."; exit 1; }

OUT="$ROOT/build/release"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Version $VERSION"
echo "$VERSION" > VERSION
git add VERSION
git diff --cached --quiet || git commit -q -m "Version $VERSION"

echo "==> App (ohne Engine)"
WINMAC_APP_BUNDLE="$OUT/Virtual.app" ./build-app.sh
[ -f "$OUT/Virtual.app/Contents/Resources/program-runner.exe" ] || { echo "Windows-Helfer fehlen im Bundle."; exit 1; }
ditto -c -k --keepParent "$OUT/Virtual.app" "$OUT/Virtual-$VERSION.zip"

echo "==> Engine"
scripts/package-engine.sh "$OUT/Engine"
ENGINE_ID="$(cat "$OUT/Engine/engine-version")"

echo "==> Prüfe das vollständige Bundle (App + Engine)"
mkdir -p "$OUT/full"
cp -cR "$OUT/Virtual.app" "$OUT/full/Virtual.app"
cp -cR "$OUT/Engine" "$OUT/full/Virtual.app/Contents/Resources/Engine"
codesign --force --deep --sign - "$OUT/full/Virtual.app" >/dev/null
python3 scripts/check-bundle.py "$OUT/full/Virtual.app" --receipt "$OUT/Virtual.verified.json"

ASSETS=("$OUT/Virtual-$VERSION.zip" "$OUT/engine.json" "$OUT/Virtual.verified.json" "$OUT/Virtual.verified.log")
# Hat das letzte Release dieselbe Engine, zeigt engine.json weiter auf deren Download.
mkdir -p "$OUT/previous"
gh release download -R "$REPO" --pattern engine.json --dir "$OUT/previous" >/dev/null 2>&1 || true
PREVIOUS_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$OUT/previous/engine.json" 2>/dev/null || true)"
if [ "$PREVIOUS_ID" = "$ENGINE_ID" ]; then
    echo "==> Engine unverändert – kein neuer Engine-Download"
    cp "$OUT/previous/engine.json" "$OUT/engine.json"
else
    ENGINE_ZIP="Virtual-Engine-${ENGINE_ID:0:12}.zip"
    echo "==> Packe $ENGINE_ZIP"
    ditto -c -k --keepParent "$OUT/Engine" "$OUT/$ENGINE_ZIP"
    python3 - "$ENGINE_ID" "https://github.com/$REPO/releases/download/v$VERSION/$ENGINE_ZIP" "$OUT/$ENGINE_ZIP" > "$OUT/engine.json" <<'PY'
import hashlib, json, os, sys
version, url, path = sys.argv[1:]
digest = hashlib.sha256()
with open(path, 'rb') as f:
    for block in iter(lambda: f.read(1 << 20), b''):
        digest.update(block)
print(json.dumps({"version": version, "url": url, "size": os.path.getsize(path), "sha256": digest.hexdigest()}, indent=2))
PY
    ASSETS+=("$OUT/$ENGINE_ZIP")
fi
git tag -a "v$VERSION" -m "Virtual $VERSION"

echo "==> Push und Release"
git push -q origin main "v$VERSION"
if [ -n "$NOTES" ]; then
    gh release create "v$VERSION" -R "$REPO" "${ASSETS[@]}" --title "Virtual $VERSION" --notes "$NOTES"
else
    gh release create "v$VERSION" -R "$REPO" "${ASSETS[@]}" --title "Virtual $VERSION" --generate-notes
fi
echo "==> Fertig: Virtual $VERSION (Engine ${ENGINE_ID:0:12})"
