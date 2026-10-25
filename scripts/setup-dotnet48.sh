#!/bin/bash
# Installiert Microsofts .NET Framework 4.8 in einen Raum – statt Wine Mono. Für Programme,
# die das echte .NET brauchen, etwa weil sie Windows-10-Schnittstellen (WinRT) nutzen.
# Wird von der Launcher-App aufgerufen, kann aber auch direkt laufen:
#
#   WINEPREFIX=/pfad/zum/prefix scripts/setup-dotnet48.sh [windows-version]
#
# Ablauf wie bei winetricks (Wine Mono entfernen, .NET 4.0 als XP, 4.8 als Windows 7),
# danach das, was unter Wine sonst fehlt:
#   - System.Runtime.WindowsRuntime(.UI.Xaml) aus dem Windows-10-Paket des Installers
#     (der Windows-7-Weg legt nur Platzhalter an, ohne die keine WinRT-Aufrufe gehen),
#   - Windows.winmd in system32\WinMetadata (Typbeschreibungen für RoResolveNamespace),
#   - Registry-Einträge und UIAutomationCore.dll, falls der Installer sie nicht anlegt,
#   - WPF mit Software-Darstellung und ohne NGen (beides hängt unter Wine auf dem Mac).
# Microsofts Dateien werden bei Microsoft bzw. aus microsoft/windows-rs (MIT) geladen und
# per SHA-256 geprüft; Virtual verteilt sie nicht selbst.
set -uo pipefail

ROOT="${WINMAC_ROOT:-$HOME/WinMac_Virtual}"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
export WINEPREFIX="${WINEPREFIX:-$ROOT/prefix}"
VERSION="${1:-win10}"
BIN="$RUNTIME/bin"
CACHE="$ROOT/thirdparty/managed/dotnet48"
WIN="$WINEPREFIX/drive_c/windows"
export WINEDEBUG="${WINEDEBUG:--all}" MVK_CONFIG_LOG_LEVEL=0

[ -x "$BIN/virtual" ] || { echo "Keine Runtime unter $BIN – zuerst Runtime bauen."; exit 1; }
[ -d "$WIN/system32" ] || { echo "Raum nicht eingerichtet: $WIN/system32 fehlt."; exit 1; }

fail() { echo "==> FEHLER: $*"; exit 1; }

# Wine-Ausgabe über eine Datei statt einer Pipe (Dienste erben Pipes und halten sie offen).
run_logged() {
    local log status
    log="$(mktemp "${TMPDIR:-/tmp}/winmac-dotnet.XXXXXX")" || return 1
    "$@" >"$log" 2>&1
    status=$?
    grep -v '^\s*$' "$log" | sed 's/^/    /' | tail -n 20
    rm -f "$log"
    return "$status"
}
# Mit Zeitlimit, damit ein hängender Installer die Einrichtung nicht ewig blockiert.
limited() { perl -e 'alarm shift; exec @ARGV; die "exec: $!\n"' "$@"; }
wine() { "$BIN/virtual" "$@"; }
# Ausgabe eines Wine-Befehls über eine Datei holen – nie über eine Pipe (siehe oben).
wine_output() {
    local out
    out="$(mktemp "${TMPDIR:-/tmp}/winmac-dotnet.XXXXXX")" || return 1
    "$BIN/virtual" "$@" >"$out" 2>&1   # uninstaller --list schreibt auf stderr
    tr -d '\r' <"$out"
    rm -f "$out"
}
reg_missing() { ! wine reg query "$1" /v "$2" >/dev/null 2>&1; }
ensure_reg() { # $1 Schlüssel, $2 Name, $3 Wert, [$4 Typ] – nur setzen, wenn er fehlt
    reg_missing "$1" "$2" && wine reg add "$1" /v "$2" /t "${4:-REG_SZ}" /d "$3" /f >/dev/null
    return 0
}

fetch() { # $1 URL, $2 SHA-256, $3 Dateiname
    local file="$CACHE/$3"
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$2" ]; then return 0; fi
    echo "    lade $3…"
    curl -fL --retry 3 --connect-timeout 20 -o "$file.part" "$1" || { rm -f "$file.part"; return 1; }
    [ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" = "$2" ] || { rm -f "$file.part"; echo "    Prüfsumme falsch: $3"; return 1; }
    mv "$file.part" "$file"
}

# Der NGen-Arbeitsprozess (mscorsvw) dreht unter Wine endlos mit voller CPU und hält den
# Installer auf. Ohne ihn übersetzt .NET Programme beim Start (JIT) – nur etwas langsamer.
INSTALL_OVERRIDES="fusion=b;winedbg.exe=d;mscorsvw.exe=d"

echo "==> Raum: $WINEPREFIX"
mkdir -p "$CACHE"
echo "==> Lade Microsoft .NET Framework 4.0, 4.8 und die WinRT-Typbeschreibungen…"
fetch https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe \
      65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f dotNetFx40_Full_x86_x64.exe || fail "Download .NET 4.0"
fetch https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe \
      95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53 ndp48-x86-x64-allos-enu.exe || fail "Download .NET 4.8"
# Die volle Union-Metadatei des SDK (windows-rs 0.58.0). Neuere windows-rs-Fassungen sind
# umgebaut; damit bildet die CLR Typen wie EventRegistrationToken nicht mehr ab.
fetch https://raw.githubusercontent.com/microsoft/windows-rs/db06b51c2ebb743efb544d40e3064efa49f28d38/crates/libs/bindgen/default/Windows.winmd \
      c3088f561534e1d6f7318f81816c3e6feea554ccfd7065769df0e3dcf871bfe9 Windows.winmd || fail "Download Windows.winmd"

# Laufende Programme des Raums würden Dateien sperren.
"$BIN/virtualserver" -k 2>/dev/null
limited 30 "$BIN/virtualserver" -w 2>/dev/null
restore_version() {
    local status=$?
    trap - EXIT
    wine reg add 'HKCU\Software\Wine' /v Version /d "$VERSION" /f >/dev/null 2>&1
    [ -z "${EXTRACT:-}" ] || rm -rf "$EXTRACT"
    exit "$status"
}
trap restore_version EXIT

echo "==> Entferne Wine Mono aus diesem Raum…"
installed="$(wine_output uninstaller --list)"
for desc in 'Wine Mono Windows Support' 'Wine Mono Runtime' 'Wine Mono'; do
    uuid="$(echo "$installed" | grep "$desc" | head -1 | cut -f1 -d'|')"
    [ -n "$uuid" ] || continue
    # uninstaller --remove öffnet den Windows Installer mit Rückfrage; still deinstallieren.
    run_logged limited 300 "$BIN/virtual" msiexec /x "$uuid" /qn
done
# Wine Mono und abgebrochene .NET-Installer (etwa aus dem Setup eines Programms)
# hinterlassen Einträge, nach denen Microsofts Installer „bereits installiert“ melden
# und nichts tun. Vor einer frischen Installation also immer wegräumen.
wine reg delete 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v3.5' /f >/dev/null 2>&1
wine reg delete 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' /f >/dev/null 2>&1
echo "$installed" | grep '|||Microsoft .NET Framework 4' | cut -f1 -d'|' | while read -r key; do
    [ -n "$key" ] || continue
    echo "    entferne alten Eintrag: $key"
    wine reg delete 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\'"$key" /f >/dev/null 2>&1
    wine reg delete 'HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\'"$key" /f >/dev/null 2>&1
done
# Wines eigene mscoree.dll weicht, damit der Installer Microsofts Fassung ablegen kann.
for dll in "$WIN/system32/mscoree.dll" "$WIN/syswow64/mscoree.dll"; do
    [ -f "$dll" ] && grep -q -a WINE_MONO_OVERRIDES "$dll" && rm -f "$dll"
done

echo "==> Installiere .NET Framework 4.0 (als Windows XP, dauert einige Minuten)…"
wine reg add 'HKCU\Software\Wine' /v Version /d winxp64 /f >/dev/null
WINEDLLOVERRIDES="$INSTALL_OVERRIDES" run_logged limited 1800 "$BIN/virtual" "$CACHE/dotNetFx40_Full_x86_x64.exe" /q /c:"install.exe /q"
status=$?
case "$status" in 0|3010|194) ;; *) fail ".NET 4.0-Installer endete mit Status $status." ;; esac
wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f >/dev/null
wine reg add 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Install /t REG_DWORD /d 1 /f >/dev/null
wine reg add 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full' /v Version /d 4.0.30319 /f >/dev/null
# Verhindert eine Rückfrage bei Prefix-Updates (Wine-Bug 41727).
wine reg add 'HKLM\Software\Microsoft\.NETFramework' /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >/dev/null
wine reg add 'HKLM\Software\Wow6432Node\Microsoft\.NETFramework' /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f >/dev/null
limited 120 "$BIN/virtualserver" -w 2>/dev/null

echo "==> Installiere .NET Framework 4.8 (als Windows 7, dauert einige Minuten)…"
wine reg add 'HKCU\Software\Wine' /v Version /d win7 /f >/dev/null
WINEDLLOVERRIDES="$INSTALL_OVERRIDES" run_logged limited 2400 "$BIN/virtual" "$CACHE/ndp48-x86-x64-allos-enu.exe" /sfxlang:1027 /q /norestart
status=$?
case "$status" in 0|3010|194) ;; *) fail ".NET 4.8-Installer endete mit Status $status." ;; esac
limited 120 "$BIN/virtualserver" -w 2>/dev/null

echo "==> Ergänze die Windows-10-Teile (WinRT-Brücke, Typbeschreibungen)…"
EXTRACT="$(mktemp -d "${TMPDIR:-/tmp}/winmac-ndp48.XXXXXX")" || fail "kein temporärer Ordner"
SEVENZ="$(command -v 7zz || command -v 7z || true)"
if [ -n "$SEVENZ" ]; then
    "$SEVENZ" x -y -o"$EXTRACT" "$CACHE/ndp48-x86-x64-allos-enu.exe" 'x64-Windows10.0-KB4486153-x64.cab' >/dev/null
else
    # Ohne 7-Zip entpackt der Installer sich selbst.
    limited 600 "$BIN/virtual" "$CACHE/ndp48-x86-x64-allos-enu.exe" /x:"Z:${EXTRACT//\//\\}" /q >/dev/null 2>&1
fi
CAB="$EXTRACT/x64-Windows10.0-KB4486153-x64.cab"
[ -f "$CAB" ] || fail "Windows-10-Paket nicht im Installer gefunden."
cabextract -q -d "$EXTRACT/cab" -F 'msil_system.runtime.windowsruntime*' "$CAB" >/dev/null 2>&1 \
    || (cd "$EXTRACT" && mkdir -p cab && cd cab && "${SEVENZ:-false}" x -y "$CAB" 'msil_system.runtime.windowsruntime*' >/dev/null) \
    || fail "cabextract oder 7-Zip fehlt (brew install cabextract)."
for name in System.Runtime.WindowsRuntime System.Runtime.WindowsRuntime.UI.Xaml; do
    lower="$(echo "$name" | tr 'A-Z' 'a-z')"
    src="$(find "$EXTRACT/cab" -path "*msil_${lower}_b77a5c561934e089_*" -name "$lower.dll" | head -1)"
    [ -f "$src" ] || fail "$name.dll fehlt im Windows-10-Paket."
    gac="$WIN/Microsoft.NET/assembly/GAC_MSIL/$name/v4.0_4.0.0.0__b77a5c561934e089"
    mkdir -p "$gac"
    cp "$src" "$gac/$name.dll"
    for fw in Framework Framework64; do
        [ -d "$WIN/Microsoft.NET/$fw/v4.0.30319" ] && cp "$src" "$WIN/Microsoft.NET/$fw/v4.0.30319/$name.dll"
    done
done
rm -rf "$EXTRACT"
for dir in system32 syswow64; do
    [ -d "$WIN/$dir" ] || continue
    mkdir -p "$WIN/$dir/WinMetadata" "$WIN/$dir/WinMetadata.wine"
    # Wines eigene .winmd-Dateien beschreiben nur Teile eines Namensraums; die CLR nimmt
    # die Datei mit dem passendsten Namen und fände dort Methoden nicht.
    for winmd in "$WIN/$dir/WinMetadata"/*.winmd; do
        [ -f "$winmd" ] && [ "$(basename "$winmd")" != Windows.winmd ] && mv -f "$winmd" "$WIN/$dir/WinMetadata.wine/"
    done
    cp "$CACHE/Windows.winmd" "$WIN/$dir/WinMetadata/Windows.winmd"
done

echo "==> Prüfe Registry und Systemdateien…"
NDP='HKLM\Software\Microsoft\NET Framework Setup\NDP\v4'
ensure_reg 'HKLM\Software\Microsoft\.NETFramework' InstallRoot 'C:\windows\Microsoft.NET\Framework64\'
ensure_reg 'HKLM\Software\Wow6432Node\Microsoft\.NETFramework' InstallRoot 'C:\windows\Microsoft.NET\Framework\'
ensure_reg "$NDP\\Client" InstallPath 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\'
ensure_reg "$NDP\\Full" InstallPath 'C:\windows\Microsoft.NET\Framework64\v4.0.30319\'
ensure_reg 'HKLM\Software\Microsoft\.NETFramework\Policy\v4.0' 30319 30319-30319
ensure_reg 'HKLM\Software\Microsoft\.NETFramework\Policy\Standards\v1.0.0' v4.0.30319 30319 REG_DWORD
ensure_reg 'HKLM\Software\Microsoft\.NETFramework\Policy\Standards\Standard CLI 2005' v4.0.30319 4095 REG_DWORD
# WPF zeichnet sonst über Direct3D 9 → wined3d → OpenGL, und das hängt auf dem Mac
# (Render-Thread bleibt in wglMakeCurrent stehen). Software-Darstellung ist zuverlässig.
wine reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f >/dev/null
# WPF braucht UIAutomationCore; Wines eigene Fassung zurücklegen, falls sie fehlt.
for pair in "x86_64-windows:system32" "i386-windows:syswow64"; do
    src="$RUNTIME/wine-build/lib/wine/${pair%%:*}/uiautomationcore.dll"
    dst="$WIN/${pair##*:}/uiautomationcore.dll"
    [ -f "$dst" ] || { [ -f "$src" ] && cp "$src" "$dst"; }
done

# Die .NET-Optimierungsdienste würden NGen sonst bei jedem Start im Hintergrund anwerfen.
for service in clr_optimization_v4.0.30319_32 clr_optimization_v4.0.30319_64; do
    wine reg add "HKLM\\System\\CurrentControlSet\\Services\\$service" /v Start /t REG_DWORD /d 4 /f >/dev/null 2>&1
done
wine reg add 'HKCU\Software\Wine' /v Version /d "$VERSION" /f >/dev/null
limited 60 "$BIN/virtualserver" -w 2>/dev/null

release="$(wine_output reg query "$NDP\\Full" /v Release | tr -d '\r' | awk '/Release/ {print $3}')"
[ -n "$release" ] && [ $((release)) -ge 528040 ] || fail ".NET 4.8 ist nicht registriert (Release=${release:-fehlt})."
[ -f "$WIN/Microsoft.NET/assembly/GAC_MSIL/System.Runtime.WindowsRuntime/v4.0_4.0.0.0__b77a5c561934e089/System.Runtime.WindowsRuntime.dll" ] \
    || fail "WinRT-Brücke fehlt."
mkdir -p -m 700 "$WINEPREFIX/.virtual"   # der Anmelde-Helfer verlangt 0700
echo "4.8 $((release))" > "$WINEPREFIX/.virtual/dotnet"
echo "==> Fertig: .NET Framework 4.8 (Release $((release))) mit WinRT-Unterstützung, Windows-Version $VERSION."
