#!/bin/bash
# setup-graphics.sh — 3D-Runtime für den Prefix einrichten.
#
#   DirectX 10/11   -> DXVK (macOS-Port) -> Vulkan -> MoltenVK -> Metal   (Standard)
#                      oder --dxmt: DXMT -> Metal (schneller, echte GPU-Angaben; bricht aber
#                      bei noch fehlenden D3D11-Funktionen hart ab, z. B. SwapDeviceContextState)
#   DirectX 9       -> bleibt bei WineD3D
#   DirectX 12      -> VKD3D-Proton      -> Vulkan -> MoltenVK -> Metal   (optional)
#
# DXMT braucht seine Metal-Brücke winemetal in der Wine-Installation
# (scripts/install-dxmt-runtime.sh); fehlt sie, bleibt der Raum bei DXVK.
#
# MoltenVK kommt aus der gekapselten Wine-Installation selbst (dort x86_64 + arm64).
# Das Homebrew-MoltenVK ist nur arm64 und passt NICHT zum x86_64-Wine unter Rosetta.
#
# Ehrliche Grenzen:
#  - DXVK-macOS ist ein älterer Port (1.10.x) und liefert nur d3d10core + d3d11;
#    dxgi kommt von Wine. DX10/11-Spiele laufen oft, nicht immer.
#  - VKD3D-Proton braucht Vulkan-Funktionen, die MoltenVK nur teilweise hat.
#    DX12 läuft damit meist nicht, deshalb nur mit --dx12.
#  - MetalFX ist nicht enthalten.
#  - Zurück auf WineD3D: ./setup-graphics.sh --off (stellt die Original-DLLs wieder her).
set -euo pipefail

ROOT="${WINMAC_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
ASSETS="${WINMAC_ASSETS_ROOT:-$ROOT}"
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
THIRD="$ROOT/thirdparty/graphics"
BIN="$RUNTIME/bin"
export WINEPREFIX="${WINEPREFIX:-$ROOT/prefix}"
SYS64="$WINEPREFIX/drive_c/windows/system32"
SYS32="$WINEPREFIX/drive_c/windows/syswow64"
BACKUP="$WINEPREFIX/.winmac-graphics-backup"

DXVK_REPO="Gcenx/DXVK-macOS"
VKD3D_REPO="HansKristian-Work/vkd3d-proton"
DXVK_DLLS=(d3d9 d3d10core d3d11 dxgi)
DXMT_DLLS=(d3d10core d3d11 dxgi)
VKD3D_DLLS=(d3d12 d3d12core)

usage() {
    echo "Aufruf: $0 [--dxmt | --dxvk] [--dx12] | --off"
    echo "  (ohne Argument)  DXVK für DirectX 10/11 einrichten (über Vulkan/MoltenVK)"
    echo "  --dxmt           stattdessen DXMT (direkt über Metal, schneller, noch Lücken)"
    echo "  --dxvk           DXVK ausdrücklich (Standard)"
    echo "  --dx12           zusätzlich VKD3D-Proton für DirectX 12 (experimentell)"
    echo "  --off            alles zurück auf WineD3D"
}

set_override() { # $1 dll, $2 Ladereihenfolge
    "$BIN/virtual" reg add 'HKCU\Software\Wine\DllOverrides' /v "$1" /d "$2" /f >/dev/null 2>&1
}

# Sicherung pro Architektur: $BACKUP/<system32|syswow64>/<dll>.dll ist das Original;
# <dll>.neu heißt „gab es vorher nicht“ – solche DLLs löscht --off wieder.
# Gesichert wird nur beim ersten Mal, sonst würde ein zweiter Lauf die schon
# ersetzte DLL als Original ablegen.
backup_dll() { # $1 Systemordner, $2 Sicherungsordner, $3 DLL
    local sys="$1" bak="$2" dll="$3"
    mkdir -p "$bak"
    if [ -f "$bak/$dll.dll" ] || [ -f "$bak/$dll.neu" ]; then return 0; fi
    if [ -f "$sys/$dll.dll" ]; then cp "$sys/$dll.dll" "$bak/"; else : >"$bak/$dll.neu"; fi
}

restore_dll() { # $1 Systemordner, $2 Sicherungsordner, $3 DLL
    local sys="$1" bak="$2" dll="$3"
    if [ -f "$bak/$dll.dll" ]; then
        rm -f "$sys/$dll.dll"
        cp "$bak/$dll.dll" "$sys/"
        rm -f "$bak/$dll.dll"
    elif [ -f "$bak/$dll.neu" ]; then
        rm -f "$sys/$dll.dll" "$bak/$dll.neu"
    fi
}

disable_graphics() {
    echo "==> Zurück auf WineD3D…"
    for dll in "${DXVK_DLLS[@]}" "${VKD3D_DLLS[@]}" winemetal; do
        restore_dll "$SYS64" "$BACKUP/system32" "$dll"
        restore_dll "$SYS32" "$BACKUP/syswow64" "$dll"
        WINMAC_EXPECT_NONZERO=1 "$BIN/virtual" reg delete 'HKCU\Software\Wine\DllOverrides' /v "$dll" /f >/dev/null 2>&1 || true
    done
    rmdir "$BACKUP/system32" "$BACKUP/syswow64" "$BACKUP" 2>/dev/null || true
    rm -f "$WINEPREFIX/.virtual/graphics-env.sh" "$WINEPREFIX/.virtual/graphics-backend"
    echo "    Erledigt. Wine rendert wieder selbst."
}

WANT_DX12=0
# Ohne Angabe die zuletzt für diesen Raum gewählte Variante (bleibt bei Engine-Updates)
BACKEND="$(cat "$WINEPREFIX/.virtual/graphics-backend" 2>/dev/null || echo dxvk)"
case "$BACKEND" in dxmt|dxvk) ;; *) BACKEND=dxvk ;; esac
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --off)     disable_graphics; exit 0 ;;
        --dx12)    WANT_DX12=1 ;;
        --dxvk)    BACKEND=dxvk ;;
        --dxmt)    BACKEND=dxmt ;;
        *)         usage; exit 1 ;;
    esac
done

[ -x "$BIN/virtual" ] || { echo "Keine Runtime – zuerst scripts/make-runtime-from-brew.sh oder build-wine.sh."; exit 1; }
[ -d "$SYS64" ] || { echo "Prefix noch nicht eingerichtet ($SYS64 fehlt) – zuerst scripts/init-prefix.sh."; exit 1; }

# --- MoltenVK aus der Wine-Installation prüfen -------------------------------
echo "==> MoltenVK prüfen…"
WINE_BIN="${WINMAC_WINE_BIN:-$RUNTIME/wine-build/bin}"
if [ ! -x "$WINE_BIN/wine" ]; then
    if [ -f "$RUNTIME/external-wine-bin" ]; then
        IFS= read -r WINE_BIN < "$RUNTIME/external-wine-bin"
    else
        WINE_BIN="$(sed -n 's|^WINE_BIN="\${WINMAC_WINE_BIN:-\(.*\)}"$|\1|p' "$BIN/virtual")"
    fi
fi
MVK="$WINE_BIN/../lib/libMoltenVK.dylib"
# 'file' statt 'lipo': lipo gehört zu den Xcode-Tools und fehlt ohne sie.
MVK_INFO="$(file -b "$MVK" 2>/dev/null || true)"
if [ -f "$MVK" ] && [[ "$MVK_INFO" == *x86_64* ]]; then
    echo "    MoltenVK aus der Wine-Installation (x86_64) gefunden."
else
    echo "    Kein x86_64-MoltenVK unter $WINE_BIN/../lib – ohne das läuft kein Vulkan."
    exit 1
fi

# --- Helfer ------------------------------------------------------------------
fetch_asset() { # $1 Repo, $2 Muster für den Asset-Namen, $3 Zieldatei
    if [ -s "$3" ]; then echo "    Schon geladen: $(basename "$3")"; return 0; fi
    local url
    url="$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
        | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
        | grep -E "$2" | grep -v -- '-builtin' | head -1)"
    [ -n "$url" ] || { echo "    Kein passendes Asset in $1"; return 1; }
    echo "    Lade $(basename "$url")…"
    if curl -fL# --retry 2 --connect-timeout 20 "$url" -o "$3.part"; then
        mv "$3.part" "$3"
    else
        rm -f "$3.part"
        return 1
    fi
}

extract() { # $1 Archiv, $2 Zielordner
    rm -rf "$2"; mkdir -p "$2"
    tar -xf "$1" -C "$2" 2>/dev/null && return 0
    command -v zstd >/dev/null && zstd -dc "$1" | tar -xf - -C "$2" && return 0
    echo "    Konnte $(basename "$1") nicht entpacken"; return 1
}

install_dlls() { # $1 entpackter Ordner, $2 Name des 32-Bit-Ordners, dann DLL-Namen
    local dir="$1" d32="$2"; shift 2
    local src64 src32
    src64="$(find "$dir" -type d -name x64 | head -1)"
    src32="$(find "$dir" -type d -name "$d32" | head -1)"
    [ -n "$src64" ] || { echo "    Kein x64-Ordner im Archiv"; return 1; }
    for dll in "$@"; do
        local got=0
        # rm vor cp: Ist die DLL ein Symlink in die Runtime, nicht durch ihn hindurchschreiben.
        if [ -f "$src64/$dll.dll" ]; then
            backup_dll "$SYS64" "$BACKUP/system32" "$dll"
            rm -f "$SYS64/$dll.dll"
            cp "$src64/$dll.dll" "$SYS64/"; echo "      64 Bit: $dll.dll"; got=1
        fi
        if [ -n "$src32" ] && [ -d "$SYS32" ] && [ -f "$src32/$dll.dll" ]; then
            backup_dll "$SYS32" "$BACKUP/syswow64" "$dll"
            rm -f "$SYS32/$dll.dll"
            cp "$src32/$dll.dll" "$SYS32/"; echo "      32 Bit: $dll.dll"; got=1
        fi
        # Override nur für DLLs, die wirklich im Paket waren.
        if [ "$got" = 1 ]; then
            set_override "$dll" "native,builtin"
        else
            echo "      ($dll.dll nicht im Paket – bleibt bei Wine)"
        fi
    done
}

mkdir -p "$THIRD"
for pkg in dxvk.tar.gz dxmt.tar.gz; do
    if [ "$ASSETS" != "$ROOT" ] && [ -s "$ASSETS/thirdparty/graphics/$pkg" ] && [ ! -s "$THIRD/$pkg" ]; then
        cp "$ASSETS/thirdparty/graphics/$pkg" "$THIRD/$pkg"
    fi
done

# DXMTs d3d11/dxgi/d3d10core sind als Wine-builtin markiert; ohne die Markierung
# lädt Wine sie aus system32 wie native DLLs (pro Raum statt für die ganze Runtime).
# winemetal.dll bleibt builtin und geht in ihre eigene Unix-Bibliothek winemetal.so.
install_dxmt() { # $1 entpackter Ordner
    local src sys bak dll
    src="$(dirname "$(find "$1" -maxdepth 2 -type d -name x86_64-windows | head -1)")"
    for pair in "x86_64-windows:$SYS64:system32" "i386-windows:$SYS32:syswow64"; do
        IFS=: read -r arch sys bak <<<"$pair"
        [ -d "$sys" ] && [ -d "$src/$arch" ] || continue
        for dll in "${DXMT_DLLS[@]}" winemetal; do
            [ -f "$src/$arch/$dll.dll" ] || continue
            backup_dll "$sys" "$BACKUP/$bak" "$dll"
            rm -f "$sys/$dll.dll"
            cp "$src/$arch/$dll.dll" "$sys/"
            if [ "$dll" != winemetal ]; then
                printf '\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' | dd of="$sys/$dll.dll" bs=1 seek=64 conv=notrunc 2>/dev/null
            fi
            echo "      ${arch%%-*}: $dll.dll"
        done
    done
    for dll in "${DXMT_DLLS[@]}"; do set_override "$dll" "native,builtin"; done
    # DXVK-Reste (d3d9 hat DXMT nicht) wieder Wine überlassen
    restore_dll "$SYS64" "$BACKUP/system32" d3d9
    restore_dll "$SYS32" "$BACKUP/syswow64" d3d9
    WINMAC_EXPECT_NONZERO=1 "$BIN/virtual" reg delete 'HKCU\Software\Wine\DllOverrides' /v d3d9 /f >/dev/null 2>&1 || true
}

if [ "$BACKEND" = dxmt ] && [ ! -f "$WINE_BIN/../lib/wine/x86_64-unix/winemetal.so" ]; then
    echo "==> DXMT-Brücke fehlt in der Runtime – nehme DXVK."
    BACKEND=dxvk
fi
if [ "$BACKEND" = dxmt ] && [ ! -s "$THIRD/dxmt.tar.gz" ]; then
    echo "==> DXMT-Paket nicht vorhanden – nehme DXVK (scripts/install-dxmt-runtime.sh lädt es)."
    BACKEND=dxvk
fi

if [ "$BACKEND" = dxmt ]; then
    # --- DXMT (DirectX 10/11 über Metal) -------------------------------------
    echo "==> DXMT (DirectX 10/11)…"
    extract "$THIRD/dxmt.tar.gz" "$THIRD/dxmt"
    install_dxmt "$THIRD/dxmt"
else
    # --- DXVK (DirectX 10/11) ------------------------------------------------
    echo "==> DXVK (DirectX 10/11)…"
    fetch_asset "$DXVK_REPO" 'dxvk-macOS.*\.tar\.gz$' "$THIRD/dxvk.tar.gz"
    extract "$THIRD/dxvk.tar.gz" "$THIRD/dxvk"
    install_dlls "$THIRD/dxvk" x32 "${DXVK_DLLS[@]}"
    # DXMT-Reste (dxgi, winemetal) wieder Wine überlassen; DXVK-macOS bringt kein dxgi mit
    for dll in dxgi winemetal; do
        restore_dll "$SYS64" "$BACKUP/system32" "$dll"
        restore_dll "$SYS32" "$BACKUP/syswow64" "$dll"
    done
    WINMAC_EXPECT_NONZERO=1 "$BIN/virtual" reg delete 'HKCU\Software\Wine\DllOverrides' /v dxgi /f >/dev/null 2>&1 || true
fi

# --- VKD3D-Proton (DirectX 12, optional) -------------------------------------
if [ "$WANT_DX12" = 1 ]; then
    echo "==> VKD3D-Proton (DirectX 12, experimentell)…"
    fetch_asset "$VKD3D_REPO" 'vkd3d-proton-[0-9.]+\.tar\.zst$' "$THIRD/vkd3d.tar.zst"
    extract "$THIRD/vkd3d.tar.zst" "$THIRD/vkd3d"
    install_dlls "$THIRD/vkd3d" x86 "${VKD3D_DLLS[@]}"
fi

# --- Umgebung für die virtual*-Befehle ---------------------------------------
mkdir -p "$WINEPREFIX/.virtual"
printf '%s\n' "$BACKEND" > "$WINEPREFIX/.virtual/graphics-backend"
cat > "$WINEPREFIX/.virtual/graphics-env.sh" <<'ENV'
# Erzeugt von setup-graphics.sh – wird von den virtual*-Befehlen geladen.
# DXVK-macOS ist ein Async-Build: Shader im Hintergrund übersetzen (weniger Ruckler).
export DXVK_ASYNC="${DXVK_ASYNC:-1}"
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-none}"
export DXMT_LOG_LEVEL="${DXMT_LOG_LEVEL:-none}"
# FPS-Anzeige bei Bedarf:  DXVK_HUD=fps runtime/bin/virtual spiel.exe
ENV

echo "============================================================"
echo " Grafik-Runtime eingerichtet ($([ "$BACKEND" = dxmt ] && echo "DXMT über Metal" || echo "DXVK über MoltenVK"))."
echo "   DLLs:      $SYS64 (+ syswow64)"
echo "   Sicherung: $BACKUP"
echo "   Env:       $WINEPREFIX/.virtual/graphics-env.sh"
[ "$WANT_DX12" = 1 ] || echo "   DirectX 12 nicht eingerichtet (bei Bedarf: --dx12)"
echo
echo " Zurück auf WineD3D:  ./setup-graphics.sh --off"
echo "============================================================"
