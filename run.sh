#!/bin/bash
# Virtual — Wine-Frontend mit Kompatibilitäts-Tweaks
set -uo pipefail

ROOT="$HOME/WinMac_Virtual"
PREFIX="$ROOT/prefix"
WINE="$HOME/Downloads/Wine Staging.app/Contents/Resources/wine/bin"

export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="mscoree=d;mshtml=d"

mkdir -p "$ROOT"

init_prefix() {
    if [ ! -d "$PREFIX/drive_c" ]; then
        echo "==> Lege Windows-Umgebung an…"
        "$WINE/wine" wineboot -i >/dev/null 2>&1
        echo "==> Setze Windows 10 (Kompatibilität)…"
        "$WINE/wine" reg add "HKCU\\Software\\Wine" /v Version /d "win10" /f >/dev/null 2>&1
        "$WINE/wine" reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" /v CurrentVersion /d "10.0" /f >/dev/null 2>&1
        "$WINE/wine" reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" /v CurrentBuild /d "19045" /f >/dev/null 2>&1
        "$WINE/wine" reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" /v ProductName /d "Windows 10 Pro" /f >/dev/null 2>&1
        "$WINE/wine" reg add "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion" /v DisplayVersion /d "22H2" /f >/dev/null 2>&1
    fi
}

install_dotnet() {
    if [ ! -d "$PREFIX/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App" ]; then
        echo "==> Installiere .NET Desktop Runtime…"
        "$WINE/wine" "$HOME/Downloads/dotnet-desktop.exe" /install /quiet /norestart >/dev/null 2>&1
    fi
}

case "${1:-}" in
    init)
        init_prefix
        install_dotnet
        echo "Fertig. Prefix: $PREFIX"
        ;;
    ""|-h|--help)
        echo "Virtual <programm.exe> [argumente…]"
        echo "Virtual init"
        ;;
    *)
        init_prefix
        EXE="$1"; shift
        if [ ! -f "$EXE" ]; then echo "Datei nicht gefunden: $EXE"; exit 1; fi
        echo "==> Starte $EXE"
        exec "$WINE/wine" "$EXE" "$@"
        ;;
esac
