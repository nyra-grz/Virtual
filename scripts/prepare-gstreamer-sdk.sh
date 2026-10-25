#!/bin/bash
# Extract headers from the official SDK package; never install anything system-wide.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/thirdparty/gstreamer-sdk"
URL=https://gstreamer.freedesktop.org/data/pkg/osx/1.26.7/gstreamer-1.0-devel-1.26.7-universal.pkg
SHA=acdfede97877e8ece42eac40897a6975c199389d9474528f27d1cfcc95864a8a
[ ! -f "$DIR/merged/include/gstreamer-1.0/gst/gst.h" ] || exit 0
mkdir -p "$DIR"
PKG="$DIR/development.pkg"
if [ ! -f "$PKG" ] || [ "$(shasum -a 256 "$PKG" | awk '{print $1}')" != "$SHA" ]; then
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$PKG.part"
    [ "$(shasum -a 256 "$PKG.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$PKG.part"; exit 1; }
    mv "$PKG.part" "$PKG"
fi
TMP="$(mktemp -d "$DIR/.sdk.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pkgutil --expand-full "$PKG" "$TMP/expanded"
mkdir -p "$TMP/merged"
for payload in "$TMP/expanded"/*.pkg/Payload; do
    [ ! -d "$payload/include" ] || ditto "$payload/include" "$TMP/merged/include"
    [ ! -d "$payload/lib/glib-2.0/include" ] || ditto "$payload/lib/glib-2.0/include" "$TMP/merged/lib/glib-2.0/include"
done
[ -f "$TMP/merged/include/gstreamer-1.0/gst/gst.h" ] || { echo "GStreamer SDK ist unvollständig." >&2; exit 1; }
mv "$TMP/merged" "$DIR/merged"
