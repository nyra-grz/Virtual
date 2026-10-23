#!/bin/bash
# Schnelle Runtime: erzeugt den umbenannten "virtual*"-Befehlssatz, der eine bereits
# installierte Wine-Distribution kapselt (Wine Staging.app oder brew wine@staging).
# So läuft die Launcher-App sofort, ohne auf den Quell-Build (build-wine.sh) zu warten.
#
# Ergebnis: ~/WinMac_Virtual/runtime/bin/{virtual,virtualserver,virtualboot,virtualcfg,virtualpath}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/runtime"
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
fi

mkdir -p "$BINDIR"

# --- Wrapper erzeugen ---------------------------------------------------------
# Jeder virtual*-Befehl setzt sinnvolle Vorgaben und ruft das echte Wine-Binary auf.
make_wrapper() {
    local name="$1" target="$2" prefixcmd="${3:-}"
    cat > "$BINDIR/$name" <<WRAP
#!/bin/bash
# Virtual – umbenannter Front-End-Befehl ($name -> $target)
set -uo pipefail
WINE_BIN="\${WINMAC_WINE_BIN:-$WINE_BIN}"
export WINEPREFIX="\${WINEPREFIX:-$HOME/WinMac_Virtual/prefix}"
export WINEDEBUG="\${WINEDEBUG:-err+all}"
# .NET und HTML nicht global deaktivieren; installierte Laufzeiten müssen laden können.
export WINEDLLOVERRIDES="\${WINEDLLOVERRIDES-}"
# Grafik-Runtime (MoltenVK/DXVK/VKD3D), falls eingerichtet
[ -f "$RUNTIME/graphics-env.sh" ] && source "$RUNTIME/graphics-env.sh"
exec "\$WINE_BIN/$target" $prefixcmd "\$@"
WRAP
    chmod +x "$BINDIR/$name"
}

make_wrapper virtual      wine
make_wrapper virtualcfg   winecfg
make_wrapper virtualpath  winepath
make_wrapper virtualserver wineserver

# virtualboot: eigener Befehl oder 'wine wineboot'
if [ -x "$WINE_BIN/wineboot" ]; then
    make_wrapper virtualboot wineboot
else
    cat > "$BINDIR/virtualboot" <<WRAP
#!/bin/bash
set -uo pipefail
WINE_BIN="\${WINMAC_WINE_BIN:-$WINE_BIN}"
export WINEPREFIX="\${WINEPREFIX:-$HOME/WinMac_Virtual/prefix}"
export WINEDEBUG="\${WINEDEBUG:-err+all}"
exec "\$WINE_BIN/wine" wineboot "\$@"
WRAP
    chmod +x "$BINDIR/virtualboot"
fi

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
