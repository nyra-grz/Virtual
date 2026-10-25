#!/bin/bash
# Install the Wine Mono version expected by our wine-11.0 source build.
# Only generated files inside this project's runtime are written; no prefix is opened.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
VERSION=10.4.1
SHA256=a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb
NAME="wine-mono-$VERSION"
DEST="$RUNTIME/wine-build/share/wine/mono"
CACHE="$ROOT/thirdparty/managed"
ARCHIVE="$CACHE/$NAME-x86.tar.xz"
URL="https://github.com/wine-mono/wine-mono/releases/download/$NAME/$NAME-x86.tar.xz"

[ -x "$RUNTIME/wine-build/bin/wine" ] || { echo "Eigener Wine-Build fehlt unter runtime/wine-build."; exit 1; }
if [ -f "$DEST/$NAME/support/winemono-support.msi" ]; then
    echo "==> Wine Mono $VERSION ist vorhanden."
    exit 0
fi
mkdir -p "$CACHE" "$DEST"
verify() {
    [ -f "$ARCHIVE" ] && [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$SHA256" ]
}
if ! verify; then
    echo "==> Lade Wine Mono $VERSION von wine-mono/wine-mono…"
    curl --fail --location --retry 2 "$URL" -o "$ARCHIVE.part"
    [ "$(shasum -a 256 "$ARCHIVE.part" | awk '{print $1}')" = "$SHA256" ] || {
        rm -f "$ARCHIVE.part"
        echo "Wine-Mono-Prüfsumme stimmt nicht."
        exit 1
    }
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
STAGING="$(mktemp -d "$DEST/.mono.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
tar -xJf "$ARCHIVE" -C "$STAGING"
[ -f "$STAGING/$NAME/support/winemono-support.msi" ] || { echo "Wine-Mono-Paket ist unvollständig."; exit 1; }
mv "$STAGING/$NAME" "$DEST/$NAME"
echo "==> Wine Mono $VERSION installiert (nur in Virtuals eigener Runtime)."
