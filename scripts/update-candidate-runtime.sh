#!/bin/bash
# Baut den CrossOver-Arbeitsbaum (thirdparty/wine-cx) inkrementell und legt daraus eine
# Kandidaten-Runtime neben die Live-Runtime, ohne diese anzufassen:
#
#   scripts/update-candidate-runtime.sh [runtime-kandidat]     (Vorgabe: runtime-next)
#
# Der Kandidat ist ein APFS-Klon von runtime/, in den nur geänderte Dateien kommen.
# Danach dieselben Nachbearbeitungen wie build-wine.sh (GStreamer-Suchpfad, ICU) und das
# alte wine.inf-Datum: Ein neueres Datum ließe jeden Raum beim nächsten Start ein
# Wine-Update (wineboot) ausführen. Umschalten erst nach den Tests:
#   mv runtime runtime.vorher && mv runtime-next runtime
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATE="$ROOT/${1:-runtime-next}"
BUILD="$ROOT/thirdparty/wine-cx-build"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/virtual-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
export PATH=/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:$PATH

echo "==> Baue $BUILD"
nice -n 10 make -C "$BUILD" -j"$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)" >"$BUILD/make-candidate.out" 2>&1 ||
    { tail -20 "$BUILD/make-candidate.out"; exit 1; }
make -C "$BUILD" install DESTDIR="$STAGE" >"$BUILD/install-candidate.out" 2>&1
INSTALLED="$(find "$STAGE" -type d -name wine-build -prune | head -1)"
[ -x "$INSTALLED/bin/wine" ] || { echo "make install ohne bin/wine"; exit 1; }

echo "==> Kandidat $CANDIDATE (Klon von runtime/)"
rm -rf "$CANDIDATE"
cp -cR "$ROOT/runtime" "$CANDIDATE"
# Nur geänderte Inhalte übernehmen; zusätzliche Dateien (gst, icu, winemetal) bleiben.
rsync -a -c "$INSTALLED/" "$CANDIDATE/wine-build/" --itemize-changes | { grep -c '^>f' || true; } | sed 's/^/    geänderte Dateien: /'
bash "$ROOT/scripts/bundle-gstreamer.sh" "$CANDIDATE/wine-build" >/dev/null
for arch in x86_64 i386; do
    [ -f "$ROOT/thirdparty/icu/out/$arch-windows/icu.dll" ] || continue
    mkdir -p "$CANDIDATE/wine-build/lib/icu/$arch-windows"
    cp "$ROOT/thirdparty/icu/out/$arch-windows/"{icu,icuuc,icuin}.dll "$CANDIDATE/wine-build/lib/icu/$arch-windows/"
done
"$ROOT/scripts/write-runtime-wrappers.sh" "$CANDIDATE"
if cmp -s "$ROOT/runtime/wine-build/share/wine/wine.inf" "$CANDIDATE/wine-build/share/wine/wine.inf"; then
    touch -r "$ROOT/runtime/wine-build/share/wine/wine.inf" "$CANDIDATE/wine-build/share/wine/wine.inf"
else
    echo "    Hinweis: wine.inf hat sich geändert – Räume aktualisieren sich beim nächsten Start."
fi
echo "==> Fertig: $CANDIDATE ($("$CANDIDATE/wine-build/bin/wine" --version))"
