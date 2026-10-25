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

For users, releases now contain the Wine engine, Wine Mono, DXVK, setup scripts
and the local authentication helper inside `Virtual.app`. Move the app to
Applications, open it, and choose a Windows installer or program. No checkout,
Homebrew, Python, terminal commands or agent is needed. User data stays in
`~/WinMac_Virtual`; the bundled engine is separate from rooms and installed apps.

Before a program or installer starts, Virtual prepares its room automatically.
Existing rooms receive setup updates once per engine version. Concurrent starts
share one setup job; an unsuccessful setup is reported and can be retried.
EXE, MSI and LNK imports share this launch path, including Finder's Open With.
Portable applications retain their working directory and must keep their complete
folder. Installers are tracked with their child processes, and newly installed
apps are discovered from shortcuts and App Paths/Uninstall registrations.
Missing Windows components and nonzero exits are reported in the app with a log.
Microsoft .NET Framework 4.8 remains available in the room's Windows tools for
applications that need it instead of Wine Mono. Wine still cannot run every app.
On Apple Silicon, the x64 Wine engine also requires Rosetta 2.

**First start (Gatekeeper):** Virtual is free and only ad-hoc signed, without a
paid Apple Developer ID, so macOS blocks it the first time. Open it once, then go
to System Settings → Privacy & Security and click **Open Anyway**. Alternatively,
in Terminal: `xattr -dr com.apple.quarantine /Applications/Virtual.app`.

For development, the source checkout is expected at `~/WinMac_Virtual`:

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
WINMAC_AUTO_DEPS=1 ./build-wine-cx.sh       # pinned CrossOver FOSS + Virtual patch set
                                            # → runtime/wine-build + runtime/bin/virtual*
```
The complete app uses the CrossOver 26.1.0 FOSS Wine source base plus Virtual's
ported changes. `build-wine-cx.sh` verifies the source archive, applies the
versioned patch set and invokes the shared build pipeline. The ordinary upstream
Wine variant remains available through `build-wine.sh` and `WINE_TAG`.

Builds the Wine 11.0 base for **x86_64**, which runs under
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

Launcher regression tests (requires full Xcode for XCTest):

```bash
cd app && swift test
```

Compatibility additions include automatic inspection of EXE/DLL imports and .NET
runtime configuration, shared component setup before queued launches, and one
automatic repair/retry for recognized missing runtime DLLs. Unknown failures are
reported instead of repeatedly relaunching the app. Winetricks handles the pinned
legacy recipes; current .NET runtime installers come from Microsoft's verified
release metadata. Native .NET 4.8 is selected for detected classic WPF/WinRT apps.

GStreamer supports media decoding; the runtime tests include an actual H.264 frame
decoded to RGB32. A keyboard regression checks Mac layout/user-locale handling,
and asynchronous directory notifications are tested through the kqueue bridge.
Choose per-room DXVK or experimental DXMT in the room's **… → Grafik** menu.
Component download/setup output is visible in the selected program's log.

To build the complete app locally without publishing:

```bash
WINMAC_BUNDLE_ENGINE=1 ./build-app.sh
```

## Rooms and programs

The native sidebar groups programs by **room** (an independent Wine prefix with its
own C: drive and Windows registry). **Standard** keeps the existing `prefix/`,
including previously added programs. Use **+ → Neuer Raum…** (New room), select it,
and click **Jetzt einrichten** (Set up now); setup progress appears live. Additional
rooms live under `rooms/`, and their metadata is saved in `rooms.json`.

A room's page shows its state (ready, running, not set up), its apps as tiles with a
start/stop button, and the Windows tools grouped into **Dateien** (files) and
**System**. **Alles beenden** (Stop everything) appears while something runs and ends
every program and Wine service of that room.

- **Add:** **+ → Programm hinzufügen…** (Add program) adds an `.exe` or `.msi` to
  the selected room. Drop files directly onto a room in the sidebar, double-click
  a file in Finder, or drop it onto the Dock icon; external files prompt for a room.
- **Install:** the room's **Programm installieren…** (Install program) button runs
  an EXE installer or `msiexec /i` in that room. `.exe`/`.msi` files can also be
  dropped onto the room page.
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
- **Quit:** closing Virtual ends Wine in every room (`wineserver -k`), so no Wine
  processes stay in the background. If programs are still running, Virtual asks first.
- **Sound:** programs can read and change the device volume (`IAudioEndpointVolume`);
  it is shared by all programs of a room and kept across restarts. Program, session and
  channel volume work on macOS and never change the Mac's own volume (patch 0012).
- **Wi-Fi:** real macOS adapter and scan data are available through Windows WLAN and
  WinRT APIs, including device enumeration. macOS may withhold SSIDs and BSSIDs
  according to location privacy settings (patch 0014).
- **Windows sign-in inside a room:** programs that protect their own connections with
  Windows authentication (NegotiateStream, WCF, local HTTP) work without a domain. Each
  room gets its own random identity on first use (patch 0013,
  `scripts/setup-local-auth.sh` installs the helper once).

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

## Managed applications (.NET Framework)

The source-built Wine 11.0 runtime includes [Wine Mono 10.4.1](https://github.com/wine-mono/wine-mono/releases/tag/wine-mono-10.4.1), the version
expected by that Wine release. `scripts/setup-managed-runtime.sh` downloads the
upstream archive, verifies its pinned SHA-256 checksum, and installs it only under
Virtual's generated `runtime/wine-build/share/wine/mono/` directory. Runtime
creation runs this step automatically; existing source runtimes can run the script
once and regenerate their wrappers with `scripts/make-runtime-from-brew.sh`.
Other Wine installations are not modified.

Virtual no longer disables `mscoree` or `mshtml` globally. Explicit
`WINEDLLOVERRIDES` remain respected. Runtime errors are logged by default
(`WINEDEBUG=err+all`); use `WINEDEBUG=-all` explicitly to silence them. New room
setup also supplies missing Windows default cursor preferences without replacing
an existing user cursor scheme.

Wine Mono supplies .NET Framework-compatible APIs, including Windows service
support. A modern **.NET Desktop Runtime** (such as .NET 8) is a separate product
and does not replace the .NET Framework 4.8 dependency of older applications.
Compatibility still depends on each application's Windows APIs.

For applications requiring native .NET Framework 4.8 and WinRT (such as the Windows
SEB client), use the room's **.NET Framework 4.8** tile. It stops the room's Windows
programs, replaces Wine Mono in that room, downloads verified Microsoft installers
and Windows SDK metadata, and installs the native WinRT bridge. Installation takes
several minutes. Other rooms keep their current managed runtime. Command-line:
`WINEPREFIX=/path/to/prefix scripts/setup-dotnet48.sh win10`.

This adds API compatibility. Exam deployment still depends on the school's SEB
configuration and supported platforms; Virtual does not alter SEB or its checks.


## Updates

On launch (at most once a day) the app checks
[Releases](https://github.com/nyra-grz/Virtual/releases) for a newer version; you
can also check manually via **Virtual → Nach Updates suchen…** (Check for updates).
It only **suggests** the update – nothing is installed until you click
"Jetzt aktualisieren" (Update now). The update downloads the complete app archive,
including its engine and setup assets, replaces the app and restarts it. Runtime
fixes therefore reach other users as part of the update. Rooms are prepared for
the new engine on their next launch. If `~/WinMac_Virtual` is an unmodified git checkout, the
scripts are updated with `git pull --ff-only` as well. The check can be turned off
in the settings; without a window: `"Virtual.app/Contents/MacOS/Virtual" --update`.

Publish a new version (requires the GitHub CLI `gh`):

```bash
./scripts/release.sh 0.4.0 "What's new"
```

## Graphics (3D)

```bash
./setup-graphics.sh        # set up DXVK for DirectX 10/11 (or the room's last choice)
./setup-graphics.sh --dxmt # DXMT instead: DirectX 10/11 straight to Metal
./setup-graphics.sh --dx12 # additionally VKD3D-Proton for DirectX 12 (experimental)
./setup-graphics.sh --off  # back to WineD3D, the original DLLs are restored
```
- **DXMT** (3Shain/dxmt v0.80, `scripts/install-dxmt-runtime.sh`) is faster and reports the
  real GPU, but aborts on D3D11 functions it does not implement yet (e.g.
  `SwapDeviceContextState`), so DXVK stays the default. The choice is stored per room.
- Without either, Wine's own `d3d12` (vkd3d over MoltenVK) already handles basic
  DirectX 12 (device, swap chain, present).
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

## Media and file notifications

- **Video/audio** (Media Foundation, DirectShow): Wine is built with GStreamer
  (`build-wine.sh` when the GStreamer.framework with development files is present);
  `scripts/bundle-gstreamer.sh` puts 52 MB of x86_64 GStreamer libraries and LGPL/BSD
  plugins (FFmpeg via gst-libav, dav1d, vpx, opus …) into `lib/gst` of the runtime.
- **File change notifications** (`ReadDirectoryChangesW`, `FindFirstChangeNotification`):
  the Wine server uses libinotify-kqueue (`scripts/build-libinotify.sh`, MIT), as on FreeBSD.

## Compatibility test

```bash
uv run scripts/compat-test.py                      # default list of popular apps
uv run scripts/compat-test.py Mozilla.Firefox 7zip.7zip --out logs/compat-x
uv run scripts/compat-test.py --list support/compat-apps.txt --jobs 3 --out logs/compat-broad
```
Downloads installers from the public winget manifests (checksums verified), installs
each app silently in its own clone of a freshly set up room and starts it, using the
engine inside `build/Virtual.app` (what ships) unless `--engine` says otherwise.
An app only counts as running when its main window is still open after 60 s (small
splash/updater windows get up to three times as long), is not an error dialog and is
not a single-coloured (blank) window. `report.md`/`results.json` also list DLLs that
are really missing. The apps' windows briefly appear on screen.

`support/compat-apps.txt` contains 150 package IDs selected from the Scout's
manifest checks on 25 October 2026. This is test coverage to run, not a list of
compatible apps; framework labels are annotations. Installer checksums are verified
when downloaded. A full run downloads and installs substantial amounts of software;
start with a small group of IDs to check a new runtime first. Each worker gets its
own cloned prefix, and only that prefix is stopped during cleanup. These Wine
prefixes are not security sandboxes.

`causes.md` groups failures for triage. An unimplemented API is reported explicitly;
nearby Wine stubs are only diagnostic clues, not proof of a crash's cause. Window
observation confirms startup, not login, updates or full application functionality.
Rendering remains unverified when a window cannot be captured or when using
`--guest-windows`.

Run the tester's regression checks without Windows installers:

```bash
uv run --with pyyaml python -m unittest discover -s scripts/tests -v
```

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
