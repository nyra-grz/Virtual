#!/bin/bash
# Projektprüfung unter macOS; funktioniert auch aus einem Git-Worktree:
#   WINMAC_HOME=~/WinMac_Virtual ./scripts/smoke-test.sh
# Quellcode/App-Build: dieses Checkout. Runtime/DXVK: WINMAC_HOME.
# Alle Wine-Aufrufe (auch innerhalb init-prefix.sh) haben ein 60-s-Limit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
WINMAC_HOME="${WINMAC_HOME:-$ROOT}"
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SCRATCH=""
WINE_READY=0
PREFIX_READY=0

report() {
    local state="$1" label="$2" detail="${3:-}"
    case "$state" in
        ok) OK_COUNT=$((OK_COUNT + 1)) ;;
        FEHLER) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        übersprungen) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
    printf '%s: %s%s\n' "$state" "$label" "${detail:+ – $detail}"
}

show_log() {
    # Diagnose begrenzen, damit ein Wine-Absturz nicht die Zusammenfassung verdeckt.
    [ ! -s "$1" ] || tail -n 30 "$1" | sed 's/^/    /'
}

finish() {
    local original_status=$? cleanup_status=0
    trap - EXIT INT TERM HUP
    if [ "$WINE_READY" = 1 ]; then
        # Die Shims erzwingen auch hier WINEPREFIX und das 60-s-Limit.
        "$WINMAC_RUNTIME/bin/virtualserver" -k >"$SCRATCH/stop.log" 2>&1
        cleanup_status=$?
        if [ "$cleanup_status" = 0 ]; then
            "$WINMAC_RUNTIME/bin/virtualserver" -w >>"$SCRATCH/stop.log" 2>&1
            cleanup_status=$?
        fi
        if [ "$cleanup_status" = 0 ]; then
            report ok "Wegwerf-Prefix: virtualserver beendet"
        else
            report FEHLER "Wegwerf-Prefix: virtualserver beenden" "Exitcode $cleanup_status"
            show_log "$SCRATCH/stop.log"
        fi
    fi
    if [ -n "$SCRATCH" ]; then
        if rm -rf -- "$SCRATCH"; then
            report ok "Temporäre Dateien und Wegwerf-Prefix gelöscht"
        else
            report FEHLER "Temporäre Dateien löschen" "$SCRATCH"
        fi
    fi
    if [ "$original_status" != 0 ] && [ "$FAIL_COUNT" = 0 ]; then
        report FEHLER "Testlauf abgebrochen" "Exitcode $original_status"
    fi
    printf '\nZusammenfassung: %d ok, %d FEHLER, %d übersprungen.\n' \
        "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    [ "$FAIL_COUNT" = 0 ] && exit 0
    exit 1
}
trap finish EXIT
trap 'report FEHLER "Abbruch durch Signal"; exit 130' INT
trap 'report FEHLER "Abbruch durch Signal"; exit 143' TERM HUP

printf 'Virtual – Smoke-Test\nQuellprojekt: %s\nWINMAC_HOME: %s\n\n' "$ROOT" "$WINMAC_HOME"
if ! WINMAC_HOME="$(cd "$WINMAC_HOME" && pwd -P)"; then
    report FEHLER "WINMAC_HOME" "Ordner nicht gefunden"
    exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
    report FEHLER "Zeitbegrenzung" "perl fehlt; Wine wird nicht gestartet"
    exit 1
fi
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/winmac-smoke.XXXXXX")" || {
    report FEHLER "Temporären Ordner anlegen"
    exit 1
}
SCRATCH="$(cd "$SCRATCH" && pwd -P)" || exit 1
export WINEPREFIX="$SCRATCH/prefix"
export WINEARCH=win64
export WINEDEBUG=-all
export WINEDLLOVERRIDES='mscoree,mshtml=d;winedbg.exe=d'
export DXVK_LOG_PATH="$SCRATCH"
export DXVK_STATE_CACHE_PATH="$SCRATCH"
export WINMAC_ROOT="$ROOT"
# Nie automatisch einen vorhandenen Installer aus ~/Downloads ausführen.
export WINMAC_DOTNET="$SCRATCH/kein-dotnet-installer.exe"
printf 'Wegwerf-Prefix: %s\n\n' "$WINEPREFIX"

# a) App nur in diesem Checkout bauen, nicht im gemeinsamen WINMAC_HOME.
if [ "$(uname -s)" != Darwin ] || ! command -v swift >/dev/null 2>&1; then
    report übersprungen "App-Build und Info.plist" "macOS mit Swift erforderlich"
elif /bin/bash "$ROOT/build-app.sh" >"$SCRATCH/app-build.log" 2>&1; then
    BUNDLE="$ROOT/build/Virtual.app"
    if [ -x "$BUNDLE/Contents/MacOS/Virtual" ]; then
        report ok "App-Build" "$BUNDLE"
    else
        report FEHLER "App-Build" "ausführbare Datei im Bundle fehlt"
    fi
    # Strukturierte Prüfung ausschließlich innerhalb CFBundleDocumentTypes.
    plist_ok=1
    if ! /usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist" >"$SCRATCH/plist.log" 2>&1; then
        plist_ok=0
    else
        /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' \
            "$BUNDLE/Contents/Info.plist" >"$SCRATCH/document-types.log" 2>>"$SCRATCH/plist.log" || plist_ok=0
        for extension in exe msi; do
            found=0
            index=0
            while /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$index" \
                    "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; do
                if /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:$index:CFBundleTypeExtensions" \
                    "$BUNDLE/Contents/Info.plist" 2>/dev/null |
                        grep -Eq "^[[:space:]]*$extension[[:space:]]*$"; then
                    found=1
                fi
                index=$((index + 1))
            done
            [ "$found" = 1 ] || plist_ok=0
        done
    fi
    if [ "$plist_ok" = 1 ]; then
        report ok "Info.plist" "CFBundleDocumentTypes enthält exe und msi"
    else
        report FEHLER "Info.plist" "gültige Dokumenttypen für exe und msi fehlen"
        show_log "$SCRATCH/plist.log"
    fi
else
    report FEHLER "App-Build" "build-app.sh fehlgeschlagen"
    show_log "$SCRATCH/app-build.log"
    report übersprungen "Info.plist" "App-Build fehlgeschlagen"
fi

# init-prefix.sh benutzt absolute Runtime-Pfade. Temporäre Shims begrenzen daher
# jeden internen virtual/virtualboot/virtualserver-Aufruf, nicht nur das Skript.
export WINMAC_SMOKE_RUNTIME="$WINMAC_HOME/runtime"
export WINMAC_RUNTIME="$SCRATCH/timed-runtime"
export WINMAC_SMOKE_FAILURES="$SCRATCH/wine-failures.log"
if [ -x "$WINMAC_SMOKE_RUNTIME/bin/virtual" ] &&
   [ -x "$WINMAC_SMOKE_RUNTIME/bin/virtualboot" ] &&
   [ -x "$WINMAC_SMOKE_RUNTIME/bin/virtualserver" ]; then
    mkdir -p "$WINMAC_RUNTIME/bin" || exit 1
    for tool in virtual virtualboot virtualserver; do
        cat >"$WINMAC_RUNTIME/bin/$tool" <<'WRAPPER'
#!/bin/bash
set -uo pipefail
: "${WINEPREFIX:?Wegwerf-Prefix muss gesetzt sein}"
tool="${0##*/}"
perl -e 'alarm shift; exec @ARGV; die "exec: $!\n"' 60 "$WINMAC_SMOKE_RUNTIME/bin/$tool" "$@"
status=$?
if [ "$status" != 0 ]; then
    printf '%s: Exitcode %s\n' "$tool" "$status" >>"$WINMAC_SMOKE_FAILURES"
fi
exit "$status"
WRAPPER
        chmod +x "$WINMAC_RUNTIME/bin/$tool" || exit 1
    done
    WINE_READY=1
else
    report FEHLER "Runtime-Dateien" "virtual, virtualboot oder virtualserver fehlt unter $WINMAC_SMOKE_RUNTIME/bin"
fi

# Sämtliche Testausgaben/Shader-Caches landen im temporären Arbeitsverzeichnis.
cd "$SCRATCH" || exit 1
# b) Runtime-Version, ebenfalls mit explizitem WINEPREFIX.
if [ "$WINE_READY" = 1 ]; then
    if "$WINMAC_RUNTIME/bin/virtual" --version >version.log 2>&1; then
        report ok "Runtime --version"
        show_log version.log
    else
        report FEHLER "Runtime --version" "Start fehlgeschlagen oder 60-s-Limit erreicht"
        show_log version.log
    fi
else
    report übersprungen "Runtime --version" "Runtime-Dateien fehlen"
fi

# c) Auch verschluckte Fehler des Setup-Skripts werden über die Shims erfasst.
if [ "$WINE_READY" = 1 ]; then
    : >"$WINMAC_SMOKE_FAILURES"
    /bin/bash "$ROOT/scripts/init-prefix.sh" win10 >prefix.log 2>&1
    setup_status=$?
    if [ "$setup_status" = 0 ] && [ ! -s "$WINMAC_SMOKE_FAILURES" ] &&
       [ -d "$WINEPREFIX/drive_c/windows/system32" ]; then
        PREFIX_READY=1
        report ok "Wegwerf-Prefix einrichten" "init-prefix.sh win10"
    else
        report FEHLER "Wegwerf-Prefix einrichten" "Exitcode $setup_status; interne Wine-Fehler werden mitgeprüft"
        show_log prefix.log
        show_log "$WINMAC_SMOKE_FAILURES"
    fi
    # Unabhängig vom Skriptstatus den tatsächlich gespeicherten Wert abfragen.
    if "$WINMAC_RUNTIME/bin/virtual" reg query \
            'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v ProductName >product-name.log 2>&1 &&
       tr -d '\r' <product-name.log | grep -Eq \
            '^[[:space:]]*ProductName[[:space:]]+REG_SZ[[:space:]]+Windows 10 Pro[[:space:]]*$'; then
        report ok "Registry ProductName" "Windows 10 Pro"
    else
        report FEHLER "Registry ProductName" "Windows 10 Pro nicht erfolgreich abgefragt"
        show_log product-name.log
    fi
else
    report übersprungen "Wegwerf-Prefix einrichten" "Runtime-Dateien fehlen"
    report übersprungen "Registry ProductName" "Runtime-Dateien fehlen"
fi

# .NET muss über den echten CLR-Einstieg laufen; ein vorhandenes Verzeichnis
# allein beweist nicht, dass mscoree und der verwaltete Code funktionieren.
managed_test() {
    local compiler="$WINMAC_HOME/runtime/wine-build/share/wine/mono/wine-mono-10.4.1/lib/mono/4.5/csc.exe"
    local source_path output_path status output
    if [ "$PREFIX_READY" != 1 ] || [ ! -f "$compiler" ]; then
        report übersprungen ".NET-CLR" "eingerichteter Prefix und eigene Wine-Mono-Runtime erforderlich"
        return
    fi
    if ! WINEDLLOVERRIDES='winedbg.exe=d' "$WINMAC_RUNTIME/bin/virtualboot" -u >mono-setup.log 2>&1; then
        report FEHLER "Wine-Mono-Prefix einrichten"
        show_log mono-setup.log
        return
    fi
    cat >managed.cs <<'CS'
using System;
class ManagedSmoke {
    static int Main() {
        Console.WriteLine("WINMAC_SMOKE_CLR=" + Environment.Version.Major + ";BITS=" + (IntPtr.Size * 8));
        return 37;
    }
}
CS
    source_path="Z:${SCRATCH//\//\\}\\managed.cs"
    output_path="Z:${SCRATCH//\//\\}\\managed.exe"
    if ! WINEDLLOVERRIDES='winedbg.exe=d' "$WINMAC_RUNTIME/bin/virtual" "$compiler" /nologo /platform:x64 "/out:$output_path" "$source_path" >managed-compile.log 2>&1; then
        report FEHLER ".NET-Test kompilieren"
        show_log managed-compile.log
        return
    fi
    report ok ".NET-Test kompilieren"
    WINEDLLOVERRIDES='winedbg.exe=d' "$WINMAC_RUNTIME/bin/virtual" "$SCRATCH/managed.exe" >managed.out 2>managed.err
    status=$?
    output="$(tr -d '\r' <managed.out)"
    if [ "$status" = 37 ] && [ "$output" = 'WINMAC_SMOKE_CLR=4;BITS=64' ]; then
        report ok ".NET-CLR ausführen" "$output; Exitcode 37"
    else
        report FEHLER ".NET-CLR ausführen" "Exitcode $status oder unerwartete Ausgabe"
        show_log managed.out
        show_log managed.err
    fi
}
managed_test

# d) Ein echter, absichtlich von null verschiedener Programm-Exitcode prüft,
# dass Wrapper nicht nur printf ausgeben, sondern den Status weiterreichen.
cat >console.c <<'C'
#include <stdio.h>
int main(void)
{
    printf("WINMAC_SMOKE_BITS=%u\n", (unsigned)(8 * sizeof(void *)));
    return 37;
}
C
console_test() {
    local bits="$1" compiler="$2" status output
    if ! command -v "$compiler" >/dev/null 2>&1; then
        report übersprungen "$bits-Bit-Konsole" "$compiler fehlt"
    elif ! "$compiler" -Wall -Wextra -Werror console.c -o "console-$bits.exe" >"compile-$bits.log" 2>&1; then
        report FEHLER "$bits-Bit-Konsole kompilieren"
        show_log "compile-$bits.log"
    else
        report ok "$bits-Bit-Konsole kompilieren"
        file "console-$bits.exe" | sed 's/^/    /'
        if [ "$PREFIX_READY" != 1 ]; then
            report übersprungen "$bits-Bit-Konsole ausführen" "Prefix-Einrichtung fehlgeschlagen"
            return
        fi
        "$WINMAC_RUNTIME/bin/virtual" "$SCRATCH/console-$bits.exe" >"console-$bits.out" 2>"console-$bits.err"
        status=$?
        output="$(tr -d '\r' <"console-$bits.out")"
        if [ "$status" = 37 ] && [ "$output" = "WINMAC_SMOKE_BITS=$bits" ]; then
            report ok "$bits-Bit-Konsole ausführen" "$output; Exitcode 37"
        else
            report FEHLER "$bits-Bit-Konsole ausführen" "Exitcode $status statt 37 oder unerwartete Ausgabe"
            show_log "console-$bits.out"
            show_log "console-$bits.err"
        fi
    fi
}
console_test 64 x86_64-w64-mingw32-gcc
console_test 32 i686-w64-mingw32-gcc

# e) Ausschließlich Hardware-Gerät; kein stiller WARP-/Software-Fallback.
cat >d3d11.c <<'C'
#define COBJMACROS
#include <stdio.h>
#include <string.h>
#include <d3d11.h>
int main(int argc, char **argv)
{
    const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3, D3D_FEATURE_LEVEL_9_2, D3D_FEATURE_LEVEL_9_1
    };
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
        levels, sizeof(levels) / sizeof(levels[0]), D3D11_SDK_VERSION, &device, &level, &context);
    /* Ältere Runtime kennt 11.1 nicht; weiterhin nur Hardware anfragen. */
    if (hr == E_INVALIDARG)
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
            levels + 1, sizeof(levels) / sizeof(levels[0]) - 1,
            D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr) || !device || !context)
    {
        fprintf(stderr, "D3D11CreateDevice fehlgeschlagen: 0x%08lx\n", (unsigned long)hr);
        if (context) ID3D11DeviceContext_Release(context);
        if (device) ID3D11Device_Release(device);
        return 2;
    }
    printf("D3D11 Hardware: Feature-Level %u.%u (0x%04x)\n",
        (unsigned)level >> 12, ((unsigned)level >> 8) & 15, (unsigned)level);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return argc > 1 && !strcmp(argv[1], "11") && level < D3D_FEATURE_LEVEL_11_0 ? 3 : 0;
}
C

d3d_test() {
    local dxvk="$WINMAC_HOME/thirdparty/graphics/dxvk" src="" candidate count=0
    local dll minimum=0 overrides="$WINEDLLOVERRIDES" system32="$WINEPREFIX/drive_c/windows/system32"
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        report übersprungen "D3D11" "x86_64-w64-mingw32-gcc fehlt"
        return
    fi
    if ! x86_64-w64-mingw32-gcc -Wall -Wextra -Werror d3d11.c -o d3d11.exe -ld3d11 >compile-d3d11.log 2>&1; then
        report FEHLER "D3D11-Test kompilieren"
        show_log compile-d3d11.log
        return
    fi
    report ok "D3D11-Test kompilieren"
    if [ "$PREFIX_READY" != 1 ]; then
        report übersprungen "D3D11 ausführen" "Prefix-Einrichtung fehlgeschlagen"
        return
    fi
    if [ -d "$dxvk" ]; then
        # Archive können eine zusätzliche Versionsverzeichnisebene enthalten.
        if ! find "$dxvk" -type f -path '*/x64/d3d11.dll' >dxvk-candidates.log 2>dxvk-find.log; then
            report FEHLER "DXVK finden"
            show_log dxvk-find.log
            return
        fi
        while IFS= read -r candidate; do
            if [ -f "${candidate%/*}/d3d10core.dll" ]; then
                src="${candidate%/*}"
                count=$((count + 1))
            fi
        done <dxvk-candidates.log
        if [ "$count" != 1 ] || [ -L "$system32" ]; then
            report FEHLER "DXVK vorbereiten" "genau ein x64-DLL-Paar und ein lokales system32 erforderlich (gefunden: $count)"
            return
        fi
        for dll in d3d11 d3d10core; do
            # Wine kann Builtins als Symlinks anlegen: nicht durch sie auf die Runtime schreiben.
            if ! rm -f -- "$system32/$dll.dll" || ! cp "$src/$dll.dll" "$system32/$dll.dll"; then
                report FEHLER "DXVK kopieren" "$dll.dll"
                return
            fi
        done
        minimum=11
        overrides="$overrides;d3d11,d3d10core=n"
        report ok "DXVK im Wegwerf-Prefix" "$src; Mindest-Feature-Level 11.0"
    else
        report übersprungen "DXVK" "Verzeichnis fehlt; Hardware-Gerät mit WineD3D wird trotzdem geprüft"
    fi
    if WINEDLLOVERRIDES="$overrides" "$WINMAC_RUNTIME/bin/virtual" "$SCRATCH/d3d11.exe" "$minimum" >d3d11.log 2>&1; then
        report ok "D3D11-Hardware-Gerät"
        show_log d3d11.log
    else
        report FEHLER "D3D11-Hardware-Gerät" "Exitcode $?; bei DXVK ist Feature-Level >= 11.0 erforderlich"
        show_log d3d11.log
    fi
}
d3d_test
# EXIT-Trap beendet den Prefix-Server, löscht die temporären Dateien und bilanziert.
exit 0
