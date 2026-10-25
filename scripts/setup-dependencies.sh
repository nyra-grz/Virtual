#!/bin/bash
# Invoked only for components detected in the selected executable/runtimeconfig.
# Winetricks supplies upstream recipes and checksums; its auto-update and GUI are off.
set -euo pipefail
ROOT="${WINMAC_ROOT:-$HOME/WinMac_Virtual}"
ASSETS="${WINMAC_ASSETS_ROOT:-$ROOT}"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
: "${WINEPREFIX:?Windows room is required}"
export PATH="$RUNTIME/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WINE="$RUNTIME/bin/virtual" WINE64="$RUNTIME/bin/virtual"
export WINESERVER="$RUNTIME/bin/virtualserver" WINEBOOT="$RUNTIME/bin/virtualboot"
export W_CACHE="$ROOT/thirdparty/managed/winetricks"
export XDG_CONFIG_HOME="$ROOT/config" WINETRICKS_LATEST_VERSION_CHECK=disabled
export WINEDEBUG=-all
mkdir -p "$W_CACHE" "$WINEPREFIX/.virtual/components"
for component in "$@"; do
    case "$component" in
        vcrun2005|vcrun2008|vcrun2010|vcrun2012|vcrun2013|vcrun2026|mfc42|vb6run) ;;
        d3dcompiler_43|d3dcompiler_47|d3dx9|d3dx10_43|d3dx11_43|physx|msxml4|msxml6|openal|xna40) ;;
        dotnet*)
            [[ "$component" =~ ^dotnet(desktop)?(6|7|8|9|10)-(x86|x64)(@[0-9]+\.[0-9]+\.[0-9]+)?$ ]] || exit 1
            ;;
        *) echo "Unbekannte Windows-Komponente: $component" >&2; exit 1 ;;
    esac
    MARKER="$WINEPREFIX/.virtual/components/$component"
    [ ! -f "$MARKER" ] || continue
    echo "==> Richte Windows-Komponente ein: $component"
    case "$component" in
        dotnet*)
            PY="$RUNTIME/sspi/python/bin/python3"
            [ -x "$PY" ] || PY="$RUNTIME/sspi/venv/bin/python"
            "$PY" -I "$ASSETS/scripts/install-dotnet-runtime.py" "$component"
            ;;
        *)
            [ -x "$RUNTIME/tools/winetricks" ] || { echo "Komponenten-Unterstützung fehlt im App-Paket." >&2; exit 1; }
            /bin/sh "$RUNTIME/tools/winetricks" --unattended "$component"
            ;;
    esac
    printf '%s\n' "$component" > "$MARKER.tmp"
    mv "$MARKER.tmp" "$MARKER"
done
