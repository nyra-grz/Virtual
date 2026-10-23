#!/bin/bash
# Baut die Konformitätstests einer Wine-DLL aus dem eigenen Quellbaum (thirdparty/wine)
# gegen den eigenen Build (thirdparty/wine-build-tree). Der Build läuft mit
# --disable-tests; dieses Skript holt einzelne Tests nach, ohne neu zu konfigurieren.
#
#   scripts/build-wine-test.sh <dll> [Ausgabeordner]     z. B. ncrypt
#
# Ergebnis: <Ausgabeordner>/<dll>_test.exe (Vorgabe: thirdparty/wine-tests).
# Starten:  runtime/bin/virtual <dll>_test.exe [Testname]
# Nur C-Quellen; Tests mit .rc/.idl/.spec-Dateien werden abgelehnt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/thirdparty/wine"
OBJ="$ROOT/thirdparty/wine-build-tree"
DLL="${1:?Aufruf: $0 <dll> [Ausgabeordner]}"
OUT="${2:-$ROOT/thirdparty/wine-tests}"
TESTS="$SRC/dlls/$DLL/tests"
CC=x86_64-w64-mingw32-gcc

[ -f "$TESTS/Makefile.in" ] || { echo "Keine Tests unter $TESTS."; exit 1; }
[ -x "$OBJ/tools/winegcc/winegcc" ] || { echo "Wine-Build fehlt (zuerst WINMAC_BUILD_ONLY=1 ./build-wine.sh)."; exit 1; }
command -v "$CC" >/dev/null || { echo "$CC fehlt (brew install mingw-w64)."; exit 1; }

# Makefile.in-Variablen inklusive Fortsetzungszeilen lesen.
mkvar() {
    sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$TESTS/Makefile.in" |
        sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" | tr -s ' \t' '  '
}
SOURCES="$(mkvar SOURCES)"
IMPORTS="$(mkvar IMPORTS)"
for s in $SOURCES; do
    case "$s" in
        *.c) ;;
        *) echo "Nicht unterstützte Quelle in $DLL/tests: $s"; exit 1 ;;
    esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/winetest-$DLL.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# testlist.c wie makedep: ein Eintrag pro Quelldatei.
{
    printf '#define WIN32_LEAN_AND_MEAN\n#include <windows.h>\n\n#define STANDALONE\n#include "wine/test.h"\n\n'
    for s in $SOURCES; do printf 'extern void func_%s(void);\n' "${s%.c}"; done
    printf '\nconst struct test winetest_testlist[] =\n{\n'
    for s in $SOURCES; do printf '    { "%s", func_%s },\n' "${s%.c}" "${s%.c}"; done
    printf '    { 0, 0 }\n};\n'
} >"$WORK/testlist.c"

CFLAGS=(-c -g -O2 -I"$TESTS" -I"$OBJ/include" -I"$SRC/include" -I"$SRC/include/msvcrt"
        -D_UCRT -D__WINESRC__ -D__WINE_PE_BUILD -fno-strict-aliasing -mcx16 -mcmodel=small -Wno-format)
objs=()
for s in $SOURCES testlist.c; do
    if [ "$s" = testlist.c ]; then file="$WORK/testlist.c"; else file="$TESTS/$s"; fi
    "$CC" "${CFLAGS[@]}" -o "$WORK/${s%.c}.o" "$file"
    objs+=("$WORK/${s%.c}.o")
done

libs=()
for imp in $IMPORTS winecrt0 ucrtbase kernel32 ntdll; do
    lib="$OBJ/dlls/$imp/x86_64-windows/lib$imp.a"
    [ -f "$lib" ] || { echo "Importbibliothek fehlt: $lib"; exit 1; }
    libs+=("$lib")
done
(cd "$OBJ" && tools/winegcc/winegcc -o "$OUT/${DLL}_test.exe" --wine-objdir . \
    -b x86_64-w64-mingw32 -mconsole "${objs[@]}" "${libs[@]}")
echo "==> $OUT/${DLL}_test.exe"
