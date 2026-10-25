#!/bin/bash
# Build-time tools, bundled so users do not need Homebrew or their own agent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${WINMAC_RUNTIME:-$ROOT/runtime}/tools"
CACHE="$ROOT/thirdparty/compatibility"
mkdir -p "$DEST/bin" "$CACHE"
SHA=672a1ff4442e8691a3ffc0e6860137e201a1d1227e9b3044245f1731e9e9837e
URL=https://raw.githubusercontent.com/Winetricks/winetricks/f3890f670867b5ffbc3938726db45c0f7d16c8ba/src/winetricks
if [ ! -f "$CACHE/winetricks" ] || [ "$(shasum -a 256 "$CACHE/winetricks" | awk '{print $1}')" != "$SHA" ]; then
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$CACHE/winetricks.part"
    [ "$(shasum -a 256 "$CACHE/winetricks.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$CACHE/winetricks.part"; exit 1; }
    mv "$CACHE/winetricks.part" "$CACHE/winetricks"
fi
CAB="$(command -v cabextract || true)"
[ -n "$CAB" ] || { echo "Build benötigt cabextract (brew install cabextract)." >&2; exit 1; }
# Homebrew's cabextract statically includes libmspack; reject unexpected private
# dependencies instead of shipping another pointer into the developer's machine.
if otool -L "$CAB" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/|$)' >/dev/null; then
    echo "cabextract hat nicht portable Bibliotheksabhängigkeiten." >&2; exit 1
fi
cp "$CACHE/winetricks" "$DEST/winetricks"
cp "$CAB" "$DEST/bin/cabextract"
chmod 755 "$DEST/winetricks" "$DEST/bin/cabextract"
echo "==> Winetricks und cabextract für automatische Komponenten vorbereitet."
