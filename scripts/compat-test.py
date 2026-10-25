#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Automatischer Kompatibilitätstest: echte Windows-Apps installieren und starten.

Holt Installer über die öffentlichen winget-Manifeste (mit Prüfsumme), installiert
jede App still in einem eigenen, frisch geklonten Raum, startet sie und hält fest,
ob ein Fenster erscheint oder sie abstürzt (mit Bildschirmfoto des Fensters).

    uv run scripts/compat-test.py [winget-IDs …] [--out ORDNER] [--runtime runtime]

Ohne IDs wird die Standardliste getestet. Ergebnis: ORDNER/report.md + results.json.
Die Fenster der getesteten Apps erscheinen kurz auf dem Bildschirm.
"""
import argparse, hashlib, json, os, re, shlex, shutil, subprocess, sys, time, urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_APPS = [
    "Google.Chrome", "Mozilla.Firefox", "Brave.Brave", "VideoLAN.VLC", "7zip.7zip",
    "Notepad++.Notepad++", "Discord.Discord", "Valve.Steam", "EpicGames.EpicGamesLauncher",
    "Microsoft.VisualStudioCode", "Telegram.TelegramDesktop", "Audacity.Audacity",
    "GIMP.GIMP.3", "KeePassXCTeam.KeePassXC", "TheDocumentFoundation.LibreOffice",
    "OBSProject.OBSStudio", "GOG.Galaxy", "ElectronicArts.EADesktop", "Ubisoft.Connect",
    "Python.Python.3.13", "Git.Git", "Zoom.Zoom", "Obsidian.Obsidian", "Spotify.Spotify",
    "qBittorrent.qBittorrent", "TimKosse.FileZilla.Client", "Blizzard.BattleNet",
]
ENGINE = ROOT / "build" / "Virtual.app" / "Contents" / "Resources" / "Engine"
# Fehlerdialoge zählen nicht als „läuft“; kleine Fenster sind meist Start-/Update-Fenster.
ERROR_TITLE = re.compile(r"\b(error|fehler|exception|not found|nicht gefunden|winedbg|crash|failed|fatal)\b", re.I)
MAIN_WINDOW_AREA = 640 * 400
MISSING_DLL = re.compile(r"import_dll Library (\S+)|find_forwarded_export .*?forward '([^']+)'")
SILENT = {
    "nullsoft": ["/S"],
    "inno": ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-"],
    "burn": ["/quiet", "/norestart"],
}
SKIP_TYPES = {"msix", "appx", "msstore", "zip", "pwa"}
NOT_MAIN = re.compile(r"uninstall|deinstall|readme|help|website|manual|license|release notes|documentation|\bweb\b", re.I)


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def gh_list(path):
    r = run(["gh", "api", f"repos/microsoft/winget-pkgs/contents/{path}"])
    return json.loads(r.stdout) if r.returncode == 0 else []


def version_key(name):
    return [int(p) if p.isdigit() else -1 for p in re.split(r"[.\-+]", name)]


def manifest(app_id):
    parts = app_id.split(".")
    base = f"manifests/{app_id[0].lower()}/" + "/".join(parts)
    versions = [e["name"] for e in gh_list(base) if e["type"] == "dir" and e["name"][:1].isdigit()]
    if not versions:
        return None, None
    version = max(versions, key=version_key)
    url = f"https://raw.githubusercontent.com/microsoft/winget-pkgs/master/{base}/{version}/{app_id}.installer.yaml"
    with urllib.request.urlopen(url, timeout=30) as f:
        return version, yaml.safe_load(f.read())


def pick_installer(m):
    installers = m.get("Installers", [])
    for arch in ("x64", "x86", "neutral"):
        for inst in installers:
            kind = (inst.get("InstallerType") or m.get("InstallerType") or "").lower()
            if inst.get("Architecture") != arch or kind in SKIP_TYPES:
                continue
            if inst.get("Scope", m.get("Scope", "machine")) not in ("machine", "user"):
                continue
            switches = {**(m.get("InstallerSwitches") or {}), **(inst.get("InstallerSwitches") or {})}
            return inst, kind, switches
    kinds = sorted({(i.get("InstallerType") or m.get("InstallerType") or "?").lower() for i in installers})
    return None, ",".join(kinds), {}


def download(url, sha, dest):
    if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest().lower() == sha.lower():
        return True
    req = urllib.request.Request(url, headers={"User-Agent": "Virtual-compat-test"})
    with urllib.request.urlopen(req, timeout=300) as f, open(dest.with_suffix(".part"), "wb") as out:
        shutil.copyfileobj(f, out)
    dest.with_suffix(".part").rename(dest)
    return hashlib.sha256(dest.read_bytes()).hexdigest().lower() == sha.lower()


def windows(winlist, virtual=None, env=None):
    """On-screen windows of Wine processes: {id: (title, w, h)}."""
    out = {}
    if virtual is not None:
        for line in run([str(virtual), str(winlist)], env=env, timeout=30).stdout.splitlines():
            parts = line.split("|", 4)
            if len(parts) == 5:
                try:
                    out[parts[0] + ":" + parts[1]] = (parts[4], int(parts[2]), int(parts[3]))
                except ValueError:
                    pass
        return out
    for line in run([str(winlist), "wine"]).stdout.splitlines():
        m = re.match(r"(\d+) (\d+) wine \| (.*) \| (\d+) x (\d+) (on|off)$", line)
        if m and m.group(6) == "on" and int(m.group(4)) >= 120 and int(m.group(5)) >= 80:
            out[m.group(1)] = (m.group(3), int(m.group(4)), int(m.group(5)))
    return out


def shortcuts(prefix):
    found = set()
    for base in ("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs",
                 "drive_c/users/Public/Desktop",
                 f"drive_c/users/{os.environ.get('USER', 'Timur')}/AppData/Roaming/Microsoft/Windows/Start Menu/Programs",
                 f"drive_c/users/{os.environ.get('USER', 'Timur')}/Desktop"):
        d = prefix / base
        if d.exists():
            found.update(p for p in d.rglob("*.lnk"))
    return found


def unix_path(prefix, win):
    win = win.strip().strip('"')
    if len(win) < 3 or win[1:3] != ":\\":
        return None
    return prefix / f"drive_{win[0].lower()}" / win[3:].replace("\\", "/")


def registered_apps(prefix):
    """Startprogramme aus Uninstall-Einträgen (wie AppScanner in der App): {Name: Pfad}."""
    found = {}
    for file in ("system.reg", "user.reg"):
        path = prefix / file
        if not path.exists():
            continue
        section, values = "", {}

        def finish():
            if "\\currentversion\\uninstall\\" not in section:
                return
            icon = re.sub(r",-?\d+$", "", values.get("displayicon", "").strip().strip('"'))
            exe = unix_path(prefix, icon) if icon.lower().endswith(".exe") else None
            location = unix_path(prefix, values.get("installlocation", ""))
            if exe is None and location and (location / "Update.exe").exists():
                # Squirrel: Starter neben Update.exe, Name passend zum Anzeigenamen
                key = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
                stubs = [p for p in location.glob("*.exe") if p.name.lower() not in ("update.exe", "squirrel.exe")]
                exe = next((p for p in stubs if key(p.stem) == key(values.get("displayname", ""))),
                           stubs[0] if len(stubs) == 1 else None)
            if exe and exe.exists() and not NOT_MAIN.search(exe.stem):
                found[values.get("displayname") or exe.stem] = exe

        for raw in path.read_text(errors="replace").splitlines():
            line = raw.strip()
            if line.startswith("[") and "]" in line:
                finish()
                section, values = line[1:line.index("]")].replace("\\\\", "\\").lower(), {}
            elif line.startswith('"') and '"="' in line:
                name, _, value = line.partition("=")
                try:
                    values[json.loads(name).lower()] = json.loads(value)
                except ValueError:
                    pass
        finish()
    return found


def uniform(png):
    """True, wenn der Fensterinhalt praktisch einfarbig ist (schwarzes/weißes Fenster)."""
    bmp = png.with_suffix(".bmp")
    if run(["sips", "-s", "format", "bmp", str(png), "--out", str(bmp)]).returncode or not bmp.exists():
        return False
    data = bmp.read_bytes()
    bmp.unlink()
    off = int.from_bytes(data[10:14], "little")
    w, h = int.from_bytes(data[18:22], "little", signed=True), abs(int.from_bytes(data[22:26], "little", signed=True))
    step = int.from_bytes(data[28:30], "little") // 8
    row = (w * step + 3) & ~3
    counts = {}
    # Titelleisten oben (bzw. unten bei Bottom-up-BMPs) auslassen
    for y in range(h // 8, h - h // 8, 4):
        for x in range(0, w, 4):
            i = off + y * row + x * step
            px = bytes(c >> 4 for c in data[i:i + 3])
            counts[px] = counts.get(px, 0) + 1
    total = sum(counts.values())
    # 7-Zip mit leerer Dateiliste liegt bei 99,3 %, ein leeres Electron-Fenster bei 100 %.
    return total > 0 and max(counts.values()) / total > 0.998


def missing_dlls(prefix, *logs):
    """Wirklich fehlende DLLs: nicht ladbare, die es im Raum nicht gibt (DLLs, die nur an
    einer fehlenden Abhängigkeit scheitern, zählen nicht), und Ziele von Weiterleitungen."""
    present = {f.lower() for _, _, files in os.walk(prefix / "drive_c") for f in files if f.lower().endswith(".dll")}
    found = set()
    for log in logs:
        if log.exists():
            for m in MISSING_DLL.finditer(log.read_text(errors="replace")):
                if m.group(1) and m.group(1).lower() not in present:
                    found.add(m.group(1))
                elif m.group(2):
                    found.add(m.group(2).split(".")[0] + ".dll (Weiterleitung)")
    return sorted(found)


def isolate_user_folders(prefix):
    """Keep test installers out of the host's Documents/Downloads directories."""
    users = prefix / "drive_c" / "users"
    if not users.exists():
        return
    for user in users.iterdir():
        if not user.is_dir() or user.is_symlink():
            continue
        for folder in user.iterdir():
            if folder.is_symlink() and not folder.resolve().is_relative_to(prefix):
                folder.unlink()
                folder.mkdir()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("apps", nargs="*")
    ap.add_argument("--out", default=str(ROOT / "logs" / f"compat-{time.strftime('%Y%m%d-%H%M')}"))
    # Standard: die Engine im App-Bundle – genau das, was ausgeliefert wird.
    ap.add_argument("--engine", default=str(ENGINE if ENGINE.exists() else ROOT),
                    help="Ordner mit runtime/ und scripts/ (App-Engine oder Projektordner)")
    ap.add_argument("--winlist", default=str(ROOT / "build" / "winlist"))
    ap.add_argument("--install-timeout", type=int, default=420)
    ap.add_argument("--launch-wait", type=int, default=60, help="Sekunden bis zur Prüfung; Launcher mit kleinem Startfenster bekommen bis zum Dreifachen")
    ap.add_argument("--guest-windows", action="store_true", help="Only query windows inside the isolated Wine instance; no macOS window capture")
    args = ap.parse_args()
    apps = args.apps or DEFAULT_APPS
    out = Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    engine = Path(args.engine).resolve()
    runtime = engine / "runtime"; virtual = runtime / "bin" / "virtual"; server = runtime / "bin" / "virtualserver"
    print(f"==> Engine: {engine}", flush=True)
    cache = ROOT / "thirdparty" / "compat-cache"; cache.mkdir(parents=True, exist_ok=True)
    winlist = Path(args.winlist)
    if args.guest_windows:
        winlist = out / "windows.exe"
        r = run(["x86_64-w64-mingw32-gcc", "-O2", str(ROOT / "winrt/tests/windows.c"), "-o", str(winlist), "-luser32"])
        if r.returncode:
            sys.exit(r.stderr)
        runner = out / "program-runner.exe"
        r = run(["x86_64-w64-mingw32-gcc", "-municode", "-O2", str(ROOT / "app/Helpers/program-runner.c"), "-o", str(runner), "-lole32", "-luuid"])
        if r.returncode:
            sys.exit(r.stderr)
    else:
        runner = None
    if not winlist.exists():
        src = ROOT / "scripts" / "winlist.swift"
        r = run(["swiftc", "-O", "-o", str(winlist), str(src)])
        if r.returncode:
            sys.exit(f"winlist konnte nicht gebaut werden: {r.stderr}")

    # Vorlage: einmal frisch eingerichteter Raum, pro App per APFS-Klon kopiert
    base = out / "base-room" / "prefix"
    if not (base / "drive_c/windows/system32").exists():
        print("==> Lege Vorlagen-Raum an …", flush=True)
        base.parent.mkdir(parents=True, exist_ok=True)
        env = {**os.environ, "WINEPREFIX": str(base), "WINMAC_ROOT": str(ROOT), "WINMAC_RUNTIME": str(runtime),
               "WINMAC_ASSETS_ROOT": str(engine)}
        r = run(["bash", str(engine / "scripts/init-prefix.sh"), "win10"], env=env)
        (out / "base-room.log").write_text(r.stdout + r.stderr)
        if r.returncode:
            sys.exit("Vorlagen-Raum gescheitert, siehe base-room.log")
        run([str(server), "-k"], env=env)
        run([str(server), "-w"], env=env)
    isolate_user_folders(base)
    base_links = {p.relative_to(base) for p in shortcuts(base)}
    base_apps = set(registered_apps(base))

    results = []
    for app in apps:
        res = {"app": app}
        results.append(res)
        print(f"==> {app}", flush=True)
        try:
            version, m = manifest(app)
        except Exception as e:
            res["result"] = f"Manifest-Fehler: {e}"
            continue
        if not m:
            res["result"] = "kein winget-Manifest"
            continue
        res["version"] = version
        inst, kind, switches = pick_installer(m)
        if not inst:
            res["result"] = f"kein passender Installer ({kind})"
            continue
        res["type"] = kind
        url = inst["InstallerUrl"]
        name = re.sub(r"[^A-Za-z0-9._-]", "_", url.split("?")[0].rsplit("/", 1)[-1]) or "installer"
        if kind in ("msi", "wix") and not name.lower().endswith(".msi"):
            name += ".msi"
        if not name.lower().endswith((".exe", ".msi")):
            name += ".exe"
        dl = cache / f"{app}-{version}-{name}"
        try:
            if not download(url, inst["InstallerSha256"], dl):
                res["result"] = "Prüfsumme des Downloads stimmt nicht"
                continue
        except Exception as e:
            res["result"] = f"Download-Fehler: {e}"
            continue

        room = out / "rooms" / app / "prefix"
        if room.parent.exists():
            shutil.rmtree(room.parent)
        room.parent.mkdir(parents=True)
        run(["cp", "-cR", str(base), str(room)])
        env = {**os.environ, "WINEPREFIX": str(room), "WINEDEBUG": "err+all,fixme-all",
               "WINEDLLOVERRIDES": "winedbg.exe=d", "MVK_CONFIG_LOG_LEVEL": "0"}
        log = out / "rooms" / app / "install.log"
        if kind in ("msi", "wix"):
            cmd = [str(virtual), "msiexec", "/i", str(dl), "/qn", "/norestart"]
        else:
            # Ohne Schalter: viele Installer (Squirrel: Discord, Slack …) sind ohnehin still;
            # zeigt einer doch einen Dialog, beendet ihn das Zeitlimit.
            silent = switches.get("Silent") or switches.get("SilentWithProgress")
            sw = shlex.split(silent) if silent else list(SILENT.get(kind, []))
            cmd = [str(virtual), str(dl), *sw]
        cmd += shlex.split(switches.get("Custom", ""))
        if runner is not None:
            cmd.insert(1, str(runner))
        t0 = time.time()
        with open(log, "w") as f:
            try:
                p = subprocess.run(cmd, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=args.install_timeout)
                res["install_exit"] = p.returncode
            except subprocess.TimeoutExpired:
                res["install_exit"] = "Zeitlimit"
        res["install_seconds"] = round(time.time() - t0)
        run([str(server), "-k"], env=env)
        time.sleep(2)

        links = [p for p in shortcuts(room) if p.relative_to(room) not in base_links and not NOT_MAIN.search(p.stem)]
        registered = {k: v for k, v in registered_apps(room).items() if k not in base_apps}
        if links:
            target = sorted(links, key=lambda p: (len(p.parts), len(p.stem)))[0]
        elif registered:
            target = sorted(registered.values(), key=lambda p: len(p.parts))[0]
        else:
            res["status"] = "nicht installiert"
            res["result"] = "installiert? keine Verknüpfung, kein Uninstall-Eintrag"
            res["missing_dlls"] = missing_dlls(room, log)
            continue
        res["shortcut"] = target.stem
        guest = virtual if args.guest_windows else None
        before = windows(winlist, guest, env)
        launch_log = out / "rooms" / app / "launch.log"
        with open(launch_log, "w") as f:
            launch = [str(virtual), "start", "/wait", "/unix", str(target)]
            if runner is not None:
                launch.insert(1, str(runner))
            proc = subprocess.Popen(launch, env=env, stdout=f, stderr=subprocess.STDOUT)
            t0 = time.time()
            seen = {}
            # Bis zur Prüfzeit warten; zeigt sich bis dahin nur ein kleines Start-/Update-Fenster
            # (Steam, Epic, GIMP …), bis zum Dreifachen auf das Hauptfenster warten.
            while time.time() - t0 < args.launch_wait * 3:
                time.sleep(3)
                now = {wid: info for wid, info in windows(winlist, guest, env).items() if wid not in before}
                seen.update(now)
                if time.time() - t0 < args.launch_wait:
                    continue
                if not now or max(w * h for _, w, h in now.values()) >= MAIN_WINDOW_AREA:
                    break
        # Gezählt wird, was am Ende noch offen ist – nicht, was zwischendurch kurz aufging.
        final = {wid: info for wid, info in windows(winlist, guest, env).items() if wid not in before}
        res["seconds"] = round(time.time() - t0)
        shots = []
        for wid, (title, w, h) in sorted(final.items(), key=lambda kv: -kv[1][1] * kv[1][2])[:3]:
            entry = {"title": title, "size": f"{w}x{h}", "file": ""}
            if not args.guest_windows:
                shot = out / "rooms" / app / f"window-{wid}.png"
                if run(["screencapture", "-x", "-o", "-l", wid, str(shot)]).returncode == 0 and shot.exists():
                    entry["file"] = str(shot.relative_to(out))
                    entry["uniform"] = uniform(shot)
            shots.append(entry)
        text = launch_log.read_text(errors="replace")
        crashed = bool(re.search(r"Unhandled (page fault|exception)|wine: Unhandled|unhandled exception", text, re.I))
        res["windows"] = shots
        res["crash"] = crashed
        res["missing_dlls"] = missing_dlls(room, log, launch_log)
        errors = [w["title"] for w in shots if ERROR_TITLE.search(w["title"] or "")]
        main = shots[0] if shots else None
        if crashed:
            res["status"] = "Absturz"
        elif not shots:
            res["status"] = "Fenster wieder zu" if seen else "kein Fenster"
        elif errors:
            res["status"] = f"Fehlerdialog: {errors[0]}"
        elif max(w * h for _, w, h in final.values()) < MAIN_WINDOW_AREA:
            res["status"] = "nur Startfenster"
        elif main.get("uniform"):
            res["status"] = "Fenster einfarbig"
        else:
            res["status"] = "läuft"
        res["result"] = res["status"]
        run([str(server), "-k"], env=env)
        proc.kill()
        time.sleep(2)
        (out / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))

    (out / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    ok = sum(1 for r in results if r.get("status") == "läuft")
    lines = [f"# Kompatibilitätstest {time.strftime('%Y-%m-%d %H:%M')}", "", f"Engine: `{engine}`", "",
             f"{ok} von {len(results)} Apps laufen (Hauptfenster nach {args.launch_wait} s noch offen, kein Fehlerdialog, nicht einfarbig).", "",
             "| App | Version | Installer | Ergebnis | Fenster | Fehlende DLLs |", "|---|---|---|---|---|---|"]
    for r in results:
        wins = ", ".join(f"[{w['title'] or 'ohne Titel'} {w['size']}]({w['file']})" if w['file'] else f"{w['title'] or 'ohne Titel'} {w['size']}" for w in r.get("windows", []))
        lines.append(f"| {r['app']} | {r.get('version', '')} | {r.get('type', '')} | {r.get('result', '')} | {wins} | {', '.join(r.get('missing_dlls', []))} |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    print(f"==> Fertig: {ok}/{len(results)} – {out / 'report.md'}")


if __name__ == "__main__":
    main()
