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
├── winrt/               WinRT stub scaffolding + test programs
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

## Using the app

- **Add:** `+` in the toolbar, drag an `.exe`/`.msi` into the window, double-click
  it in Finder, or drop it on the app icon.
- **Start:** select a program → "Starten" (Start), or double-click it in the list.
- **Status & stop:** green dot = running; "Beenden" (Quit) stops it.
- **Logs:** one log file per launch in `logs/`, shown live in the window;
  "Log im Finder" (Show log in Finder) opens it.
- **Settings:** runtime path, prefix, Windows version; also
  "Windows-Umgebung jetzt einrichten" (set up Windows environment now).

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
./scripts/release.sh 0.3.0 "What's new"
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
- **WinRT** is not fully available in Wine. `winrt/` provides the pattern and a
  stub, not a complete WinRT implementation (that would be a months-long project).
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
- [x] WinRT scaffolding + test programs (`winrt/`)
- [x] Graphics runtime script with an honest fallback (`setup-graphics.sh`)
- [x] Smoke test in a throwaway prefix (`scripts/smoke-test.sh`)
- [x] Update check via GitHub releases (`scripts/release.sh`)

## License

Free for everyone. © 2026 Daniel Özdek, released under the
**GNU Lesser General Public License 2.1 or later** (`LICENSE`) – the same license
as Wine. You may use, change and redistribute everything; anyone who distributes a
modified version must publish its source code as well. Origin and licenses of the
third-party components used: `LICENSE-Wine.md`.
