#!/bin/bash
# Bündelt GStreamer (Medienwiedergabe für Media Foundation/DirectShow über winegstreamer)
# in eine Wine-Installation, damit Nutzer kein eigenes GStreamer installieren müssen.
#
#   scripts/bundle-gstreamer.sh <wine-installation> [GStreamer.framework]
#
# Kopiert die Kernbibliotheken, eine feste Plugin-Auswahl (Container, Decoder; ohne
# applemedia, das eine zweite MoltenVK-Kopie mitbrächte) und alle ihre Abhängigkeiten als x86_64 nach lib/gst; Plugins nach
# lib/gst/gstreamer-1.0. Eigener Ordner, damit nichts mit libintl/libffi/libz der Runtime
# kollidiert. winegstreamer.so bekommt einen Suchpfad dorthin. Die virtual*-Befehle
# setzen GST_PLUGIN_SYSTEM_PATH (scripts/write-runtime-wrappers.sh).
set -euo pipefail
WINE="${1:?Wine-Installation angeben, z. B. runtime/wine-build}"
FW="${2:-/Library/Frameworks/GStreamer.framework/Versions/Current}"
SRC="$FW/lib"
DEST="$WINE/lib/gst"

[ -f "$SRC/libgstreamer-1.0.0.dylib" ] || { echo "GStreamer.framework fehlt ($FW) – https://gstreamer.freedesktop.org/download/ (Runtime + Development)." >&2; exit 1; }
[ -f "$WINE/lib/wine/x86_64-unix/winegstreamer.so" ] || { echo "winegstreamer.so fehlt in $WINE – Wine mit --with-gstreamer bauen." >&2; exit 1; }

# Nur LGPL/BSD-lizenzierte Plugins (kein a52dec, x264, x265, lame: GPL); AC3 & Co.
# dekodiert gst-libav.
PLUGINS=(
    coreelements app playback typefindfunctions pbtypes autodetect
    audioconvert audioresample audiorate volume videoconvertscale videorate deinterlace videofilter
    isomp4 matroska avi asf flv ogg wavparse aiff mpegpsdemux mpegtsdemux
    id3demux icydemux apetag audioparsers videoparsersbad subparse
    libav dav1d vpx opus vorbis theora flac mpg123 speex
    alaw mulaw adpcmdec jpeg png
)

rm -rf "$DEST"
mkdir -p "$DEST/gstreamer-1.0"

copied=()
is_copied() { local x; for x in "${copied[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

# $1 Quelldatei, $2 Ziel; universelle Binärdateien auf x86_64 reduzieren
copy_thin() {
    if lipo -archs "$1" 2>/dev/null | grep -qw arm64; then
        lipo -thin x86_64 "$1" -output "$2"
    else
        cp "$1" "$2"
    fi
    chmod 755 "$2"
}

# kopiert eine Bibliothek aus $SRC samt aller @rpath-Abhängigkeiten
copy_lib() {
    local name="$1" dep
    is_copied "$name" && return 0
    [ -f "$SRC/$name" ] || { echo "    fehlt im Framework: $name" >&2; return 1; }
    copied+=("$name")
    copy_thin "$SRC/$name" "$DEST/$name"
    for dep in $(otool -L "$DEST/$name" | awk 'NR>1 && $1 ~ /^@rpath\// {sub("@rpath/","",$1); print $1}'); do
        [ "$dep" = "$name" ] || copy_lib "$dep"
    done
}

echo "==> GStreamer-Kern…"
for lib in libgstreamer-1.0.0.dylib libgstbase-1.0.0.dylib libgstaudio-1.0.0.dylib libgstvideo-1.0.0.dylib \
           libgsttag-1.0.0.dylib libgobject-2.0.0.dylib libglib-2.0.0.dylib libgmodule-2.0.0.dylib; do
    copy_lib "$lib"
done

echo "==> Plugins…"
for plugin in "${PLUGINS[@]}"; do
    file="$SRC/gstreamer-1.0/libgst$plugin.dylib"
    [ -f "$file" ] || { echo "    Plugin fehlt: $plugin"; continue; }
    copy_thin "$file" "$DEST/gstreamer-1.0/libgst$plugin.dylib"
    for dep in $(otool -L "$file" | awk 'NR>1 && $1 ~ /^@rpath\// {sub("@rpath/","",$1); print $1}'); do
        [ "$dep" = "libgst$plugin.dylib" ] || copy_lib "$dep"   # erste Zeile: eigener Name
    done
done

# winegstreamer.so findet die Bibliotheken über @rpath; lib/gst als Suchpfad ergänzen
GSO="$WINE/lib/wine/x86_64-unix/winegstreamer.so"
while IFS= read -r old; do
    [ -z "$old" ] || install_name_tool -delete_rpath "$old" "$GSO"
done < <(otool -l "$GSO" | awk '/LC_RPATH/ {found=1;next} found && /path / {if ($2 ~ /^\/Library\/Frameworks\/GStreamer/) print $2; found=0}')
otool -l "$GSO" | grep -q "@loader_path/../../gst" || install_name_tool -add_rpath @loader_path/../../gst "$GSO"

# veränderte bzw. reduzierte Dateien neu (ad hoc) signieren
codesign --force --sign - "$GSO" "$DEST"/*.dylib "$DEST"/gstreamer-1.0/*.dylib >/dev/null 2>&1 || true

echo "==> GStreamer gebündelt: $(du -sh "$DEST" | awk '{print $1}') in $DEST (${#copied[@]} Bibliotheken, ${#PLUGINS[@]} Plugins)"
