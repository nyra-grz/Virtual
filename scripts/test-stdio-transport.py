#!/usr/bin/env python3
"""Exercise the real GUI runner with host pipes, files, binary data and descendants.

Called by smoke-test.sh in its private prefix. No downloads or persistent rooms.
"""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--wine', required=True)
parser.add_argument('--runner', required=True)
parser.add_argument('--fixture', required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
marker = b'\r\nVIRTUAL_EXIT_CODE=0\r\n'
payload = b''.join(bytes((i + block * 13) & 255 for i in range(16384)) for block in range(64))
errors = bytes(x ^ 0x5a for x in payload)
for mode in ('pipe', 'file', 'payload', 'orphan', 'input'):
    command = [args.wine, args.runner, args.fixture, mode]
    if mode == 'file':
        stdout_file = args.scratch / 'stdio-file.out'
        stderr_file = args.scratch / 'stdio-file.err'
        with stdout_file.open('wb') as out, stderr_file.open('wb') as err:
            run = subprocess.run(command, stdout=out, stderr=err, timeout=30)
        stdout, stderr = stdout_file.read_bytes(), stderr_file.read_bytes()
    else:
        run = subprocess.run(command, input=b'input remains available\n', capture_output=True, timeout=30)
        stdout, stderr = run.stdout, run.stderr
    (args.scratch / f'stdio-{mode}.out').write_bytes(stdout)
    (args.scratch / f'stdio-{mode}.err').write_bytes(stderr)
    expected = payload if mode in ('payload', 'orphan') else (
        b'input remains available\n' if mode == 'input' else b'STDIO_CONTRACTS_OK\n')
    expected_stderr = errors if mode in ('payload', 'orphan') else b''
    if run.returncode != 0 or stdout != expected + marker or stderr != expected_stderr:
        raise SystemExit(f'{mode}: exit={run.returncode}; stdout {len(stdout)} bytes, stderr {len(stderr)} bytes; content mismatch')
    print(f'{mode}: exact bytes and exit status verified', flush=True)

# A closed log consumer must fail promptly and unblock the producer. Keeping
# the relay's read end open after a sink error deadlocks a large child write.
for stream, expected_code in (('stdout', 20), ('stderr', 21)):
    reader, writer = os.pipe()
    os.close(reader)
    try:
        options = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        options[stream] = writer
        run = subprocess.run([args.wine, args.runner, args.fixture, 'payload'], timeout=30, **options)
    finally:
        os.close(writer)
    if run.returncode != expected_code:
        raise SystemExit(f'closed {stream}: exit={run.returncode}, expected {expected_code}')
    if stream == 'stderr' and f'VIRTUAL_EXIT_CODE={expected_code}'.encode() not in run.stdout:
        raise SystemExit('closed stderr: missing Windows result')
    print(f'closed {stream}: producer unblocked and failure preserved', flush=True)
