#!/usr/bin/env python3
"""Install a supported .NET runtime from Microsoft's current release metadata.

Unlike a fixed old desktop-runtime recipe, this uses the current patch release
in the required major/minor channel and verifies Microsoft's published SHA-512.
https://github.com/dotnet/core/tree/main/release-notes
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlparse


def curl(url, destination=None):
    host = urlparse(url).hostname or ""
    if not (host.endswith(".microsoft.com") or host in {"dotnetcli.azureedge.net", "dotnetcli.blob.core.windows.net"}):
        raise RuntimeError("Unerwartete Download-Adresse in .NET-Metadaten")
    args = ["/usr/bin/curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "20", "--max-time", "900", url]
    if destination:
        subprocess.run(args + ["--output", str(destination)], check=True)
    else:
        return subprocess.check_output(args + ["--silent", "--show-error"])


def install(component):
    match = re.fullmatch(r"dotnet(desktop)?(6|7|8|9|10)-(x86|x64)(?:@(\d+\.\d+\.\d+))?", component)
    if not match:
        raise RuntimeError("Nicht unterstützte .NET-Komponente")
    desktop, major, arch, minimum = match.groups()
    minimum = tuple(int(part) for part in (minimum or (major + ".0.0")).split("."))
    package = "windowsdesktop" if desktop else "runtime"
    framework = "Microsoft.WindowsDesktop.App" if desktop else "Microsoft.NETCore.App"
    prefix = Path(os.environ["WINEPREFIX"])
    program_files = "Program Files (x86)" if arch == "x86" else "Program Files"
    installed = prefix / "drive_c" / program_files / "dotnet" / "shared" / framework
    # Existing compatible installations are preserved, including user-installed ones.
    def compatible(path):
        return path.is_dir() and re.fullmatch(r"\d+\.\d+\.\d+", path.name) and path.name.startswith(major + ".0.") and tuple(map(int, path.name.split("."))) >= minimum
    if installed.is_dir() and any(compatible(p) for p in installed.iterdir()):
        print(f"==> {framework} {major}.0 ({arch}) ist vorhanden.", flush=True)
        return
    metadata = json.loads(curl(f"https://builds.dotnet.microsoft.com/dotnet/release-metadata/{major}.0/releases.json"))
    release = next(r for r in metadata["releases"] if package in r)
    if tuple(map(int, release[package]["version"].split("."))) < minimum:
        raise RuntimeError("Die vom Programm benötigte .NET-Version ist in diesem Kanal noch nicht verfügbar")
    asset = next(f for f in release[package]["files"] if f["rid"] == "win-" + arch and f["name"].endswith(".exe"))
    digest = asset["hash"].lower()
    if not re.fullmatch(r"[0-9a-f]{128}", digest):
        raise RuntimeError(".NET-Metadaten enthalten keine gültige Prüfsumme")
    cache = Path(os.environ["WINMAC_ROOT"]) / "thirdparty" / "managed" / "dotnet"
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / (digest[:16] + "-" + asset["name"])
    def verified(path):
        if not path.is_file():
            return False
        with path.open("rb") as stream:
            return hashlib.file_digest(stream, "sha512").hexdigest() == digest
    if not verified(target):
        temporary = target.with_suffix(".part")
        print(f"==> Lade {framework} {release[package]['version']} ({arch}) von Microsoft…", flush=True)
        try:
            curl(asset["url"], temporary)
            if not verified(temporary):
                raise RuntimeError(".NET-Download hat eine falsche Prüfsumme")
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    runtime = Path(os.environ["WINMAC_RUNTIME"])
    result = subprocess.run([str(runtime / "bin/virtual"), str(target), "/install", "/quiet", "/norestart"], timeout=900)
    if result.returncode not in (0, 105, 194):
        raise RuntimeError(f".NET-Installer meldet Status {result.returncode}")
    if not installed.is_dir() or not any(compatible(p) for p in installed.iterdir()):
        raise RuntimeError("Der Installer hat die benötigte .NET-Laufzeit nicht angelegt")
    print(f"==> {framework} {major}.0 ({arch}) ist eingerichtet.", flush=True)


if __name__ == "__main__":
    try:
        install(sys.argv[1])
    except Exception as error:
        print(f".NET-Einrichtung fehlgeschlagen: {error}", file=sys.stderr)
        sys.exit(1)
