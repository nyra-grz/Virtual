#!/bin/bash
# Relocatable launchers: the same engine must work on another Mac and from a DMG.
set -euo pipefail
RUNTIME="${1:?runtime directory required}"
mkdir -p "$RUNTIME/bin"
if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$RUNTIME/external-wine-bin"; fi
for name in virtual virtualboot virtualserver virtualcfg virtualpath; do
    cat > "$RUNTIME/bin/$name" <<'WRAPPER'
#!/bin/bash
set -uo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"
WINE_BIN="${WINMAC_WINE_BIN:-$RUNTIME/wine-build/bin}"
if [ ! -x "$WINE_BIN/wine" ] && [ -f "$RUNTIME/external-wine-bin" ]; then
    IFS= read -r WINE_BIN < "$RUNTIME/external-wine-bin"
fi
export WINEPREFIX="${WINEPREFIX:-$HOME/WinMac_Virtual/prefix}"
# CrossOver FOSS otherwise hardcodes the Windows username to "crossover".
# Keep the existing Wine identity and profile paths when upgrading Virtual rooms.
export CX_REPORT_REAL_USERNAME=1
export WINEDEBUG="${WINEDEBUG:-fixme-all}"
# CrossOver's msync: Windows sync objects over Mach semaphores instead of a wineserver
# round trip (winrt/tests/sync.c: mutex/semaphore ~23x, thread ping-pong ~3x faster).
# Off for a room or test with WINEMSYNC=0.
export WINEMSYNC="${WINEMSYNC:-1}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES-}"
export DXVK_ASYNC="${DXVK_ASYNC:-1}" DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
if [ -f "$WINEPREFIX/.virtual/graphics-env.sh" ]; then
    source "$WINEPREFIX/.virtual/graphics-env.sh"
elif [ -f "$RUNTIME/graphics-env.sh" ]; then
    source "$RUNTIME/graphics-env.sh"
fi
# Gebündeltes GStreamer (scripts/bundle-gstreamer.sh) für Video/Audio in Windows-Programmen
GST_DIR="$WINE_BIN/../lib/gst"
if [ -d "$GST_DIR/gstreamer-1.0" ]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_DIR/gstreamer-1.0" GST_PLUGIN_PATH_1_0="" GST_REGISTRY_FORK=no
    export GST_REGISTRY_1_0="${GST_REGISTRY_1_0:-$HOME/Library/Caches/Virtual/gstreamer-registry.x86_64.bin}"
    mkdir -p "$(dirname "$GST_REGISTRY_1_0")" 2>/dev/null
fi
if [ -x "$RUNTIME/sspi/bin/virtual-ntlm-auth" ]; then
    export VIRTUAL_LOCAL_AUTH_HELPER="${VIRTUAL_LOCAL_AUTH_HELPER:-$RUNTIME/sspi/bin/virtual-ntlm-auth}"
    export VIRTUAL_LOCAL_AUTH_FILE="${VIRTUAL_LOCAL_AUTH_FILE:-$WINEPREFIX/.virtual/local-identity.json}"
fi
case "$(basename "$0")" in
    virtual)       exec "$WINE_BIN/wine" "$@" ;;
    virtualserver) exec "$WINE_BIN/wineserver" "$@" ;;
    virtualboot)   exec "$WINE_BIN/wine" wineboot "$@" ;;
    virtualcfg)    exec "$WINE_BIN/wine" winecfg "$@" ;;
    virtualpath)   exec "$WINE_BIN/wine" winepath "$@" ;;
esac
WRAPPER
    chmod 755 "$RUNTIME/bin/$name"
done
