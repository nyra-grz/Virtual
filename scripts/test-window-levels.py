#!/usr/bin/env python3
"""Compile the exact native driver policy from its versioned source patch.

The test operates on values from AppKit, without creating/controlling windows.
Build verification separately checks reconstructed source against compiled source.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--header', type=Path, help='Use an actual prepared-source header')
args = parser.parse_args()
if args.header:
    header = args.header.read_text()
else:
    patch = (ROOT / 'patches/crossover/0033-Virtual-0034-native-window-levels.patch').read_text()
    marker = '+++ b/dlls/winemac.drv/virtual_window_levels.h\n'
    added = patch.split(marker, 1)[1]
    lines = []
    for line in added.splitlines():
        if line.startswith(('--- ', 'diff --git ')):
            break
        if line.startswith('+') and not line.startswith('+++'):
            lines.append(line[1:])
    header = '\n'.join(lines) + '\n'
    if 'virtual_window_level(' not in header:
        raise SystemExit('Native source policy missing from patch.')
with tempfile.TemporaryDirectory(prefix='virtual-window-levels-') as scratch:
    work = Path(scratch)
    (work / 'virtual_window_levels.h').write_text(header)
    binary = work / 'window-levels'
    subprocess.run(['clang', '-arch', 'x86_64', '-mmacosx-version-min=12.0',
                    '-Wall', '-Wextra', '-Werror', '-I', str(work),
                    str(ROOT / 'winrt/tests/mac_window_levels.m'),
                    '-framework', 'AppKit', '-framework', 'CoreGraphics',
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
