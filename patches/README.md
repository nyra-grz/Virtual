# patches/ — own changes to the Wine fork "Virtual"

After cloning, `build-wine.sh` applies every `*.patch` in this folder to the Wine
source (`git apply --check` first; if a patch does not fit the chosen `WINE_TAG`,
it is skipped cleanly instead of breaking the build).

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

They are applied in this order on top of `WINE_TAG` (wine-11.0). Details, limits and
tests: `winrt/README.md`.

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
