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

# .NET: nur anbieten, wenn eine Datei bereitliegt (kein Zwang, kein Download hier).
DOTNET="${WINMAC_DOTNET:-$HOME/Downloads/dotnet-desktop.exe}"
DOTNET_FAILED=0
if [ -f "$DOTNET" ]; then
    echo "==> Installiere .NET Desktop Runtime ($DOTNET)…"
    run_logged "$BIN/virtual" "$DOTNET" /install /quiet /norestart
    status=$?
    if [ "$status" != 0 ]; then
        DOTNET_FAILED=1
        echo "    Hinweis: Der .NET-Installer meldete Exitcode $status – .NET fehlt eventuell."
    fi
else
    echo "==> .NET-Installer nicht gefunden ($DOTNET) – übersprungen."
    echo "    (Zum Mitinstallieren dotnet-desktop.exe dorthin legen oder WINMAC_DOTNET setzen.)"
fi

# Registry auf die Platte schreiben lassen (endet der Server, speichert er sie).
wait_server 30
if [ "$DOTNET_FAILED" = 1 ]; then
    echo "==> Einrichtung abgeschlossen (ohne .NET)."
else
    echo "==> Einrichtung abgeschlossen."
fi
