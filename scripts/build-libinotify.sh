#!/bin/bash
# Baut libinotify-kqueue (inotify-API über kqueue, MIT-Lizenz) statisch für x86_64.
# Ohne sie hat der Wine-Server auf macOS keine Dateiänderungs-Benachrichtigungen:
# ReadDirectoryChangesW/FindFirstChangeNotification melden nie etwas (Launcher erkennen
# fertige Downloads nicht, Editoren keine geänderten Dateien). Wine nutzt sie über
# INOTIFY_CFLAGS/INOTIFY_LIBS, wie auf FreeBSD.
#
#   scripts/build-libinotify.sh   -> thirdparty/inotify/install/{include,lib}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/thirdparty/inotify"
LOCK="$ROOT/support/components.lock.json"
URL="$(sed -n '/"libinotify"/,/}/s/.*"url": *"\([^"]*\)".*/\1/p' "$LOCK")"
SHA="$(sed -n '/"libinotify"/,/}/s/.*"sha256": *"\([^"]*\)".*/\1/p' "$LOCK")"
PKG="$DIR/$(basename "$URL")"

[ -f "$DIR/install/lib/libinotify.a" ] && [ -f "$DIR/install/include/sys/inotify.h" ] && { echo "==> libinotify schon gebaut."; exit 0; }
mkdir -p "$DIR"
if [ ! -s "$PKG" ] || [ "$(shasum -a 256 "$PKG" | awk '{print $1}')" != "$SHA" ]; then
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$PKG.part"
    [ "$(shasum -a 256 "$PKG.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$PKG.part"; echo "libinotify-Prüfsumme stimmt nicht." >&2; exit 1; }
    mv "$PKG.part" "$PKG"
fi
rm -rf "$DIR/src"; mkdir -p "$DIR/src"
tar -xzf "$PKG" -C "$DIR/src" --strip-components=1
# Kein --host: configure soll seine x86_64-Testprogramme ausführen (läuft über Rosetta).
( cd "$DIR/src" && ./configure CC="clang -arch x86_64" --enable-static --disable-shared --prefix="$DIR/install" >/dev/null \
  && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null )
# Nur die statische Bibliothek, damit der Wine-Server sie fest einbaut.
rm -f "$DIR/install/lib/libinotify.la" "$DIR"/install/lib/libinotify*.dylib
echo "==> libinotify gebaut: $DIR/install"
