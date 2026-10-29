# patches/ — own changes to the Wine fork "Virtual"

After cloning, `build-wine.sh` applies every `*.patch` in this folder to the Wine
source (`git apply --check` first). A failed patch stops the build, so a runtime
cannot silently ship without a required compatibility fix.

## The patches

| Patch | What it does |
| --- | --- |
| `0002-nsiproxy-macos-wifi-type.patch` | Reports Wi-Fi interfaces on macOS as IEEE 802.11 (IfType 71) instead of Ethernet |
| `0003-hostname-implement.patch` | Implements `Windows.Networking.HostName` |
| `0004-connectivity-implement.patch` | Implements `Windows.Networking.Connectivity` |
| `0005-enumeration-upstream-fixes.patch` | Four pending upstream fixes for `windows.devices.enumeration` (Wine merge request !11997, original commit messages kept) |
| `0006-devices-implement.patch` | Implements `Windows.Devices.Enumeration` further (real audio endpoints, names, device classes, CreateFromId, watcher events) and the `Windows.Media.Devices` selectors |
| `0007-bcrypt-gnutls-zero-iv.patch` | AES/3DES in ECB mode and AES key wrap no longer crash: the bundled GnuTLS 3.8.7 faults on block ciphers initialized without IV, so bcrypt now passes an all-zero vector (bcrypt tests: 15 failures → 0) |
| `0008-ncrypt-ecdsa-persisted-keys.patch` | ncrypt: ECDSA P-256 keys (from upstream) and named, persisted keys (`NCryptOpenKey`/`NCryptDeleteKey`, stored in the prefix registry, not DPAPI-protected). Needed by Epic Games Launcher / EOS for its DPoP login key (ncrypt tests: 470, 0 failures) |
| `0009-win32u-accessibility-keys-setcursors.patch` | StickyKeys, ToggleKeys and FilterKeys can be read and changed via `SystemParametersInfo` (stored like on Windows, Windows 10 defaults), so games can turn off the Shift-x5 hotkey. `SPI_SETCURSORS` succeeds instead of failing (built-in cursors only) |
| `0010-wintypes-resolve-metadata.patch` | `RoResolveNamespace` reads the `.winmd` files, so the .NET Framework can resolve Windows Runtime types instead of failing on load |
| `0011-combase-parameterized-iids.patch` | `RoGetParameterizedTypeInstanceIID`: GUIDs of generic WinRT interfaces (`IVector<T>`, `IAsyncOperation<T>` …) from their type signature |
| `0012-mmdevapi-endpoint-volume.patch` | Full `IAudioEndpointVolume` (real channel count, master/channel levels with balance, mute, steps, notifications, shared by all programs of a room and saved). On macOS session/stream/channel volume and mute now actually work: applied to the samples, the Mac volume stays untouched (test: 73 checks, 0 failures) |
| `0013-msv1_0-room-local-auth.patch` | Windows authentication between the programs of a room (NegotiateStream, WCF, local HTTP) without a domain: each room gets its own random identity on first use; remote targets still use Samba's `ntlm_auth` |
| `0014-wlanapi-wifi.patch` | Real macOS CoreWLAN adapter and scan data through WlanAPI and `Windows.Devices.WiFi`; the same adapter appears in `DeviceInformation` and opens through `FromIdAsync` |
| `0015-macdrv-desktops-overlay.patch` | Only the input desktop's windows are visible (SwitchDesktop reaches all processes); kiosk desktops and borderless full-screen windows float above normal Mac apps, shrinkable with Virtual's shortcut |
| `0016-chromium-browsers.patch` | Edge, Chrome, Electron and CEF work: `--in-process-gpu` and `--no-sandbox` for the browser process (no warning bar via policy), `SIO_ADDRESS_LIST_SORT` for Chromium's DNS client, no crash when the window starts maximized, custom title bars (tab strip) stay visible below the Mac title bar; Windows CJK font names map to the Mac's CJK fonts |
| `0017-com-services-winhttp.patch` | COM classes in Windows services start (long service names, `ServiceParameters`), owners may set the DACL, typelib marshaler handles `LPWSTR`/`LPSTR`, WinHTTP keeps header lines up to 64 KB: Google's updater (Chrome installer) gets through |
| `0018-macdrv-keyboard-locale-upstream.patch` | Upstream Wine fix (3b1ab640): keyboard layouts keep the current user locale, so activating a layout no longer fails with "Changing user locale is not supported"; layout comparison parenthesized |
| `0019-macdrv-dxmt-bridge.patch` | Exports the dispatch table DXMT v0.80 expects from the Mac driver (adapted to Wine 11) and gives windows a client view on demand: DirectX 10/11 via DXMT → Metal, enabled per room by `setup-graphics.sh --dxmt` (DXVK stays the default) with `winemetal` from `scripts/install-dxmt-runtime.sh` |
| `0020-services-object-security.patch` | `QueryServiceObjectSecurity`/`SetServiceObjectSecurity` store and return a service's descriptor (Windows default DACL otherwise) instead of stubs; Epic Games' updater service works |
| `0021-winegstreamer-fixed-caps.patch` | Media formats are only converted from fixed GStreamer caps; incomplete types stay unknown while Media Foundation negotiates instead of failing |
| `0022` (in `crossover/`) | `GetProcessGroupAffinity` reports processor group 0 like Windows instead of failing as a stub without setting the count; Qt 6 apps such as KeePassXC crashed on the garbage |
| `0023-threadpool-timer-ex.patch` | Implements `SetThreadpoolTimerEx` / `TpSetTimerEx` from Wine upstream, preserving queued/running callback cancellation semantics and serializing immediate submission with cancellation. Removes a confirmed Zoom API-stub abort; 32-/64-bit semantic and concurrent cancellation probes, not a full Zoom compatibility claim. |
| `0024-uxtheme-parent-background-ex.patch` | Exports and implements `DrawThemeParentBackgroundEx` for modern child controls: parent erase/print, static-brush fallback, window/client coordinates, clipping and DC restoration. A 32-/64-bit pixel probe fails on the previous missing export and passes 24 checks per architecture. Removes the API blocker recorded for WinDirStat; the complete application has not been retested. |
| `0025-electron-image-detection.patch` | Recognizes modern Electron executables by their Node registration and Electron fuse exports, including packages whose resources live in a version subdirectory. Keeps Node-only executables, Electron's Node CLI mode, renderer children and explicit opt-out unchanged. Includes 32-/64-bit process probes and a VS Code 1.142.0 comparison: black window without the existing Chromium switches; editor and opened test text render with them. |
| `0026-memory-protection-contracts.patch` | On Darwin, changing a shared file view to `PAGE_WRITECOPY` creates a genuine private shadow with Mach `VM_PROT_COPY`; writes no longer leak into the file or peer views. Keeps maximum rights for later guard/protection transitions. `VirtualLock` consumes a one-shot guard with `STATUS_GUARD_PAGE_VIOLATION`; successful writable-page locking updates software write-watch state without changing payload. |
| `0027-memory-status-address-space.patch` | `GlobalMemoryStatusEx.ullAvailVirtual` counts free Windows address regions instead of subtracting resident physical memory. Reservations and releases are visible on every call even while physical-memory metrics remain cached. Region traversal has a cost proportional to address-space fragmentation (measured ~0.51 ms with 1,024 reservations on the development Mac). |
| `0028` (in `crossover/`) | Restores Wine 11.0's full macOS GSBASE transitions at Windows/Unix, callback and signal boundaries. Inline x64 thread/process IDs, LastError, stack bounds and fiber data address the real TEB, instead of selected Darwin TSD mirrors. `winrt/tests/teb.c` compares inline/API behavior on the main thread, eight workers, fibers and window callbacks; the 32-bit path is retained. Plain upstream Wine already contains these transitions. |
| `0029` (in `crossover/`) | Adds `DXGIDeclareAdapterRemovalSupport` with once-only, concurrent and built-in-device late-call validation. Native third-party device creation is not tracked. Exports `WcsCreateIccProfile` with regular parameter/handle/unsupported errors, preserving the existing real ICC profile for caller fallback; WCS XML conversion remains unsupported. |
| `0030` (in `crossover/`) | GDI OpenGL forwarders hold a temporary module reference rather than pinning the first renderer forever, resolve functions afresh and preserve the forwarded last error. OpenGL clears freed per-thread pixel-format cache fields on detach so repeated load/unload is safe. Allows PrusaSlicer to select its bundled Mesa renderer automatically. |
| `0031` (in `crossover/`) | Direct2D custom-effect factories return `IUnknown`, which is queried for `ID2D1EffectImpl` before initialization and property callbacks. Feature levels, bitmap formats and intermediate render-target precision come from the real D3D device. Tests use distinct COM identities, bound properties, balanced destruction and actual bitmap creation. |

The graphics probes cover 32/64-bit exports, real ICC preservation, repeated
OpenGL context/module lifetimes and custom-effect COM identity. The 32-bit D2D
probe and late-device tests explicitly use WineD3D's OpenGL path; 32-bit Vulkan
and native-renderer late-device tracking are not certified by those tests.
Modern Paint.NET still needs standard Direct2D effects absent from this base
(including Histogram and other effects used for category discovery); its full
startup/editing workflow is not claimed as fixed by these patches.

`winrt/tests/memory.c` exercises 137 documented contracts per architecture: page
reservation/commit/decommit, zeroing, protection boundaries, executable buffers,
heap alignment/reallocation, private file writes, guard locking and live virtual
availability. It is a focused regression gate, not proof of full Windows memory
parity. The larger upstream heap suites retain known `todo_wine` differences;
the combined x64 upstream suite can reach a Rosetta exception-emulation failure
during write-watch tests, while the isolated write-watch case completes. That
integration issue remains under investigation. These changes do not resolve the OBS
startup crash by themselves.

They are applied in this order on top of `WINE_TAG` (wine-11.0). Details, limits and
tests: `winrt/README.md`.

## CrossOver base (the runtime that ships)

Since 0.7.0 the runtime is built from CodeWeavers' open-source CrossOver sources
(26.3.0 since 0.7.1)
(Wine 11.0 plus their Mac work: msync, D3DMetal/DXMT bridge, controller support)
instead of plain Wine 11.0. `build-wine-cx.sh` downloads the source archive, checks
its SHA-256 and applies `crossover/series` in order: the patches above ported onto
that base as one commit each (0015 merged with CrossOver's Mac driver, 0019 replaced
by CrossOver's own bridge) plus one CrossOver-specific commit (the real Windows user name instead of
CrossOver's fixed "crossover"). Since 26.3 CrossOver carries our libinotify fix
for winebus itself.
The WinRT networking/devices patches (0003–0006, 0014) are required alongside the
later compatibility fixes. A rebase must preserve them or prove equivalent
upstream behavior with their regression tests; a patch failure stops the build.

The source of truth is `patches/crossover/series` plus its checked patch files and
the archive digest in `build-wine-cx.sh`. `WINMAC_PREPARE_ONLY=1 bash build-wine-cx.sh`
reconstructs that exact source under `thirdparty/crossover/`. The older
`thirdparty/wine-cx-series` checkout is on `series/26.1`; do not regenerate the
26.3 patch series from it. For a new base, validate every required patch and run
the full preservation gate before replacing the engine.

## Renaming: what actually happens (honestly)

The goal was "wine → virtual" in the source code as well. In practice:

- **Safe and done:** the *outward-facing command set* is fully renamed.
  `runtime/bin/` contains `virtual`, `virtualserver`, `virtualboot`, `virtualcfg`
  and `virtualpath` (created by `scripts/make-runtime-from-brew.sh` or at the end
  of `build-wine.sh`). Users and the launcher app only ever see `virtual*`.
  The default prefix is `~/WinMac_Virtual/prefix`.

- **Deliberately NOT touched (would break):** the *internal* binary names
  `wine`/`wineserver` and the client-server protocol, the names of the built-in
  DLLs and `winebuild`'s PE/ELF generation. A blind search-and-replace of "wine"
  in the source destroys the build (protocol symbols, driver names, comments,
  Windows API names containing "win"). That is a real limit, not convenience –
  see README › "Limits".

- **Cosmetics via patch (optional):** visible brand strings in `virtualcfg`
  (About dialog, window title). Example: `0001-branding-virtual.patch.example`.
  Shipped as `.example` because the exact context differs between Wine versions –
  to enable it, rename it to `0001-branding-virtual.patch` and check it against
  the chosen `WINE_TAG`.

## Fingerprints / version setting

The Windows version and build (Windows 10 Pro, 19045) are set **in the
registry** – `scripts/init-prefix.sh`. That is where programs actually look
(`HKLM\…\CurrentVersion`), and it works reliably across all Wine versions without
touching the compiler.

## How a program can still recognise Wine/Virtual (complete & honest)

These points remain – hiding them would be "signature/detection circumvention",
which is explicitly **not** a goal:

1. `ntdll.dll` exports `wine_get_version` / `wine_get_build_id`. The classic Wine
   check. Removing it breaks programs that ask *politely*.
2. Registry keys `HKCU\Software\Wine` and `HKLM\Software\Wine`.
3. Device names and paths: `\\.\\winemac.drv`, `Z:\` → `/`, `/dev` mappings.
4. Missing real Windows artifacts: drivers, WMI classes, certain services,
   `C:\Windows\System32` files with the original Microsoft signature.
5. Timing and behaviour differences of individual APIs compared to real Windows.
6. No real NT kernel: anti-cheat with a ring-0 driver fundamentally does not run.

Bottom line: "no VM detection" in the sense of *maximum compatibility* means
*presenting* itself like a normal Windows 10 installation (version, build, no
Mono/Gecko popup) – not actively hiding from protection software.
