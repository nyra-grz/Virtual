#!/bin/bash
# Schnelle Runtime: erzeugt den umbenannten "virtual*"-Befehlssatz, der eine bereits
# installierte Wine-Distribution kapselt (Wine Staging.app oder brew wine@staging).
# So läuft die Launcher-App sofort, ohne auf den Quell-Build (build-wine.sh) zu warten.
#
# Ergebnis: ~/WinMac_Virtual/runtime/bin/{virtual,virtualserver,virtualboot,virtualcfg,virtualpath}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
BINDIR="$RUNTIME/bin"

# --- Wine-Installation finden -------------------------------------------------
find_wine_bin() {
    local candidates=(
        "${WINE_BIN:-}"
        "$RUNTIME/wine-build/bin"
        "$HOME/Downloads/Wine Staging.app/Contents/Resources/wine/bin"
        "/Applications/Wine Staging.app/Contents/Resources/wine/bin"
    )
    for c in "${candidates[@]}"; do
        [ -n "$c" ] && [ -x "$c/wine" ] && { echo "$c"; return 0; }
    done
    # Homebrew
    if command -v brew >/dev/null 2>&1; then
        local p; p="$(brew --prefix wine@staging 2>/dev/null || true)"
        [ -n "$p" ] && [ -x "$p/bin/wine" ] && { echo "$p/bin"; return 0; }
        p="$(brew --prefix wine 2>/dev/null || true)"
        [ -n "$p" ] && [ -x "$p/bin/wine" ] && { echo "$p/bin"; return 0; }
    fi
    return 1
}

WINE_BIN="$(find_wine_bin)" || {
    echo "Keine Wine-Installation gefunden."
    echo "Lege 'Wine Staging.app' nach ~/Downloads oder installiere:  brew install --cask wine-staging"
    echo "oder baue aus dem Quelltext:  ./build-wine.sh"
    exit 1
}
echo "==> Nutze Wine aus: $WINE_BIN"

# Der eigene Wine-Build benötigt seine passende verwaltete Laufzeit. Andere
# Wine-Installationen bringen Mono selbst mit und werden nicht verändert.
if [ "$WINE_BIN" = "$RUNTIME/wine-build/bin" ]; then
    "$ROOT/scripts/setup-managed-runtime.sh"
    # Braucht den msv1_0-Patch 0013; ohne uv bleibt nur die lokale Anmeldung aus.
    "$ROOT/scripts/setup-local-auth.sh" || echo "    (lokale Windows-Anmeldung nicht eingerichtet)"
fi

mkdir -p "$BINDIR"

# Use relocatable wrappers for both source builds and external development runtimes.
"$ROOT/scripts/write-runtime-wrappers.sh" "$RUNTIME" "$WINE_BIN"

# Herkunft dokumentieren
cat > "$RUNTIME/RUNTIME.txt" <<INFO
Virtual Runtime (Schnellvariante)
Erstellt: $(date)
Gekapselte Wine-Installation: $WINE_BIN
Wine-Version: $("$WINE_BIN/wine" --version 2>/dev/null || echo "unbekannt")

Dies ist die Schnell-Runtime, die eine vorhandene Wine-Distribution umbenennt.
Die reproduzierbare Quell-Variante erzeugt build-wine.sh unter runtime/wine-build.
INFO

echo "==> Runtime fertig: $BINDIR"
ls -1 "$BINDIR"
echo
echo "Test:  $BINDIR/virtual --version"
"$BINDIR/virtual" --version 2>/dev/null || true
