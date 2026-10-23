# Virtual

A renamed Wine distribution for macOS (Apple Silicon) called **Virtual**, plus a
native **launcher app** written in Swift/AppKit. Start Windows programs with a
click, a double-click in Finder, or drag and drop.

The app's interface is currently in German; menu items are quoted below with an
English translation.

> Legal: Wine is licensed under the LGPL-2.1+. Forking, renaming and redistributing
> it is allowed as long as the copyright and license notices are kept and changes
> to the code are published (see `patches/`, `LICENSE-Wine.md`). The name "Wine"
> is not used to label the origin of this distribution, hence the `virtual*`
> command names.

## Overview

```
~/WinMac_Virtual/        (project folder)
├── app/                 native launcher app (SwiftPM, AppKit)
├── build-app.sh         builds "build/Virtual.app"
├── build-wine.sh        reproducible Wine source build → runtime/wine-build
├── setup-graphics.sh    MoltenVK + DXVK + VKD3D for the prefix
├── scripts/
│   ├── make-runtime-from-brew.sh   quick runtime from an existing Wine install
│   ├── init-prefix.sh              create the Windows environment (Win10/19045, .NET)
│   ├── smoke-test.sh               end-to-end check in a throwaway prefix
│   └── release.sh                  publish a new version as a GitHub release (for the updater)
├── VERSION              app version number
├── patches/             own Wine changes (+ honest notes on the renaming)
├── winrt/               WinRT networking and devices: documentation and tests
├── runtime/             generated: virtual* commands (not committed)
├── prefix/              Windows environment / WINEPREFIX (not committed)
└── logs/                launch logs (not committed)
```

## Quick start (works right away, no source build)

The project folder must be `~/WinMac_Virtual` – the app looks for scripts,
runtime and prefix there.

```bash
git clone https://github.com/nyra-grz/Virtual.git ~/WinMac_Virtual
cd ~/WinMac_Virtual

# 1) Create the runtime from an existing Wine installation
#    (finds "Wine Staging.app" in ~/Downloads or brew wine@staging automatically)
./scripts/make-runtime-from-brew.sh

# 2) Create the Windows environment (Windows 10 Pro / build 19045)
./scripts/init-prefix.sh

# 3) Build and open the launcher app
./build-app.sh
open "build/Virtual.app"
```

## Reproducible source build

```bash
WINMAC_AUTO_DEPS=1 ./build-wine.sh          # clones Wine, patches, builds, installs
                                            # → runtime/wine-build + runtime/bin/virtual*
```
Builds `wine-11.0` (change with `WINE_TAG`) for **x86_64**, which runs under
Rosetta 2 just like Wine Staging.app; 32-bit programs run through WoW64
(`--enable-archs=i386,x86_64`, mingw-w64 from Homebrew). Homebrew only provides
the headers – the x86_64 libraries (FreeType, GnuTLS, SDL2, MoltenVK) are taken
from `~/Downloads/Wine Staging.app` (`WINMAC_X86_LIBS`) and copied to
`runtime/wine-build/lib`. Built without GStreamer. The previous `virtual*`
commands are kept in `runtime/bin.vorher`. Takes about 5 minutes on an M5 Pro,
considerably longer on smaller Macs. Afterwards run `init-prefix.sh` /
`build-app.sh` as above.

Check that everything works together (uses its own throwaway prefix, your real
one is not touched):

```bash
./scripts/smoke-test.sh      # app build, prefix, 32/64-bit programs, D3D11 via DXVK
```

## Rooms and programs

The native sidebar groups programs by **room** (an independent Wine prefix with its
own C: drive and Windows registry). **Standard** keeps the existing `prefix/`,
including previously added programs. Use **+ → Neuer Raum…** (New room), select it,
and click **Raum einrichten** (Set up room); setup progress appears live. Additional
rooms live under `rooms/`, and their metadata is saved in `rooms.json`.

- **Add:** **+ → Programm hinzufügen…** (Add program) adds an `.exe` or `.msi` to
  the selected room. Drop files directly onto a room in the sidebar, double-click
  a file in Finder, or drop it onto the Dock icon; external files prompt for a room.
- **Install:** the room's **Programm installieren…** (Install program) tool runs
  an EXE installer or `msiexec /i` in that room.
- **Discovery:** Start Menu and public Desktop shortcuts appear automatically,
  with icons read from their Windows executables. Virtual watches shortcut folders
  and rescans after a program or tool exits. **Apps suchen** (Find apps) rescans
  manually. A banner identifies new apps and selects one of them.
- **Run:** select a program and click **Starten** (Start), or double-click its row.
  A green dot means its tracked process is running; **Beenden** (Stop) stops it.
  Shortcuts run through Windows `start /wait /unix`.
- **Logs:** output appears live on the program page. **Log öffnen** (Open log)
  opens the launch log, which remains available after the process exits. Files
  are kept under `logs/`.
- **Tools:** each configured room offers Explorer, Command Prompt, Control Panel,
  Registry Editor, Task Manager, Wine configuration, and its C: drive in Finder.
- **Manage:** rooms and programs have context menus. Additional rooms can be renamed
  or moved to the Trash; Standard cannot be deleted. Remove a program to hide its
  library entry; this does not uninstall it. A discovered shortcut can reappear on
  the next scan. Removing a room also removes its library entries.
- **Settings:** choose the shared runtime and the **Standard-Raum (WINEPREFIX)**
  path, Windows version, and update preferences.

## Links, files and certificates

Virtual reads each room's `system.reg` and `user.reg` for Windows protocol and file
associations. Custom schemes such as `steam://` are registered dynamically with
macOS after app discovery; there is no fixed scheme list in the shipped bundle.
Existing native Mac handlers take precedence. `http`, `https`, `ftp` and `mailto`
are excluded. When several rooms can handle a link, Virtual asks which one to use.
An ordinary file goes to its owning room or a room that declares its extension;
otherwise a configured room can be chosen. Virtual registers as an alternate file
viewer, so it does not replace existing default file handlers.

Certificates (`cer`, `crt`, `der`, `pem`, `p7b`, `p7c`, `pfx`, `p12`) can be opened
with Virtual from Finder or imported with the room tool. The bundled Windows
`certimport.exe` writes to that room's current-user stores: self-issued certificates
to **Root**, other certificates to **CA**, and PFX certificates with private keys
to **My**. Root imports require confirmation; PFX/P12 imports prompt for a password,
passed on stdin. This does not change the macOS Keychain. `build-app.sh` includes
the helper when `x86_64-w64-mingw32-gcc` is available; otherwise import is unavailable.

### Room and handoff limits

Rooms separate Windows state, but are **not security sandboxes**: Wine programs can
access Mac files through mapped drives. Discovery relies on installer shortcuts;
portable apps without shortcuts must be added manually. User Desktop symlinks to
the Mac Desktop are skipped, as are obvious uninstall/help/documentation links.
Some shortcut formats or PE icons may fall back to a generic icon. The bundled `program-runner.exe` tracks a launch and its descendants in a Windows
job, so **Beenden** also stops detached shortcut children. Builds without
mingw-w64 fall back to tracking the initial process.
File and URL handoff depends on valid Windows associations and Wine support.
Registered open commands are launched directly, including per-user registrations
that Wine 11 does not resolve through HKCR. Unusual handlers using DDE or Windows
environment placeholders may still need application-specific setup.
Dynamic URL registration needs a writable app bundle and re-signs it ad hoc.

## Updates

On launch (at most once a day) the app checks
[Releases](https://github.com/nyra-grz/Virtual/releases) for a newer version; you
can also check manually via **Virtual → Nach Updates suchen…** (Check for updates).
It only **suggests** the update – nothing is installed until you click
"Jetzt aktualisieren" (Update now). The update downloads the app archive, replaces
the app and restarts it. If `~/WinMac_Virtual` is an unmodified git checkout, the
scripts are updated with `git pull --ff-only` as well. The check can be turned off
in the settings; without a window: `"Virtual.app/Contents/MacOS/Virtual" --update`.

Publish a new version (requires the GitHub CLI `gh`):

```bash
./scripts/release.sh 0.4.0 "What's new"
```

## Graphics (3D)

```bash
./setup-graphics.sh        # set up DXVK for DirectX 10/11
./setup-graphics.sh --dx12 # additionally VKD3D-Proton for DirectX 12 (experimental)
./setup-graphics.sh --off  # back to WineD3D, the original DLLs are restored
```
- Path: DirectX → DXVK/VKD3D → Vulkan → **MoltenVK** → Metal. MoltenVK comes from
  the Wine installation itself (x86_64). Homebrew's `molten-vk` package is arm64
  only and does not fit the x86_64 Wine running under Rosetta.
- DX12 through VKD3D-Proton mostly does not work on MoltenVK, which is why it is
  optional.
- The DXVK macOS port (1.10.3) only provides `d3d10core` and `d3d11`. DirectX 9
  stays on WineD3D, `dxgi` comes from Wine.
- **MetalFX** is not part of MoltenVK and not required. If it is ever added, then
  as a separate, optional Vulkan layer – never forced.
- **Fallback:** without a GPU runtime set up, Wine renders by itself (WineD3D,
  software if necessary). That always keeps working.

## Limits (honest, not worked around)

- A Wine fork is **not** a real Windows machine. Full API parity only exists on
  real Windows.
- **WinRT** as a whole is not complete in Wine. Virtual implements the networking
  (`Windows.Networking.Connectivity`, `HostName`) and device enumeration APIs with
  the real data of the Mac (see `winrt/README.md`); other WinRT areas are as in Wine.
- The source code is **not** blindly rewritten "wine → virtual" – that would break
  the build. The outward-facing commands are renamed; what stays "wine" internally
  and why is described in `patches/README.md`, including a list of how a program
  can still recognise the Wine base.
- **No** kernel tricks, **no** signature circumvention, **no** hiding of activity.
  Anti-cheat with a ring-0 driver does not run.
- 3D support is experimental; not every game runs.

## Definition of done – status

- [x] Launcher builds (`build-app.sh` → signed `.app`)
- [x] Launcher starts an `.exe`/`.msi` (through the `virtual` runtime, with WINEPREFIX)
- [x] Logs work (one file per launch in `logs/`, live in the window)
- [x] Reproducible runtime (`build-wine.sh` from source **or** quick runtime)
- [x] Finder double-click & drag and drop (CFBundleDocumentTypes for `.exe`/`.msi`)
- [x] WinRT networking and devices with real Mac data + tests (`winrt/`, `patches/`)
- [x] Graphics runtime script with an honest fallback (`setup-graphics.sh`)
- [x] Smoke test in a throwaway prefix (`scripts/smoke-test.sh`)
- [x] Update check via GitHub releases (`scripts/release.sh`)

## License

Free for everyone. © 2026 Daniel Özdek, released under the
**GNU Lesser General Public License 2.1 or later** (`LICENSE`) – the same license
as Wine. You may use, change and redistribute everything; anyone who distributes a
modified version must publish its source code as well. Origin and licenses of the
third-party components used: `LICENSE-Wine.md`.
