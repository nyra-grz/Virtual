#!/bin/bash
# Reproduce the tested CrossOver FOSS base plus Virtual's patch series
# (patches/crossover/series, applied in order; a patch that does not apply stops
# the build and is named). Only LGPL Wine sources are used; no proprietary
# CrossOver app or license key.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION=26.1.0
SHA=e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa
URL="https://media.codeweavers.com/pub/crossover/source/crossover-sources-$VERSION.tar.gz"
CACHE="$ROOT/thirdparty/crossover"
PKG="$CACHE/crossover-sources-$VERSION.tar.gz"
PATCHES="$ROOT/patches/crossover"
SERIES=()
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    SERIES+=("$line")
done < "$PATCHES/series"
PATCH_ID="$( (cd "$PATCHES" && cat series "${SERIES[@]}") | shasum -a 256 | awk '{print substr($1,1,12)}')"
SRC="$CACHE/wine-$VERSION-$PATCH_ID"
mkdir -p "$CACHE"
if [ ! -f "$PKG" ] || [ "$(shasum -a 256 "$PKG" | awk '{print $1}')" != "$SHA" ]; then
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$PKG.part"
    [ "$(shasum -a 256 "$PKG.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$PKG.part"; exit 1; }
    mv "$PKG.part" "$PKG"
fi
if [ ! -f "$SRC/.virtual-source-ready" ]; then
    TMP="$(mktemp -d "$CACHE/.source.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT
    tar -xzf "$PKG" -C "$TMP" sources/wine
    git init -q "$TMP/sources/wine"
    for patch in "${SERIES[@]}"; do
        git -C "$TMP/sources/wine" apply --check "$PATCHES/$patch" || { echo "Patch passt nicht: $patch" >&2; exit 1; }
        git -C "$TMP/sources/wine" apply "$PATCHES/$patch"
    done
    printf '%s\n' "$VERSION $SHA $PATCH_ID" > "$TMP/sources/wine/.virtual-source-ready"
    mv "$TMP/sources/wine" "$SRC"
fi
export WINMAC_SOURCE_PREPARED=1 WINMAC_WINE_SOURCE="$SRC"
export WINMAC_WINE_BUILD="${WINMAC_WINE_BUILD:-$CACHE/build-$VERSION-$PATCH_ID}"
export WINMAC_RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
if [ "${WINMAC_PREPARE_ONLY:-0}" = 1 ]; then printf '%s\n' "$SRC"; exit 0; fi
exec /bin/bash "$ROOT/build-wine.sh"
