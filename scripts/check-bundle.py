#!/usr/bin/env python3
"""Verify the exact shippable bundle, then bind its content to the core results.

Usage: scripts/check-bundle.py build/Virtual.app [--receipt PATH]
This does not publish, migrate rooms or change the bundle. A receipt is written
only after all checks pass and the bundle's content remains identical.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = (
    'Contents/MacOS/Virtual', 'Contents/Info.plist',
    'Contents/Resources/program-runner.exe', 'Contents/Resources/certimport.exe',
    'Contents/Resources/Engine/engine-version',
    'Contents/Resources/Engine/support/components.lock.json',
    'Contents/Resources/Engine/scripts/init-prefix.sh',
    'Contents/Resources/Engine/runtime/bin/virtual',
    'Contents/Resources/Engine/runtime/wine-build/bin/wine',
)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while block := f.read(1024 * 1024):
            h.update(block)
    return h.hexdigest()


def inventory(bundle):
    """Hash bytes, link targets and execute bits; reject nonportable links."""
    bundle = bundle.resolve()
    entries = []
    for path in sorted(bundle.rglob('*')):
        mode = path.lstat().st_mode
        name = path.relative_to(bundle).as_posix()
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(bundle):
                raise ValueError(f'Link verlässt das Bundle: {name}')
            if not path.exists():
                raise ValueError(f'Linkziel fehlt: {name}')
            entries.append([name, 'link', target])
        elif stat.S_ISREG(mode):
            entries.append([name, 'file', mode & 0o111, digest(path)])
        elif not stat.S_ISDIR(mode):
            raise ValueError(f'Nicht auslieferbarer Dateityp: {name}')
    encoded = json.dumps(entries, ensure_ascii=False, separators=(',', ':')).encode()
    return hashlib.sha256(encoded).hexdigest(), entries


def require_bundle(bundle):
    for relative in REQUIRED:
        if not (bundle / relative).is_file():
            raise ValueError(f'Unvollständiges Bundle: {relative}')
    for relative in ('Contents/MacOS/Virtual', 'Contents/Resources/Engine/runtime/bin/virtual',
                     'Contents/Resources/Engine/runtime/wine-build/bin/wine'):
        if not os.access(bundle / relative, os.X_OK):
            raise ValueError(f'Nicht ausführbar: {relative}')
    with (bundle / 'Contents/Info.plist').open('rb') as f:
        return plistlib.load(f)


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args]).decode().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    receipt = (args.receipt or bundle.with_suffix('.verified.json')).resolve()
    if receipt.is_relative_to(bundle):
        parser.error('Prüfnachweis muss außerhalb des signierten Bundles liegen.')
    receipt.parent.mkdir(parents=True, exist_ok=True)
    # A failed retry must never leave a stale successful receipt at this path.
    receipt.unlink(missing_ok=True)
    info = require_bundle(bundle)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    before, entries = inventory(bundle)
    revision = git('rev-parse', 'HEAD')
    diff = git('diff', '--binary', 'HEAD')
    status = git('status', '--porcelain')
    engine = bundle / 'Contents/Resources/Engine'
    env = dict(os.environ, WINMAC_HOME=str(engine), WINMAC_SMOKE_BUNDLE=str(bundle),
               WINMAC_SMOKE_SKIP_BUILD='1', WINMAC_SMOKE_STRICT='1')
    log = receipt.with_suffix('.log')
    print(f'==> Prüfe ausgeliefertes Bundle: {bundle}', flush=True)
    with log.open('w') as output:
        process = subprocess.Popen(['/bin/bash', str(ROOT / 'scripts/check-core.sh')],
                                   cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            output.write(line)
            print(line, end='', flush=True)
        if process.wait():
            raise ValueError(f'Kerntests fehlgeschlagen. Protokoll: {log}')
    if inventory(bundle)[0] != before:
        raise ValueError('Bundle wurde während der Prüfung geändert.')
    if git('rev-parse', 'HEAD') != revision or git('diff', '--binary', 'HEAD') != diff or git('status', '--porcelain') != status:
        raise ValueError('Quellstand wurde während der Prüfung geändert.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    result = dict(checked_at=datetime.now(timezone.utc).isoformat(), bundle=str(bundle),
                  source_commit=revision, source_status=status,
                  source_diff_sha256=hashlib.sha256(diff.encode()).hexdigest(),
                  version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                  bundle_sha256=before, files=entries,
                  engine_identity=(engine/'engine-version').read_text().strip(),
                  core_log_sha256=digest(log), core_gate='passed; no skipped runtime checks',
                  app_workflows='not certified by this core gate')
    temporary = receipt.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(receipt)
    print(f'==> Prüfnachweis: {receipt}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
