#!/bin/bash
# Baut die Windows-System-ICU so, wie Windows 10 sie seit 1903 mitbringt: eine icu.dll
# (nur C-API, unversionierte Namen, Daten eingebettet) plus icuuc.dll und icuin.dll als
# reine Weiterleitungen darauf. Qt 6 (KeePassXC, OBS …), Audacity und MSVC-Programme mit
# std::chrono-Zeitzonen laden diese Systembibliothek; Wine bringt sie nicht mit.
#
#   scripts/build-icu.sh             baut nach thirdparty/icu/out/{x86_64,i386}-windows/
#   scripts/build-icu.sh --install   kopiert danach nach runtime/wine-build/lib/icu/
#
# Braucht Homebrew-mingw-w64 (Cross-Compiler und libicu.a mit der Exportliste von
# Windows' icu.dll). Lizenz der ICU: Unicode-3.0 (support/THIRD_PARTY.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=78.3
URL="https://github.com/unicode-org/icu/releases/download/release-$VERSION/icu4c-$VERSION-sources.tgz"
SHA=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
WORK="$ROOT/thirdparty/icu"
OUT="$WORK/out"
JOBS="$(sysctl -n hw.ncpu)"
MINGW="$(brew --prefix mingw-w64 2>/dev/null)" || { echo "mingw-w64 fehlt: brew install mingw-w64"; exit 1; }

mkdir -p "$WORK"
PKG="$WORK/icu4c-$VERSION-sources.tgz"
if [ ! -f "$PKG" ] || [ "$(shasum -a 256 "$PKG" | awk '{print $1}')" != "$SHA" ]; then
    echo "==> Lade ICU $VERSION"
    curl -fL --retry 2 --connect-timeout 20 "$URL" -o "$PKG.part"
    [ "$(shasum -a 256 "$PKG.part" | awk '{print $1}')" = "$SHA" ] || { rm -f "$PKG.part"; echo "Prüfsumme falsch"; exit 1; }
    mv "$PKG.part" "$PKG"
fi
SRC="$WORK/icu-$VERSION"
if [ ! -f "$SRC/source/configure" ]; then
    rm -rf "$SRC.tmp" && mkdir -p "$SRC.tmp"
    tar -xzf "$PKG" -C "$SRC.tmp"
    mv "$SRC.tmp/icu" "$SRC" && rmdir "$SRC.tmp"
fi

# 1. Werkzeuge für den Mac (Pflicht für --with-cross-build: erzeugen die Daten)
HOST="$WORK/build-host"
if [ ! -x "$HOST/bin/icupkg" ]; then
    echo "==> ICU-Werkzeuge für den Mac"
    rm -rf "$HOST" && mkdir -p "$HOST"
    (cd "$HOST" && "$SRC/source/runConfigureICU" MacOSX --disable-tests --disable-samples --disable-extras >configure.log 2>&1 \
        && make -j"$JOBS" >make.log 2>&1) || { echo "Mac-Build gescheitert, siehe $HOST"; exit 1; }
fi

stub_c="$WORK/forward-stub.c"
printf '#include <windows.h>\nBOOL WINAPI DllMain(HINSTANCE h, DWORD r, LPVOID p) { return TRUE; }\n' > "$stub_c"

for arch in x86_64 i386; do
    case $arch in
        x86_64) T=x86_64-w64-mingw32; ENTRY=DllMain; UNDERSCORE="" ;;
        i386)   T=i686-w64-mingw32;   ENTRY=_DllMain@12; UNDERSCORE="_" ;;
    esac
    B="$WORK/build-$arch"
    # Die Datenbibliothek heißt je nach Ziel sicudt.a oder libsicudt.a.
    DT="$B/lib/sicudt.a"; [ -f "$DT" ] || DT="$B/lib/libsicudt.a"
    if [ ! -f "$B/lib/libsicuuc.a" ] || [ ! -f "$DT" ]; then
        echo "==> ICU für Windows $arch"
        rm -rf "$B" && mkdir -p "$B"
        (cd "$B" && CPPFLAGS="-DU_STATIC_IMPLEMENTATION" CFLAGS="-O2" CXXFLAGS="-O2 -std=c++17" \
            "$SRC/source/configure" --host="$T" --with-cross-build="$HOST" --disable-renaming \
            --enable-static --disable-shared --with-data-packaging=static \
            --disable-tests --disable-samples --disable-extras --disable-tools >configure.log 2>&1 \
            && make -j"$JOBS" SHELL=/bin/bash >make.log 2>&1) || { echo "Windows-Build ($arch) gescheitert, siehe $B"; exit 1; }
    fi

    D="$OUT/$arch-windows"
    rm -rf "$D" && mkdir -p "$D"
    # Exportliste genau wie Windows' icu.dll (aus mingw-w64s Importbibliothek); Namen,
    # die ICU $VERSION nicht mehr hat, fallen heraus und werden gemeldet.
    "$T-nm" "$MINGW/toolchain-${T%%-*}/$T/lib/libicu.a" 2>/dev/null \
        | awk -v u="__imp_$UNDERSCORE" '$2 == "I" && index($3, u) == 1 { print substr($3, length(u) + 1) }' | sort -u > "$D/windows.exports"
    "$T-nm" -g --defined-only "$B/lib/libsicuin.a" "$B/lib/libsicuuc.a" "$DT" 2>/dev/null \
        | awk -v u="$UNDERSCORE" '$2 ~ /^[TDRB]$/ { n = $3; if (u != "" && index(n, u) == 1) n = substr(n, 2); print n }' | sort -u > "$D/icu.defined"
    comm -12 "$D/windows.exports" "$D/icu.defined" > "$D/exports"
    comm -23 "$D/windows.exports" "$D/icu.defined" > "$D/missing.exports"
    { echo "LIBRARY icu.dll"; echo "EXPORTS"; cat "$D/exports"; } > "$D/icu.def"
    "$T-g++" -shared -static -s -o "$D/icu.dll" "$D/icu.def" -Wl,--whole-archive \
        "$B/lib/libsicuin.a" "$B/lib/libsicuuc.a" "$DT" -Wl,--no-whole-archive \
        -Wl,--no-insert-timestamp,--dynamicbase,--nxcompat
    # icuuc.dll/icuin.dll: volle Liste als Weiterleitung – welche Hälfte ein Programm
    # erwartet, ist egal, Windows leitet ebenfalls alles an icu.dll weiter.
    for lib in icuuc icuin; do
        { echo "LIBRARY $lib.dll"; echo "EXPORTS"; awk '{ print $1 " = icu." $1 }' "$D/exports"; } > "$D/$lib.def"
        "$T-gcc" -shared -s -nostdlib -o "$D/$lib.dll" "$D/$lib.def" "$stub_c" -Wl,-e,"$ENTRY"
    done
    rm -f "$D/icu.defined" "$D/windows.exports"

    # Darf nur Windows-Systembibliotheken brauchen (kein libstdc++/winpthread nachladen).
    imports="$("$T-objdump" -p "$D/icu.dll" | awk '/DLL Name:/ { print tolower($3) }' | sort -u | tr '\n' ' ')"
    for dll in $imports; do
        case $dll in kernel32.dll|advapi32.dll|msvcrt.dll|user32.dll|api-ms-win-crt-*) ;;
            *) echo "icu.dll ($arch) importiert unerwartet $dll"; exit 1 ;; esac
    done
    echo "    $arch: $(wc -l < "$D/exports" | tr -d ' ') Exporte, $(wc -l < "$D/missing.exports" | tr -d ' ') fehlen; Importe: $imports"
done

if [ "${1:-}" = "--install" ]; then
    if pgrep wineserver >/dev/null; then echo "Es laufen Windows-Programme – erst beenden, dann --install."; exit 1; fi
    DEST="$ROOT/runtime/wine-build/lib/icu"
    rm -rf "$DEST.new" && mkdir -p "$DEST.new"
    for arch in x86_64 i386; do
        mkdir -p "$DEST.new/$arch-windows"
        cp "$OUT/$arch-windows/"{icu,icuuc,icuin}.dll "$DEST.new/$arch-windows/"
    done
    cp "$SRC/LICENSE" "$DEST.new/LICENSE"
    rm -rf "$DEST" && mv "$DEST.new" "$DEST"
    echo "==> Installiert: $DEST"
fi
