#!/bin/bash
# Richtet die Windows-Umgebung (Prefix) beim Erststart ein.
# Wird von der Launcher-App (PrefixSetup) aufgerufen, kann aber auch direkt laufen.
#
#   scripts/init-prefix.sh [windows-version]      z. B. win10 (Vorgabe)
#
# Exitcode 0 nur, wenn der Prefix angelegt ist und die Registry-Werte nachgelesen
# stimmen. Ein gescheiterter (optionaler) .NET-Installer wird gemeldet, ist aber kein Fehler.
set -uo pipefail

ROOT="${WINMAC_ROOT:-$HOME/WinMac_Virtual}"
ASSETS="${WINMAC_ASSETS_ROOT:-$ROOT}"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
export WINEPREFIX="${WINEPREFIX:-$ROOT/prefix}"
VERSION="${1:-win10}"
BIN="$RUNTIME/bin"

[ -x "$BIN/virtual" ] || { echo "Keine Runtime unter $BIN – zuerst Runtime bauen."; exit 1; }

fail() { echo "==> FEHLER: $*"; exit 1; }

# Wine-Ausgabe eingerückt zeigen – über eine Datei, nicht über eine Pipe: Von Wine
# gestartete Dienste (services.exe, winedevice.exe) erben die Pipe und halten sie offen,
# solange der Prefix benutzt wird; sed würde bis dahin auf EOF warten.
run_logged() {
    local log status
    log="$(mktemp "${TMPDIR:-/tmp}/winmac-init.XXXXXX")" || return 1
    "$@" >"$log" 2>&1
    status=$?
    sed 's/^/    /' "$log"
    rm -f "$log"
    return "$status"
}

# Wartet begrenzt auf das Ende des Wineservers dieses Prefixes. Läuft im selben
# Prefix noch ein anderes Windows-Programm, endet der Server nicht von selbst –
# dann nicht ewig blockieren (und das Programm auch nicht beenden).
BUSY=0
wait_server() { # $1 Sekunden
    [ "$BUSY" = 0 ] || return 0
    command -v perl >/dev/null 2>&1 || return 0
    perl -e 'alarm shift; exec @ARGV; die "exec: $!\n"' "$1" "$BIN/virtualserver" -w 2>/dev/null
    [ $? = 142 ] || return 0   # 142 = SIGALRM, also Zeitlimit erreicht
    BUSY=1
    echo "    Hinweis: Im Prefix läuft noch ein anderes Windows-Programm – warte nicht weiter."
    echo "    Die Einstellungen gelten trotzdem; Wine speichert sie, sobald es beendet ist."
}

echo "==> Prefix: $WINEPREFIX"
echo "==> Windows-Version: $VERSION"

echo "==> Lege Windows-Umgebung an (virtualboot)…"
run_logged "$BIN/virtualboot" -i || fail "virtualboot ist gescheitert (Exitcode $?)."
[ -d "$WINEPREFIX/drive_c/windows/system32" ] || fail "Prefix unvollständig: drive_c/windows/system32 fehlt."

# wineboot arbeitet nach dem Rückkehren teils noch im Hintergrund weiter.
wait_server 30

# Module, die eine neuere Runtime mitbringt (winegstreamer für Video), legt Wine nur
# beim Anlegen eines Raums nach system32. In bestehende Räume nur die fehlenden
# übernehmen – vorhandene Dateien (auch native wie .NET) bleiben unberührt –
# und neu übernommene Module registrieren (COM-Klassen wie Medien-Decoder).
WINE_LIB="$RUNTIME/wine-build/lib/wine"
ADDED64=() ADDED32=()
for pair in "x86_64-windows:system32" "i386-windows:syswow64"; do
    arch="${pair%%:*}" sys="$WINEPREFIX/drive_c/windows/${pair#*:}"
    [ -d "$WINE_LIB/$arch" ] && [ -d "$sys" ] || continue
    # Nur Module, die Virtual nach dem ersten Release ergänzt hat; andere legt Wine
    # bewusst woanders ab (z. B. mscorwks, wbem, speech).
    for name in winegstreamer.dll; do
        dll="$WINE_LIB/$arch/$name"
        [ -f "$dll" ] && [ ! -e "$sys/$name" ] || continue
        cp "$dll" "$sys/$name" || continue
        if [ "$arch" = x86_64-windows ]; then ADDED64+=("$name"); else ADDED32+=("$name"); fi
    done
done
if [ "${#ADDED64[@]}" -gt 0 ] || [ "${#ADDED32[@]}" -gt 0 ]; then
    echo "==> Neue Wine-Module übernommen: ${ADDED64[*]:-} ${ADDED32[*]:-}"
    for name in "${ADDED64[@]:-}"; do
        [ -n "$name" ] && "$BIN/virtual" regsvr32 /s "$name" >/dev/null 2>&1
    done
    for name in "${ADDED32[@]:-}"; do
        [ -n "$name" ] && "$BIN/virtual" 'C:\windows\syswow64\regsvr32.exe' /s "$name" >/dev/null 2>&1
    done
    wait_server 30
fi

# Windows-Desktop wie bei CrossOver: eigener Ordner im Raum, der Mac-Schreibtisch nur als
# „My Mac Desktop“ darin. Ältere Räume zeigen direkt auf ~/Desktop – dort landeten sonst
# die .lnk-Verknüpfungen jedes Installers. Vorhandene Dateien bleiben, wo sie sind.
for desktop in "$WINEPREFIX"/drive_c/users/*/Desktop; do
    [ -L "$desktop" ] || continue
    target="$(readlink "$desktop")"
    case "$target" in "$WINEPREFIX"/*) continue ;; esac
    rm "$desktop" && mkdir "$desktop" && ln -s "$target" "$desktop/My Mac Desktop"
    echo "==> Desktop eigenständig: ${desktop#"$WINEPREFIX"/}"
done
# winemenubuilder legt Linux-.desktop-Dateien auf den Mac-Schreibtisch; Virtual findet
# Programme selbst über die Verknüpfungen im Raum.
"$BIN/virtual" reg add 'HKCU\Software\Wine\DllOverrides' /v winemenubuilder.exe /t REG_SZ /d "" /f >/dev/null 2>&1 ||
    echo "    winemenubuilder konnte nicht abgeschaltet werden."

echo "==> Setze Version und Fingerprint-Registry (Windows 10 Pro / Build 19045)…"
EXPECTED=()   # "Schlüssel|name Typ Wert", so wie reg query es (normalisiert) ausgibt
set_reg() { # $1 Schlüssel, $2 Name, $3 Wert, $4 Typ
    local type="${4:-REG_SZ}" shown="$3"
    [ "$type" = REG_DWORD ] && shown="$(printf '0x%x' "$3")"
    "$BIN/virtual" reg add "$1" /v "$2" /t "$type" /d "$3" /f >/dev/null 2>&1 ||
        echo "    $2 konnte nicht gesetzt werden."
    # Namen sind case-insensitiv: Wine hat z. B. schon „EditionId“ und behält diese Schreibweise.
    EXPECTED+=("$1|$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]') $type $shown")
}

set_reg 'HKCU\Software\Wine' Version "$VERSION"
NTKEY='HKLM\Software\Microsoft\Windows NT\CurrentVersion'
set_reg "$NTKEY" CurrentVersion "10.0"
set_reg "$NTKEY" CurrentBuild "19045"
set_reg "$NTKEY" CurrentBuildNumber "19045"
set_reg "$NTKEY" ProductName "Windows 10 Pro"
set_reg "$NTKEY" DisplayVersion "22H2"
set_reg "$NTKEY" EditionID "Professional"
set_reg "$NTKEY" ReleaseId "2009"
set_reg "$NTKEY" CurrentMajorVersionNumber "10" REG_DWORD
set_reg "$NTKEY" CurrentMinorVersionNumber "0" REG_DWORD

# Nachlesen: Ein Exitcode 0 von reg add allein beweist nicht, dass der Wert steht.
echo "==> Prüfe Registry…"
missing=0
for key in 'HKCU\Software\Wine' "$NTKEY"; do
    query_log="$(mktemp "${TMPDIR:-/tmp}/winmac-reg.XXXXXX")" || fail "Temporäres Registry-Protokoll fehlt."
    "$BIN/virtual" reg query "$key" >"$query_log" 2>/dev/null || { rm -f "$query_log"; fail "Registry nicht lesbar: $key"; }
    values="$(tr -d '\r' <"$query_log" | awk '{ $1 = tolower($1); print }')"
    rm -f "$query_log"
    for entry in "${EXPECTED[@]}"; do
        [ "${entry%%|*}" = "$key" ] || continue
        grep -Fqx -- "${entry#*|}" <<<"$values" && continue
        echo "    fehlt oder falsch: $key → ${entry#*|}"
        missing=$((missing + 1))
    done
done
[ "$missing" = 0 ] || fail "$missing Registry-Werte stimmen nicht."

# Ein frischer Wine-Prefix kann den Windows-Cursor-Schlüssel ganz auslassen.
# Leere Cursorpfade wählen die tatsächlich eingebauten Systemcursor. Vorhandene
# Benutzerschemata bleiben erhalten; keine anwendungsspezifische Prüfung wird geändert.
cursor_query="$(mktemp "${TMPDIR:-/tmp}/virtual-cursor-query.XXXXXX")" || fail "Cursor-Konfiguration nicht lesbar."
if ! "$BIN/virtual" reg query 'HKCU\Control Panel' >"$cursor_query" 2>&1; then
    rm -f "$cursor_query"
    fail "Windows-Systemeinstellungen sind nicht lesbar."
fi
if ! tr -d '\r' <"$cursor_query" | grep -Fxiq 'HKEY_CURRENT_USER\Control Panel\Cursors'; then
    cursor_reg="$(mktemp "${TMPDIR:-/tmp}/virtual-cursors.XXXXXX")" || fail "Cursor-Konfiguration nicht anlegbar."
    cat >"$cursor_reg" <<'REG'
REGEDIT4

[HKEY_CURRENT_USER\Control Panel\Cursors]
@="Windows Default"
"Scheme Source"=dword:00000000
"AppStarting"=""
"Arrow"=""
"Crosshair"=""
"Hand"=""
"Help"=""
"IBeam"=""
"No"=""
"NWPen"=""
"Person"=""
"Pin"=""
"SizeAll"=""
"SizeNESW"=""
"SizeNS"=""
"SizeNWSE"=""
"SizeWE"=""
"UpArrow"=""
"Wait"=""
REG
    "$BIN/virtual" regedit /s "$cursor_reg" >"$cursor_reg.log" 2>&1
    cursor_status=$?
    rm -f "$cursor_reg" "$cursor_reg.log"
    [ "$cursor_status" = 0 ] || fail "Windows-Standardcursor konnten nicht eingerichtet werden."
elif "$BIN/virtual" reg query 'HKCU\Control Panel\Cursors' /ve 2>/dev/null \
        | grep -Eq 'REG_SZ[[:space:]]+\(value not set\)|REG_SZ[[:space:]]*$'; then
    # Schlüssel vorhanden, aber ohne Standardwert (ältere Prefixe). Echtes Windows
    # hat dort immer einen. Nur den Standardwert setzen; eigene Cursorpfade bleiben.
    "$BIN/virtual" reg add 'HKCU\Control Panel\Cursors' /ve /d "Windows Default" /f >/dev/null 2>&1 \
        || fail "Windows-Standardcursor konnten nicht eingerichtet werden."
fi

rm -f "$cursor_query"

# .NET: nur anbieten, wenn eine Datei bereitliegt (kein Zwang, kein Download hier).
DOTNET="${WINMAC_DOTNET:-$HOME/Downloads/dotnet-desktop.exe}"
DOTNET_FAILED=0
# Do not guess or run an unrelated installer found in the user's Downloads.
if [ -n "${WINMAC_DOTNET:-}" ] && [ -f "$DOTNET" ]; then
    echo "==> Installiere .NET Desktop Runtime ($DOTNET)…"
    run_logged "$BIN/virtual" "$DOTNET" /install /quiet /norestart
    status=$?
    if [ "$status" != 0 ]; then
        DOTNET_FAILED=1
        echo "    Hinweis: Der .NET-Installer meldete Exitcode $status – .NET fehlt eventuell."
    fi
else
    echo "==> Wine Mono ist die Standard-.NET-Laufzeit; vorhandenes Microsoft .NET bleibt erhalten."
fi

# DirectX 10/11 über DXVK (DXMT pro Raum mit setup-graphics.sh --dxmt). Ohne das scheitert in einem
# neuen Raum schon D3D11CreateDevice (z. B. Epic Games Launcher stürzt sofort ab).
# Nur aus den bereits geladenen Paketen, kein Download hier; schlägt es fehl, bleibt
# der Raum bei WineD3D.
if { [ -s "$ASSETS/thirdparty/graphics/dxmt.tar.gz" ] || [ -s "$ASSETS/thirdparty/graphics/dxvk.tar.gz" ]; } && [ -f "$ASSETS/setup-graphics.sh" ]; then
    echo "==> Richte DirectX 10/11 ein…"
    run_logged /bin/bash "$ASSETS/setup-graphics.sh" || fail "Grafikunterstützung konnte nicht eingerichtet werden. Bitte die Einrichtung erneut starten."
else
    echo "==> Grafikpakete nicht geladen – übersprungen."
    echo "    (Einmal ./setup-graphics.sh ausführen, dann bekommen neue Räume DXMT/DXVK.)"
fi

# Registry auf die Platte schreiben lassen (endet der Server, speichert er sie).
wait_server 30
if [ "$DOTNET_FAILED" = 1 ]; then
    echo "==> Einrichtung abgeschlossen (ohne .NET)."
else
    echo "==> Einrichtung abgeschlossen."
fi
