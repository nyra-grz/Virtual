# Review and smoke test

Date: 23 October 2026. Reviewed was the worktree `~/WinMac_Virtual-codex`,
branch `codex/smoke-test`, based on commit `ca0b0c8`
(`setup-graphics.sh: robustere MoltenVK-Prüfung, nur echte DXVK-DLLs`).
Parallel changes in the main checkout are not part of this review.

Scope read: `setup-graphics.sh`, `build-app.sh`, both existing `scripts/*.sh` and
all eight files in `app/Sources/WinMacVirtual/`. `build-wine.sh` was not read or
assessed. The reviewed files were not changed. The only new files are
`scripts/smoke-test.sh` and this document; the requested app build additionally
creates ignored build artifacts in the worktree.

## Confirmed findings

### 1. [P1] Prefix setup reports success despite a failed initialisation

**Locations:** `scripts/init-prefix.sh:20`, `scripts/init-prefix.sh:26`,
`scripts/init-prefix.sh:28`, `scripts/init-prefix.sh:51`;
consequence in `app/Sources/WinMacVirtual/PrefixSetup.swift:49`.

Errors from `virtualboot`, from all registry writes and from the optional
installer are discarded with `|| true`. The final successful `echo` determines the
exit code. The app interprets it as a successful setup and sets
`didInitPrefix = true`.

**Failure scenario:** the runtime wrapper exists and is executable, but its Wine
target cannot start, or the prefix is not writable. The user still gets
"Einrichtung abgeschlossen" (setup complete), although the intended Windows
configuration is missing.

**Evidence:** the unchanged `init-prefix.sh` was run with an isolated fake
runtime: `virtualboot` returned 42, `virtual` returned 1 for every registry access,
`virtualserver` returned 0. The script returned **exit code 0** and
`==> Einrichtung abgeschlossen.`. No real prefix was used.

**Suggestion:** collect critical errors or abort immediately with an error status;
read back the essential registry values. Report optional installer errors
separately. Only set `didInitPrefix` after verified success.

### 2. [P2] Failed program launches leak open file descriptors

**Locations:** `app/Sources/WinMacVirtual/Launcher.swift:41`,
`app/Sources/WinMacVirtual/Launcher.swift:60`,
`app/Sources/WinMacVirtual/Launcher.swift:83`.

The log file and pipe are opened before `process.run()`; the readability handler
holds on to the log file. If `run()` throws, the termination handler is never
called. This error path is missing the removal of the readability handler and the
closing of the file and pipe handles.

**Failure scenario:** an executable file that cannot be started because of an
invalid format is chosen as the runtime in the settings. Every new launch attempt
consumes more descriptors. After enough repetitions the app, or its next launches,
can no longer open files or pipes.

**Evidence:** the unchanged `Launcher.swift` was compiled with isolated
`Settings`/`Program` stubs. The fake runtime marked as executable had no valid
program format. With 30 expected launch errors the number of entries in `/dev/fd`
rose from **4 to 94**; they stayed open even after the run loop was processed.
No app settings were changed.

**Suggestion:** handle the `run()` error path with `do/catch` or a cleanup that is
active until the launch succeeds: remove the handler, close all handles opened by
the launcher, then rethrow the original error.

### 3. [P2] Program exit cuts off the last log output

**Locations:** `app/Sources/WinMacVirtual/Launcher.swift:60`,
`app/Sources/WinMacVirtual/Launcher.swift:72`–`76`.

Process termination and reading the pipe completely are two different events. The
termination handler disables the reader and closes the log file immediately,
without waiting for EOF or for the pipe processing still pending. Bytes the
program has already written can therefore remain in the pipe buffer. The reader
and the termination handler also use the same log handle without shared
serialisation.

**Failure scenario:** an installer or console program writes the actual error
message right before it exits. The log contains the exit status, but the crucial
last message is missing.

**Evidence:** the unchanged `Launcher.swift` was run with isolated stubs and 40
short-lived native test processes. Each process wrote 131072 bytes followed by
`END-OF-PROGRAM`. 40 logs were created; **3 logs** were missing the end marker.
No crash was observed in this test.

**Suggestion:** read the pipe until EOF and write the output on a serial queue.
Only write the footer, close the log and report the launch as finished once both
process termination and reader EOF have happened.

### 4. [P1] MSI files offered as supported documents are started like EXEs

**Locations:** `app/Sources/WinMacVirtual/Launcher.swift:47`–`48`;
MSI files accepted in `app/Sources/WinMacVirtual/Library.swift:73`–`74`
and registered in `build-app.sh:53`.

Regardless of the file type, the launcher uses the argument list
`[program.path]`. An MSI database is thus passed directly to the Wine program
loader. There is no call to `msiexec` and no shell-open call.

**Failure scenario:** a valid `.msi` is opened from Finder or started from the
library. Instead of the installer, Wine tries to load the database as an
executable program; the installation does not start.

**Evidence:** the complete argument construction is visible in the lines above.
The [Wine loader](https://github.com/wine-mirror/wine/blob/master/tools/wine/wine.man.in)
loads executable DOS/Windows files; for MSI packages
[`msiexec /i <package>`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/msiexec)
is the installation call. This is a finding from the code path, not an MSI
installation test run here.

**Suggestion:** for `.msi`, use an argument list for `msiexec /i` and convert the
Unix path correctly to a Windows path, or alternatively open it through
`start /unix`. Keep passing arguments individually via `Process.arguments`, not
as a combined shell string.

### 5. [P2] Unbounded wait for the whole prefix server blocks setup

**Locations:** `scripts/init-prefix.sh:23`, `scripts/init-prefix.sh:50`,
`setup-graphics.sh:53`, `setup-graphics.sh:159`.

`virtualserver -w` waits for the entire wineserver of the prefix to exit, not just
for the registry change made before. The calls have neither a time limit nor a
check whether other Windows applications are running.

**Failure scenario:** while a game or editor is running in the same prefix,
"Windows-Umgebung jetzt einrichten" (set up Windows environment now) or the
graphics setup is started. As long as the other application keeps the server
alive, the setup does not return. At `init-prefix.sh:23` it does not even reach
the registry configuration; the app's setup button stays disabled.

**Evidence:** the unconditional calls are in the lines above. The
[wineserver documentation](https://github.com/wine-mirror/wine/blob/master/server/wineserver.man.in)
defines `-w` as waiting for the server to exit and assigns the instance via
`WINEPREFIX`. No unrelated, running user program was started or stopped to
demonstrate this.

**Suggestion:** remove unnecessary global waits after synchronous registry
commands. For the first initialisation use a bounded wait if needed and report a
busy prefix clearly. Do not terminate all user programs with a global `-k`
without asking.

### 6. [P2] Graphics rollback does not remove newly added DLLs

**Locations:** `setup-graphics.sh:48`–`50`, `setup-graphics.sh:103`–`105`,
`setup-graphics.sh:119`–`123`.

Only DLLs that already exist before installation are backed up. The installation
also copies DLLs for which no original existed. `--off` only restores existing
backups and removes registry overrides; the additionally installed files remain.

**Failure scenario:** the Wine runtime in use does not have a
`system32/d3d12core.dll` yet; the optional VKD3D package brings this file. After
`--off` the native VKD3D DLL is still in the search path and can still be loaded.
The announced original state was not restored.

**Evidence:** the unchanged functions `set_override` and `disable_graphics` were
taken from the script and run in a temporary test environment with fake registry
commands. An installed `d3d12core.dll` without a backup was still present
afterwards, while the function returned exit code 0 and
`Erledigt. Wine rendert wieder selbst.` (done, Wine renders by itself again).

**Suggestion:** keep an installation manifest per architecture that also stores
the state "did not exist originally". On rollback, restore originals and delete
only the DLLs that were demonstrably added by the setup.

## New smoke test

Call from the worktree itself:

```sh
WINMAC_HOME="$HOME/WinMac_Virtual" ./scripts/smoke-test.sh
```

The script builds the app in **its own checkout**; runtime and DXVK are only read
from `WINMAC_HOME`. The real `prefix/` is not used. A working folder created with
`mktemp -d` contains all test EXEs, logs, DXVK copies and the new prefix.
Temporary runtime wrappers limit every Wine call, including the calls inside
`init-prefix.sh`, to 60 seconds using a Perl alarm. They also log errors that the
existing init script swallows. `WINEPREFIX` is explicitly exported before the
first Wine call; `winedbg.exe`, `mscoree` and `mshtml` are disabled. A .NET
installer that happens to be in Downloads is not run.

The console programs check their actual pointer width, `printf` output and the
propagation of exit code **37**. For D3D11 only a hardware device is requested.
If DXVK is present, exactly its x64 DLLs `d3d11.dll` and `d3d10core.dll` are
copied into the throwaway prefix, loaded natively for this call only, and at least
feature level 11.0 is required. Possible DLL symlinks are removed in the throwaway
prefix before copying, so that no shared runtime file is overwritten. Without
DXVK, hardware device creation through WineD3D is still checked.

The EXIT trap calls `virtualserver -k` and then the likewise bounded wait for
exactly this prefix, deletes the temporary folder and prints the summary. Any
error, including during cleanup, results in exit code 1. Missing optional
compilers are reported as "übersprungen" (skipped) with a reason; a missing
runtime is an error. `setup-graphics.sh` is never run.

Pre-check: `bash -n scripts/smoke-test.sh` succeeded.
The review reproductions described above only created temporary files and did not
change any of the reviewed sources.

## Full smoke test run

Output of the final full run with the runtime from the main checkout, including
cleanup and summary. The script prints German status words: `ok`, `FEHLER`
(error), `übersprungen` (skipped). The GPU details printed by MoltenVK are
shortened.

```text
WinMac Virtual – Smoke-Test
Quellprojekt: ~/WinMac_Virtual-codex
WINMAC_HOME: ~/WinMac_Virtual

ok: App-Build – ~/WinMac_Virtual-codex/build/WinMac Virtual.app
ok: Info.plist – CFBundleDocumentTypes enthält exe und msi
ok: Runtime --version
    wine-11.18 (Staging)
ok: Wegwerf-Prefix einrichten – init-prefix.sh win10
ok: Registry ProductName – Windows 10 Pro
ok: 64-Bit-Konsole kompilieren
    console-64.exe: PE32+ executable (console) x86-64, for MS Windows
ok: 64-Bit-Konsole ausführen – WINMAC_SMOKE_BITS=64; Exitcode 37
ok: 32-Bit-Konsole kompilieren
    console-32.exe: PE32 executable (console) Intel 80386, for MS Windows
ok: 32-Bit-Konsole ausführen – WINMAC_SMOKE_BITS=32; Exitcode 37
ok: D3D11-Test kompilieren
ok: DXVK im Wegwerf-Prefix – ~/WinMac_Virtual/thirdparty/graphics/dxvk/dxvk-macOS-async-v1.10.3-20230507-repack/x64; Mindest-Feature-Level 11.0
ok: D3D11-Hardware-Gerät
    [mvk-info] Created VkDevice to run on GPU Apple M5 Pro with the following 16 Vulkan extensions enabled: …
    D3D11 Hardware: Feature-Level 11.0 (0xb000)
ok: Wegwerf-Prefix: virtualserver beendet
ok: Temporäre Dateien und Wegwerf-Prefix gelöscht

Zusammenfassung: 14 ok, 0 FEHLER, 0 übersprungen.

Smoke-Test-Exitcode: 0
```

## Addendum: fixes (23 October 2026)

All six findings are fixed; afterwards `./build-app.sh` builds without new warnings
and the smoke test reports 14 ok / 0 errors. Deviations from the review:

- **Finding 4** cannot be reproduced with wine-11.18: Wine hands non-EXE files to
  the file association internally; `virtual package.msi` installed the Wine Gecko
  MSI in the throwaway prefix just like `msiexec /i` and returned the same error
  code for a broken MSI. The launcher still calls `msiexec /i <Windows path>`
  explicitly, so it does not depend on this fallback.
- **Finding 5**: the first hang in `init-prefix.sh` was not `virtualserver -w`
  but the pipe `virtualboot -i | sed`. In a busy prefix wineboot starts additional
  `services.exe`/`winedevice.exe` processes that inherit the pipe and keep it open.
  Wine output therefore now goes through a file; waiting for the server is limited
  to 30 s.
- **Finding 1**: reading the registry back compares value names case-insensitively,
  because Wine already has e.g. `EditionId` and `reg add /v EditionID` keeps that
  spelling.
- **Finding 6**: `setup-graphics.sh` wrote through DLL symlinks into the runtime
  during installation; the target file is now removed before every copy.
- In addition to finding 2: every *successful* launch also leaked a descriptor
  (40 launches: 4 → 44 open FDs). The read channel is now always closed.

The app has since been renamed from "WinMac Virtual" to **Virtual**.
