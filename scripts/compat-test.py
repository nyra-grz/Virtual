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
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
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
    "qBittorrent.qBittorrent", "Blizzard.BattleNet",
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


def pid_in_room(pid, room):
    """Gehört der Prozess zu diesem Raum? Wine-Prozesse arbeiten in ihrem drive_c bzw. halten
    Dateien darin offen (bei parallelen Tests laufen mehrere Räume gleichzeitig)."""
    paths = run(["lsof", "-a", "-p", pid, "-d", "cwd,txt,0-64", "-Fn"]).stdout
    return any(line[1:].startswith(str(room) + "/") for line in paths.splitlines() if line.startswith("n/"))


def windows(winlist, virtual=None, env=None, room=None):
    """On-screen windows of Wine processes: {id: (title, w, h)}; with room only that room's."""
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
    owners = {}
    for line in run([str(winlist), "wine"]).stdout.splitlines():
        m = re.match(r"(\d+) (\d+) wine \| (.*) \| (\d+) x (\d+) (on|off)$", line)
        if m and m.group(6) == "on" and int(m.group(4)) >= 120 and int(m.group(5)) >= 80:
            if room is not None and m.group(2) not in owners:
                owners[m.group(2)] = pid_in_room(m.group(2), room)
            if room is None or owners[m.group(2)]:
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


STUB = re.compile(r"fixme:(\w+):(\w+) .*?\b(stub|not implemented|semi-stub)", re.I)
CRASH = re.compile(r"Unhandled (page fault on \w+ access to [0-9A-Fa-f]+|exception [0-9a-fx]+) at address ([0-9A-Fa-f]+)")
UNIMPLEMENTED = re.compile(r"wine: Call from \S+ to unimplemented function ([^\s,]+), aborting", re.I)


def cause(res, *logs):
    """Kurze Ursache für die Triage: wo es abstürzt, was fehlt, welche Wine-Stubs zuletzt
    aufgerufen wurden. Gleiche Ursachen bei vielen Apps sind die lohnendsten Fixes."""
    text = "\n".join(log.read_text(errors="replace") for log in logs if log.exists())
    stubs = []
    crash = CRASH.search(text)
    for m in STUB.finditer(text[:crash.start()] if crash else text):
        name = f"{m.group(1)}:{m.group(2)}"
        if name in stubs:
            stubs.remove(name)
        stubs.append(name)
    res["last_stubs"] = stubs[-6:]
    status = res.get("status", "")
    unimplemented = UNIMPLEMENTED.search(text)
    if unimplemented:
        res["unimplemented_function"] = unimplemented.group(1)
        return "nicht implementiert: " + unimplemented.group(1)
    if crash:
        # +loaddll provides bases, not image bounds, and the default log prefix
        # is a thread ID rather than a process ID. The nearest lower base may
        # belong to another process (or another image), so it proves no module.
        res["crash_in"] = crash.group(2)
        return "Absturz (Modul unbekannt)"
    if res.get("missing_dlls"):
        return "fehlt: " + ", ".join(res["missing_dlls"])
    titles = " ".join(w.get("title") or "" for w in res.get("windows", []))
    if "gecko" in titles.lower():
        return "braucht Wine Gecko (IE/HTML-Engine)"
    if status == "nicht installiert":
        return f"Installer endet mit {res.get('install_exit')}"
    if status.startswith("Fehlerdialog"):
        return status
    if status == "Fenster einfarbig":
        return "leeres Fenster (Rendering)"
    if status == "Fenster offen (Darstellung ungeprüft)":
        return "Darstellung nicht geprüft (keine Fensteraufnahme)"
    if status in ("kein Fenster", "Fenster wieder zu", "nur Startfenster"):
        return status + (f" nach Stub {stubs[-1]}" if stubs else "")
    return ""


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


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("muss größer als null sein")
    return number


def stop_room(server, env):
    """Bounded shutdown of this prefix only, including detached installer children."""
    try:
        run([str(server), "-k"], env=env, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        pass
    # A completed wait proves shutdown even if the server exited before -k.
    try:
        return run([str(server), "-w"], env=env, timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False



def write_results(path, results, lock, completed=None):
    # A reader sees either the previous complete snapshot or the new one. The
    # lock also prevents parallel workers from sharing the temporary filename.
    with lock:
        if completed is not None:
            index, result = completed
            results[index] = result.copy()
        snapshot = json.dumps(results, indent=2, ensure_ascii=False)
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(snapshot)
        temporary.replace(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("apps", nargs="*")
    ap.add_argument("--list", help="Datei mit winget-IDs (eine pro Zeile, # leitet Kommentare ein)")
    ap.add_argument("--jobs", type=positive_int, default=1, help="so viele Apps gleichzeitig testen (eigene Räume)")
    ap.add_argument("--out", default=str(ROOT / "logs" / f"compat-{time.strftime('%Y%m%d-%H%M')}"))
    # Standard: die Engine im App-Bundle – genau das, was ausgeliefert wird.
    ap.add_argument("--engine", default=str(ENGINE if ENGINE.exists() else ROOT),
                    help="Ordner mit runtime/ und scripts/ (App-Engine oder Projektordner)")
    ap.add_argument("--winlist", default=str(ROOT / "build" / "winlist"))
    ap.add_argument("--install-timeout", type=positive_int, default=420)
    ap.add_argument("--launch-wait", type=positive_int, default=60, help="Sekunden bis zur Prüfung; Launcher mit kleinem Startfenster bekommen bis zum Dreifachen")
    ap.add_argument("--keep-rooms", action="store_true", help="auch Räume laufender Apps behalten (sonst nur gescheiterte)")
    ap.add_argument("--guest-windows", action="store_true", help="Only query windows inside the isolated Wine instance; no macOS window capture")
    args = ap.parse_args()
    apps = list(args.apps)
    if args.list:
        apps += [line.split("#")[0].strip() for line in Path(args.list).read_text().splitlines() if line.split("#")[0].strip()]
    apps = list(dict.fromkeys(apps or DEFAULT_APPS))
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
    env = {**os.environ, "WINEPREFIX": str(base), "WINMAC_ROOT": str(ROOT), "WINMAC_RUNTIME": str(runtime),
           "WINMAC_ASSETS_ROOT": str(engine)}
    if not (base / "drive_c/windows/system32").exists():
        print("==> Lege Vorlagen-Raum an …", flush=True)
        base.parent.mkdir(parents=True, exist_ok=True)
        r = run(["bash", str(engine / "scripts/init-prefix.sh"), "win10"], env=env)
        (out / "base-room.log").write_text(r.stdout + r.stderr)
        if r.returncode:
            sys.exit("Vorlagen-Raum gescheitert, siehe base-room.log")
    if not stop_room(server, env):
        sys.exit("Vorlagen-Raum konnte nicht beendet werden")
    isolate_user_folders(base)
    base_links = {p.relative_to(base) for p in shortcuts(base)}
    base_apps = set(registered_apps(base))

    def test_app(app, res):
        try:
            version, m = manifest(app)
        except Exception as e:
            res["result"] = f"Manifest-Fehler: {e}"
            return
        if not m:
            res["result"] = "kein winget-Manifest"
            return
        res["version"] = version
        inst, kind, switches = pick_installer(m)
        if not inst:
            res["result"] = f"kein passender Installer ({kind})"
            return
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
                return
        except Exception as e:
            res["result"] = f"Download-Fehler: {e}"
            return

        room = out / "rooms" / app / "prefix"
        env = {**os.environ, "WINEPREFIX": str(room), "WINEDEBUG": "err+all,fixme+all,+loaddll",
               "WINEDLLOVERRIDES": "winedbg.exe=d", "MVK_CONFIG_LOG_LEVEL": "0"}
        proc = None
        try:
            if room.parent.exists():
                shutil.rmtree(room.parent)
            room.parent.mkdir(parents=True)
            copied = run(["cp", "-cR", str(base), str(room)])
            if copied.returncode:
                raise RuntimeError(f"Raum konnte nicht geklont werden: {copied.stderr.strip()}")
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
            if not stop_room(server, env):
                raise RuntimeError("Installer-Prozesse im Testraum konnten nicht beendet werden")

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
                res["cause"] = cause(res, log)
                return
            res["shortcut"] = target.stem
            guest = virtual if args.guest_windows else None
            before = windows(winlist, guest, env, room)
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
                    now = {wid: info for wid, info in windows(winlist, guest, env, room).items() if wid not in before}
                    seen.update(now)
                    if time.time() - t0 < args.launch_wait:
                        continue
                    if not now or max(w * h for _, w, h in now.values()) >= MAIN_WINDOW_AREA:
                        break
            # Gezählt wird, was am Ende noch offen ist – nicht, was zwischendurch kurz aufging.
            final = {wid: info for wid, info in windows(winlist, guest, env, room).items() if wid not in before}
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
            crashed = bool(UNIMPLEMENTED.search(text) or re.search(r"Unhandled (page fault|exception)|wine: Unhandled|unhandled exception", text, re.I))
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
            elif "uniform" not in main:
                res["status"] = "Fenster offen (Darstellung ungeprüft)"
            else:
                res["status"] = "läuft"
            res["result"] = res["status"]
            if res["status"] != "läuft":
                res["cause"] = cause(res, launch_log)
        finally:
            if not stop_room(server, env):
                res["cleanup_error"] = "Testraum wurde nicht vollständig beendet"
            if proc is not None:
                try:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    res["cleanup_error"] = "Startprozess wurde nicht vollständig beendet"
            if res.get("cleanup_error"):
                res["status"] = res["result"] = "Testfehler: " + res["cleanup_error"]



    results = [{"app": app} for app in apps]
    results_lock = Lock()

    def guarded(index):
        # Active workers own their mutable dictionaries. Published snapshots
        # contain completed copies only, never dictionaries another worker edits.
        res = {"app": apps[index]}
        print(f"==> {res['app']}", flush=True)
        try:
            test_app(res["app"], res)
        except Exception as e:  # ein kaputter Fall soll den Lauf nicht beenden
            res["status"] = res["result"] = f"Testfehler: {e}"
        # Installierte Apps brauchen viel Platz; nur gescheiterte Räume bleiben zur Fehlersuche.
        room = out / "rooms" / res["app"] / "prefix"
        if res.get("status") == "läuft" and not args.keep_rooms and room.exists():
            shutil.rmtree(room, ignore_errors=True)
        write_results(out / "results.json", results, results_lock, (index, res))
        print(f"    {res['app']}: {res.get('status') or res.get('result')}", flush=True)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(guarded, range(len(apps))))

    write_results(out / "results.json", results, results_lock)
    ok = sum(1 for r in results if r.get("status") == "läuft")
    lines = [f"# Kompatibilitätstest {time.strftime('%Y-%m-%d %H:%M')}", "", f"Engine: `{engine}`", "",
             f"{ok} von {len(results)} Apps bestehen die Fensterprüfung (Hauptfenster nach {args.launch_wait} s noch offen, kein Fehlerdialog, Aufnahme nicht einfarbig).", "",
             "Ohne erfolgreiche Fensteraufnahme bleibt die Darstellung ungeprüft; diese Fälle zählen nicht als bestanden. Die Prüfung belegt keine vollständige App-Funktion.", "",
             "| App | Version | Installer | Ergebnis | Ursache | Fenster | Fehlende DLLs |", "|---|---|---|---|---|---|---|"]
    for r in results:
        wins = ", ".join(f"[{w['title'] or 'ohne Titel'} {w['size']}]({w['file']})" if w['file'] else f"{w['title'] or 'ohne Titel'} {w['size']}" for w in r.get("windows", []))
        lines.append(f"| {r['app']} | {r.get('version', '')} | {r.get('type', '')} | {r.get('result', '')} | {r.get('cause', '')} | {wins} | {', '.join(r.get('missing_dlls', []))} |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    # Für die Triage: Fehlschläge nach Ursache, Stubs nach Häufigkeit bei gescheiterten Apps
    groups, stub_hits = {}, {}
    for r in results:
        if r.get("status") == "läuft":
            continue
        groups.setdefault(r.get("cause") or r.get("result") or "?", []).append(r["app"])
        for stub in r.get("last_stubs", []):
            stub_hits.setdefault(stub, []).append(r["app"])
    causes = [f"# Ursachen {time.strftime('%Y-%m-%d %H:%M')}", "", f"{len(results) - ok} von {len(results)} Apps bestehen die Fensterprüfung nicht.", "",
              "| Ursache | Apps | Anzahl |", "|---|---|---|"]
    for c, names in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        causes.append(f"| {c} | {', '.join(names)} | {len(names)} |")
    causes += ["", "## Zuletzt aufgerufene Wine-Stubs bei gescheiterten Apps", "", "| Stub | Apps | Anzahl |", "|---|---|---|"]
    for stub, names in sorted(stub_hits.items(), key=lambda kv: -len(kv[1]))[:40]:
        causes.append(f"| {stub} | {', '.join(names)} | {len(names)} |")
    (out / "causes.md").write_text("\n".join(causes) + "\n")
    print(f"==> Fertig: {ok}/{len(results)} – {out / 'report.md'}")


if __name__ == "__main__":
    main()
