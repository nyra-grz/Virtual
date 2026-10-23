# winrt/ — WinRT networking and devices

Virtual implements the WinRT APIs that programs use to ask about the network and
the devices of the machine. The implementation lives in Wine itself, as patches in
`patches/` that `build-wine.sh` applies, and it reports the **real state of the
Mac** – the actual network connection, addresses, speakers and microphones – not
invented values.

| Patch | Area |
| --- | --- |
| `0002-nsiproxy-macos-wifi-type.patch` | Wi-Fi interfaces are reported as Wi-Fi (IfType 71) instead of Ethernet on macOS |
| `0003-hostname-implement.patch` | `Windows.Networking.HostName` |
| `0004-connectivity-implement.patch` | `Windows.Networking.Connectivity` (NetworkInformation, ConnectionProfile …) |
| `0005-enumeration-upstream-fixes.patch` | four pending upstream Wine fixes (merge request !11997) |
| `0006-devices-implement.patch` | `Windows.Devices.Enumeration`, audio selectors in `Windows.Media.Devices` |

## What works

**Windows.Networking.Connectivity**
- `NetworkInformation`: `GetInternetConnectionProfile` (the adapter of the best route
  to the internet), `GetConnectionProfiles` (every connected adapter), `GetHostNames`
  (computer name and every local address, with `IPInformation`), `GetLanIdentifiers`,
  `GetProxyConfigurationAsync` (WinHTTP proxy settings), `GetSortedEndpointPairs`,
  and the `NetworkStatusChanged` event (checked every two seconds while handlers are
  registered).
- `ConnectionProfile`: name, connectivity level, network names, connection cost, data
  plan status, network adapter (IANA type, link speeds, adapter and network id,
  connected profile), security settings, local usage (interface counters), WLAN/WWAN
  details, domain connectivity level, usage and connectivity interval queries.

**Windows.Networking.HostName**
- Type detection (domain name, IPv4, IPv6, Bluetooth), `CanonicalName` (normalised
  addresses, lowercase domain names), `DisplayName` (IDN decoded), `IsEqual`,
  `Compare`, `ToString`, and `IPInformation` for local addresses.

**Windows.Devices.Enumeration**
- The real audio endpoints (speakers, microphones, headsets, an iPhone used as a
  microphone …) appear as `SWD\MMDEVAPI` device interfaces, exactly as on Windows,
  together with the GPU, monitors and input devices Wine knows.
- `DeviceInformation`: `Name`, `IsEnabled`, `IsDefault` (default audio endpoints),
  `EnclosureLocation`, `Update`, `Properties`.
- `FindAllAsync`, `CreateWatcher` and `GetAqsFilterFromDeviceClass` for every
  `DeviceClass`, `CreateFromIdAsync` (also with additional properties and a
  `DeviceInformationKind`), and the `Added`, `Updated`, `Removed`,
  `EnumerationCompleted` and `Stopped` watcher events.
- `MediaDevice.GetAudioRenderSelector`, `GetAudioCaptureSelector` and
  `GetVideoCaptureSelector` return the filters that match these devices.

## Honest limits

- **Wi-Fi name:** macOS only reveals the SSID to apps with location access, which
  the Wine process does not have. `GetConnectedSsid` is therefore empty, and the
  profile is named "Wi-Fi" (wired: "Ethernet"), like unnamed networks on Windows.
  Wi-Fi security mode and signal strength are unknown for the same reason.
- **Cameras, scanners, portable storage (WPD), location sensors:** Wine has no macOS
  backend for these, so the device class queries correctly return no devices.
- **Usage history:** Windows keeps a network usage database; Virtual reports the
  interface counters since boot and no history.
- **Thumbnails** of devices (`GetThumbnailAsync`) are not implemented.
- `GetSortedEndpointPairs` keeps the given order instead of applying RFC 6724.

## Tests

`tests/network.c` and `tests/devices.c` call every API above through the public WinRT
activation API, print what they find and exit with 1 on any failure:

```sh
x86_64-w64-mingw32-gcc winrt/tests/network.c -o build/network.exe -lruntimeobject -lole32 -luuid
x86_64-w64-mingw32-gcc winrt/tests/devices.c -o build/devices.exe -lruntimeobject -lole32 -luuid
runtime/bin/virtual build/network.exe
runtime/bin/virtual build/devices.exe
```

Result on 23 October 2026 on a MacBook Pro (Apple M5 Pro), compared with unpatched
wine-11.0:

| Test | wine-11.0 | Virtual |
| --- | --- | --- |
| `network.exe` | 43 of 63 checks failed | 115 checks, 0 failed |
| `devices.exe` | 35 of 56 checks failed | 106 checks, 0 failed |

## Windows.Devices.WiFi template

`src/windows.devices.wifi.c` is a factory template for `Windows.Devices.WiFi`, which
Wine does not provide at all. `ActivateInstance` returns `E_NOTIMPL` and
`FindAllAdaptersAsync` is not implemented yet (hook for CoreWLAN: `TODO CoreWLAN`).
It is built inside the Wine tree (it uses `wine/debug.h`); `src/test_wifi.c` is its
factory smoke test:

```sh
x86_64-w64-mingw32-gcc winrt/src/test_wifi.c -o build/test_wifi.exe -lruntimeobject -lole32
```
