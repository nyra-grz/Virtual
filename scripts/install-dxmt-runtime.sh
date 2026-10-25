#!/bin/bash
# Legt DXMTs Metal-Brücke (winemetal) in eine Wine-Installation, damit Räume
# DirectX 10/11 über DXMT -> Metal nutzen können (setup-graphics.sh, Standard).
#
#   scripts/install-dxmt-runtime.sh <wine-installation>   z. B. runtime/wine-build
#
# Paket und Prüfsumme aus support/components.lock.json; geladen wird nur, wenn
# thirdparty/graphics/dxmt.tar.gz fehlt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINE="${1:?Wine-Installation angeben, z. B. runtime/wine-build}"
PKG="$ROOT/thirdparty/graphics/dxmt.tar.gz"
URL="$(sed -n '/"dxmt"/,/}/s/.*"url": *"\([^"]*\)".*/\1/p' "$ROOT/support/components.lock.json")"
SHA="$(sed -n '/"dxmt"/,/}/s/.*"sha256": *"\([^"]*\)".*/\1/p' "$ROOT/support/components.lock.json")"

[ -d "$WINE/lib/wine/x86_64-unix" ] || { echo "Keine Wine-Installation unter $WINE" >&2; exit 1; }
mkdir -p "$(dirname "$PKG")"
if [ ! -s "$PKG" ] || [ "$(shasum -a 256 "$PKG" | awk '{print $1}')" != "$SHA" ]; then
    echo "==> Lade DXMT…"
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$PKG.part"
    [ "$(shasum -a 256 "$PKG.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$PKG.part"; echo "DXMT-Prüfsumme stimmt nicht." >&2; exit 1; }
    mv "$PKG.part" "$PKG"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$PKG" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 2 -type d -name x86_64-unix | head -1)"
SRC="$(dirname "$SRC")"
cp "$SRC/x86_64-unix/winemetal.so" "$WINE/lib/wine/x86_64-unix/"
cp "$SRC/x86_64-windows/winemetal.dll" "$WINE/lib/wine/x86_64-windows/"
cp "$SRC/i386-windows/winemetal.dll" "$WINE/lib/wine/i386-windows/"
echo "==> DXMT-Brücke (winemetal) in $WINE eingerichtet."
