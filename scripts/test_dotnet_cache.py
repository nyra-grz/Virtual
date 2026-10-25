"""Parallel room setups share the .NET download cache; no network, no Wine.

Run: python3 -m unittest discover -s scripts -p 'test_*.py'
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
ROOMS = 3

# One room: install-dotnet-runtime.py with curl replaced by a slow local download.
INSTALL_ROOM = r'''
import hashlib, importlib.util, json, os, sys, time
spec = importlib.util.spec_from_file_location("installer", sys.argv[1])
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
chunk = b"dotnet" * 1024
def curl(url, destination=None):
    if destination is None:
        asset = {"rid": "win-x64", "name": "dotnet-runtime-8.0.5-win-x64.exe", "url": "https://builds.dotnet.microsoft.com/r.exe",
                 "hash": hashlib.sha512(chunk * 40).hexdigest()}
        return json.dumps({"releases": [{"runtime": {"version": "8.0.5", "files": [asset]}}]}).encode()
    with open(os.environ["DOWNLOADS"], "a") as log:
        log.write(url + "\n")
    with open(destination, "wb") as out:
        for _ in range(40):
            out.write(chunk)
            out.flush()
            time.sleep(0.01)
installer.curl = curl
installer.install("dotnet8-x64")
'''

FAKE_VIRTUAL = '''#!/bin/bash
shasum -a 512 "$1" | cut -d' ' -f1 > "$WINEPREFIX/installed-from"
mkdir -p "$WINEPREFIX/drive_c/Program Files/dotnet/shared/Microsoft.NETCore.App/8.0.5"
'''

FAKE_CURL = '''#!/bin/bash
while [ $# -gt 1 ]; do [ "$1" = -o ] && out="$2"; shift; done
printf '%s\\n' "$1" >> "$DOWNLOADS"
for _ in $(seq 40); do printf 'net48' >> "$out"; sleep 0.01; done
'''


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


class SharedDownloadCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.downloads = self.root / "downloads"

    def tearDown(self):
        self.temp.cleanup()

    def run_rooms(self, command, environment):
        rooms = []
        for index in range(ROOMS):
            prefix = self.root / "rooms" / str(index)
            prefix.mkdir(parents=True)
            env = dict(os.environ, DOWNLOADS=str(self.downloads), WINEPREFIX=str(prefix), **environment)
            rooms.append((prefix, subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)))
        for _, process in rooms:
            out, err = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, out + err)
        return [prefix for prefix, _ in rooms]

    def assert_one_clean_download(self, cache, name):
        self.assertEqual(len(self.downloads.read_text().splitlines()), 1)
        leftovers = [p.name for p in cache.iterdir() if p.name.startswith(name + ".") and p.name != name + ".lock"]
        self.assertEqual(leftovers, [])

    def test_runtime_installer_downloads_once_and_installs_verified_file(self):
        executable(self.root / "runtime/bin/virtual", FAKE_VIRTUAL)
        prefixes = self.run_rooms([sys.executable, "-I", "-c", INSTALL_ROOM, str(SCRIPTS / "install-dotnet-runtime.py")],
                                  {"WINMAC_ROOT": str(self.root), "WINMAC_RUNTIME": str(self.root / "runtime")})
        digest = hashlib.sha512(b"dotnet" * 1024 * 40).hexdigest()
        name = digest[:16] + "-dotnet-runtime-8.0.5-win-x64.exe"
        cache = self.root / "thirdparty/managed/dotnet"
        self.assert_one_clean_download(cache, name)
        for prefix in prefixes:
            self.assertEqual((prefix / "installed-from").read_text().strip(), digest)

    def test_dotnet48_fetch_downloads_once_into_shared_cache(self):
        source = (SCRIPTS / "setup-dotnet48.sh").read_text()
        functions = re.search(r"^checksum_ok\(\).*?^fetch\(\).*?^}\n", source, re.S | re.M).group(0)
        executable(self.root / "bin/curl", FAKE_CURL)
        cache = self.root / "cache"
        cache.mkdir()
        digest = hashlib.sha256(b"net48" * 40).hexdigest()
        script = functions + 'CACHE="$1"\nfetch https://download.microsoft.com/ndp48.exe "$2" ndp48.exe\n'
        self.run_rooms(["/bin/bash", "-c", script, "fetch", str(cache), digest],
                       {"PATH": f"{self.root / 'bin'}:{os.environ.get('PATH', '/usr/bin:/bin')}"})
        self.assert_one_clean_download(cache, "ndp48.exe")
        self.assertEqual(hashlib.sha256((cache / "ndp48.exe").read_bytes()).hexdigest(), digest)


if __name__ == "__main__":
    unittest.main()
