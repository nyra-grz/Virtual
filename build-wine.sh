#!/bin/bash
# build-wine.sh — reproduzierbarer Quell-Build des Wine-Forks "Virtual".
#
# Klont Wine, wendet unsere patches/ an, baut es für x86_64 und installiert nach
# ~/WinMac_Virtual/runtime/wine-build. Danach wird der umbenannte "virtual*"-
# Befehlssatz unter runtime/bin erzeugt (die alte Fassung bleibt in runtime/bin.vorher).
#
# Warum x86_64: Spiele sind x86-Programme. Wie die funktionierende Wine Staging.app
# läuft dieses Wine auf Apple Silicon unter Rosetta 2. 32-Bit-Programme laufen über
# WoW64 (--enable-archs=i386,x86_64); die Windows-Teile baut mingw-w64 aus Homebrew.
#
# Bibliotheken: Homebrew ist hier nur arm64. FreeType, GnuTLS, SDL2 und MoltenVK
# kommen deshalb als x86_64 samt Abhängigkeiten aus Wine Staging.app (WINMAC_X86_LIBS)
# und werden nach runtime/wine-build/lib kopiert; die Header kommen aus Homebrew.
# Vulkan läuft direkt über MoltenVK (ohne Vulkan-Loader, der bräuchte ICD-Dateien).
# GStreamer gibt es dort nicht als x86_64, also ohne GStreamer.
#
# EHRLICHER HINWEIS: Der Build dauert 30–90 Minuten. Wer sofort loslegen will,
# nutzt stattdessen  scripts/make-runtime-from-brew.sh  (kapselt ein fertiges Wine).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/thirdparty/wine"
BUILD="$ROOT/thirdparty/wine-build-tree"
RUNTIME="$ROOT/runtime"
PREFIX_INSTALL="$RUNTIME/wine-build"
WINE_GIT="https://gitlab.winehq.org/wine/wine.git"
WINE_TAG="${WINE_TAG:-wine-11.0}"   # aktuelles Stable; per Umgebungsvariable überschreibbar
X86_LIBS="${WINMAC_X86_LIBS:-$HOME/Downloads/Wine Staging.app/Contents/Resources/wine/lib}"
# Startpunkte; Symlinks und @loader_path-Abhängigkeiten werden mitkopiert.
X86_LIB_NAMES=(libfreetype.dylib libgnutls.dylib libSDL2.dylib libMoltenVK.dylib)

echo "============================================================"
echo " Virtual – Wine-Quell-Build"
echo " Tag: $WINE_TAG   Ziel: $PREFIX_INSTALL   Architektur: x86_64 (Rosetta)"
echo "============================================================"

# --- 1. Voraussetzungen ------------------------------------------------------
[ "$(uname -s)" = Darwin ] || { echo "Nur für macOS."; exit 1; }
arch -x86_64 /usr/bin/true 2>/dev/null || {
    echo "Rosetta 2 fehlt:  softwareupdate --install-rosetta --agree-to-license"; exit 1; }
[ -f "$X86_LIBS/libfreetype.dylib" ] || {
    echo "Keine x86_64-Bibliotheken unter: $X86_LIBS"
    echo "Wine Staging.app nach ~/Downloads legen oder WINMAC_X86_LIBS setzen."; exit 1; }
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew wird benötigt: https://brew.sh"; exit 1
fi
BREW="$(brew --prefix)"
# Werkzeuge + Header. Die Bibliotheken dieser Pakete (arm64) werden nicht gelinkt.
DEPS=(bison flex mingw-w64 pkgconf freetype gnutls sdl2)
echo "==> Prüfe Abhängigkeiten: ${DEPS[*]}"
MISSING=()
for d in "${DEPS[@]}"; do brew list "$d" >/dev/null 2>&1 || MISSING+=("$d"); done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "    Fehlt: ${MISSING[*]}"
    if [ "${WINMAC_AUTO_DEPS:-0}" = "1" ]; then
        brew install "${MISSING[@]}"
    else
        echo "    Installieren mit:  brew install ${MISSING[*]}"
        echo "    oder dieses Skript erneut mit WINMAC_AUTO_DEPS=1 starten."
        exit 1
    fi
fi
for t in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
    command -v "$t" >/dev/null 2>&1 || { echo "$t fehlt (brew install mingw-w64)."; exit 1; }
done

# bison/flex aus brew in den PATH (macOS liefert zu alte Versionen)
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"

# --- 2. Quellen holen --------------------------------------------------------
mkdir -p "$ROOT/thirdparty"
if [ ! -d "$SRC/.git" ]; then
    echo "==> Klone Wine ($WINE_TAG)…"
    git clone --depth 1 --branch "$WINE_TAG" "$WINE_GIT" "$SRC"
else
    echo "==> Wine-Quelle vorhanden, setze auf ${WINE_TAG}…"
    ( cd "$SRC" && git fetch --depth 1 origin tag "$WINE_TAG" && git checkout -f "$WINE_TAG" && git clean -fdx -q )
fi

# --- 3. Eigene Patches anwenden ---------------------------------------------
if compgen -G "$ROOT/patches/*.patch" >/dev/null; then
    echo "==> Wende eigene Patches an…"
    for p in "$ROOT"/patches/*.patch; do
        echo "    - $(basename "$p")"
        ( cd "$SRC" && git apply --check "$p" 2>/dev/null && git apply "$p" ) \
            || echo "      (übersprungen – passt nicht auf $WINE_TAG, siehe patches/README.md)"
    done
fi

# --- 4. x86_64-Bibliotheken bereitstellen ------------------------------------
# Kopiert eine Bibliothek aus $X86_LIBS samt Symlink-Ziel und @loader_path-Abhängigkeiten.
copy_x86_lib() { # $1 Dateiname, $2 Zielordner
    local name="$1" dest="$2" target dep
    [ -e "$dest/$name" ] || [ -L "$dest/$name" ] && return 0
    [ -e "$X86_LIBS/$name" ] || { echo "    Fehlt in $X86_LIBS: $name"; return 1; }
    if [ -L "$X86_LIBS/$name" ]; then
        target="$(readlink "$X86_LIBS/$name")"
        ln -s "$target" "$dest/$name"
        copy_x86_lib "${target##*/}" "$dest"
        return
    fi
    cp "$X86_LIBS/$name" "$dest/"
    for dep in $(otool -arch x86_64 -L "$X86_LIBS/$name" | sed -n 's|^[[:space:]]*@loader_path/\([^ ]*\) .*|\1|p'); do
        copy_x86_lib "$dep" "$dest"
    done
}
copy_x86_libs() { # $1 Zielordner
    mkdir -p "$1"
    for lib in "${X86_LIB_NAMES[@]}"; do copy_x86_lib "$lib" "$1"; done
}

rm -rf "$BUILD"; mkdir -p "$BUILD"
X86_LINK="$BUILD/x86_64-libs"   # nur diese Bibliotheken sieht configure
echo "==> x86_64-Bibliotheken aus ${X86_LIBS}…"
copy_x86_libs "$X86_LINK"
ls "$X86_LINK" | sed 's/^/    /'
# Die Staging-Bibliotheken tragen Installnamen ohne Pfad (z. B. „libfreetype.dylib“).
# configure liest den Namen fürs spätere dlopen aber aus „…/libX.N.dylib“, sonst landet
# Unsinn in config.h. Deshalb bekommen nur diese Kopien zum Linken @rpath/<Dateiname>;
# die Kopien unter runtime/wine-build/lib bleiben unverändert.
for lib in "${X86_LIB_NAMES[@]}"; do
    file="$lib"
    [ -L "$X86_LINK/$lib" ] && file="$(readlink "$X86_LINK/$lib")"
    file="${file##*/}"
    install_name_tool -id "@rpath/$file" "$X86_LINK/$file" 2>/dev/null
    codesign -f -s - "$X86_LINK/$file" 2>/dev/null
done
# Build-Werkzeuge wie tools/sfnt2fon linken FreeType und suchen es beim Ausführen über
# @loader_path/../../ – das ist der Build-Ordner selbst.
copy_x86_libs "$BUILD"

# --- 5. Konfigurieren & Bauen ------------------------------------------------
# Native Werkzeuge (make, clang, mingw) erzeugen x86_64-Code; was configure und der
# Build davon ausführen (Testprogramme, winebuild, widl …), läuft unter Rosetta.
# Kein pkg-config: dessen Homebrew-Einträge zeigen auf arm64-Bibliotheken.
# Kein --with-opengl: Das verlangt ab Wine 11 EGL, das es auf macOS nicht gibt.
# OpenGL läuft hier über winemac.drv und das OpenGL-Framework (CGL) und wird immer gebaut.
echo "==> configure (dies kann dauern)…"
mkdir -p "$BUILD/kein-pkgconfig"
( cd "$BUILD" && PKG_CONFIG_LIBDIR="$BUILD/kein-pkgconfig" PKG_CONFIG_PATH="" "$SRC/configure" \
    --prefix="$PREFIX_INSTALL" \
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 \
    --disable-tests \
    --with-coreaudio --with-freetype --with-gnutls --with-sdl \
    --with-vulkan \
    --without-gstreamer --without-x --without-oss \
    CC="clang -arch x86_64" OBJC="clang -arch x86_64" \
    LDFLAGS="-L$X86_LINK -Wl,-rpath,@loader_path/../../" \
    FREETYPE_CFLAGS="-I$BREW/opt/freetype/include/freetype2" FREETYPE_LIBS="-L$X86_LINK -lfreetype" \
    GNUTLS_CFLAGS="-I$BREW/opt/gnutls/include" GNUTLS_LIBS="-L$X86_LINK -lgnutls" \
    SDL2_CFLAGS="-I$BREW/opt/sdl2/include/SDL2" SDL2_LIBS="-L$X86_LINK -lSDL2" )

echo "==> Gefundene Bibliotheken (Namen fürs dlopen):"
for v in FREETYPE GNUTLS SDL2 VULKAN; do
    n="$(sed -n "s/^#define SONAME_LIB$v \"\(.*\)\"$/\1/p" "$BUILD/include/config.h")"
    case "$n" in
        lib*.dylib) [ -e "$X86_LINK/$n" ] || { echo "    $v: $n liegt nicht unter $X86_LINK"; exit 1; } ;;
        *)          echo "    $v: unbrauchbar („${n}“)"; exit 1 ;;
    esac
    echo "    $v: $n"
done

echo "==> make -j$(sysctl -n hw.ncpu) …"
( cd "$BUILD" && make -j"$(sysctl -n hw.ncpu)" )

# Zum Entwickeln von Patches: nur bauen, die laufende Runtime nicht anfassen.
# Danach einzelne DLLs mit  make -C thirdparty/wine-build-tree dlls/<name>  neu bauen.
if [ "${WINMAC_BUILD_ONLY:-0}" = 1 ]; then
    echo "==> WINMAC_BUILD_ONLY=1: fertig gebaut in $BUILD, nichts installiert."
    exit 0
fi

echo "==> make install → $PREFIX_INSTALL"
rm -rf "$PREFIX_INSTALL"
( cd "$BUILD" && make install )
# Die Unix-Module finden sie über @loader_path/../../ (= lib/), setup-graphics.sh MoltenVK dort.
copy_x86_libs "$PREFIX_INSTALL/lib"

# --- 6. Umbenannten Front-End-Befehlssatz erzeugen ---------------------------
if [ -d "$RUNTIME/bin" ]; then
    echo "==> Sichere bisherige Befehle nach runtime/bin.vorher"
    rm -rf "$RUNTIME/bin.vorher"; cp -a "$RUNTIME/bin" "$RUNTIME/bin.vorher"
fi
echo "==> Erzeuge virtual*-Befehle, die diesen Build kapseln…"
WINE_BIN="$PREFIX_INSTALL/bin" bash "$ROOT/scripts/make-runtime-from-brew.sh"

echo "============================================================"
echo " Fertig. Runtime: $RUNTIME/bin"
echo " Version: $("$PREFIX_INSTALL/bin/wine" --version 2>/dev/null || echo '?')"
echo " Zurück zur vorherigen Runtime:  rm -rf runtime/bin && mv runtime/bin.vorher runtime/bin"
echo "============================================================"
