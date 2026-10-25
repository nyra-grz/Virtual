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

They are applied in this order on top of `WINE_TAG` (wine-11.0). Details, limits and
tests: `winrt/README.md`.

## CrossOver base (the runtime that ships)

Since 0.7.0 the runtime is built from CodeWeavers' open-source CrossOver sources
(Wine 11.0 plus their Mac work: msync, D3DMetal/DXMT bridge, controller support)
instead of plain Wine 11.0. `build-wine-cx.sh` downloads the source archive, checks
its SHA-256 and applies `crossover/0001-virtual-compatibility.patch`, which is the
patch series above ported onto that base (0019 is replaced by CrossOver's own
Mac-driver bridge) plus two CrossOver-specific changes: the real Windows user name
instead of CrossOver's fixed "crossover", and libinotify flags for winebus.

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
