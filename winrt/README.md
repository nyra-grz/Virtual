# winrt/ — WinRT stubs

This folder contains three templates for built-in WinRT DLLs in the Wine fork
"Virtual". The new stubs deliberately return no network profiles or devices;
they do not access macOS hardware.

## Classes and behaviour

| DLL / source file in `src/` | Runtime class | Implemented scope |
| --- | --- | --- |
| `windows.devices.wifi.c` | `Windows.Devices.WiFi.WiFiAdapter` | Existing factory scaffolding; `ActivateInstance` returns `E_NOTIMPL`. `FindAllAdaptersAsync` is not implemented yet. Hook for CoreWLAN: `TODO CoreWLAN`. |
| `windows.networking.connectivity.c` | `Windows.Networking.Connectivity.NetworkInformation` | `INetworkInformationStatics.GetInternetConnectionProfile` sets the profile pointer to `NULL` and returns `S_OK`. |
| `windows.devices.enumeration.c` | `Windows.Devices.Enumeration.DeviceInformation` | `IDeviceInformationStatics.FindAllAsync` returns an already completed `IAsyncOperation<DeviceInformationCollection>` with an empty collection. |

Each DLL comes with a `.spec` of the same name exporting
`DllGetActivationFactory` and `DllCanUnloadNow`, plus a test program:
`test_wifi.c`, `test_connectivity.c`, `test_enumeration.c`.

The two new factories support `IActivationFactory` and their respective static
interface through `QueryInterface` and `RoGetActivationFactory`.
`ActivateInstance` returns `E_NOTIMPL`, because these classes are used
statically. Unsupported interface IDs return `E_NOINTERFACE`.
`DllCanUnloadNow` returns `S_FALSE`, as in the WiFi template.

The enumeration supports all four `FindAllAsync` overloads of
`IDeviceInformationStatics`; filters are not evaluated in the empty stub.
Every call gets its own async operation with `IAsyncInfo.Status = Completed`
and `ErrorCode = S_OK`. A completion handler that is set is called immediately,
stored once and released on `Close` or when the operation is freed.
`GetResults` returns a non-NULL `IVectorView<DeviceInformation>` with
`Size = 0`, `IndexOf = false`, `GetMany = 0` and `GetAt = E_BOUNDS`.
`IIterable`/`IIterator` allow an empty iteration (`HasCurrent = false`).
After `Close`, `GetResults` returns `RO_E_CLOSED`; collections obtained before
remain valid. `Cancel` does not change an operation that has already completed.

Other network methods, network events, `CreateFromIdAsync` and
`CreateWatcher` return `E_NOTIMPL`. Newer static interfaces such as
`IDeviceInformationStatics2` are not implemented. These stubs are not a complete
WinRT replacement.

## Headers and ABI

The implementations and tests use the C interfaces from
`windows.networking.connectivity.h`, `windows.devices.enumeration.h` and their
Foundation dependencies. The `WIDL_using_*` macros enable the short interface
names of the Wine/MinGW headers. GUIDs, method order and the generic
async/collection interfaces therefore come straight from the headers.

With the MinGW-w64 13.0.0 checked here these headers are complete; no own
interface declarations were needed. `RO_E_CLOSED` and
`E_ILLEGAL_DELEGATE_ASSIGNMENT` are missing there, though. The enumeration DLL
and test contain minimal definitions guarded by `#ifndef`, using the
[Windows SDK values](https://learn.microsoft.com/en-us/windows/win32/com/com-error-codes-1)
`0x80000013` and `0x80000018`.

All tests define `INITGUID`, so that `IID_IActivationFactory` and the WinRT
interface IDs in particular are defined in the test. No additional UUID libraries
or `-lcombase` are needed for the test programs.

The ABI matches the Wine IDLs for
[Connectivity](https://github.com/wine-mirror/wine/blob/master/include/windows.networking.connectivity.idl)
and [Enumeration](https://github.com/wine-mirror/wine/blob/master/include/windows.devices.enumeration.idl).

## Hooking them into the Wine build

The `.c`/`.spec` pairs are templates for integration into the Wine source tree.
The following steps are done manually in the Wine build of your choice; the
files here do not register or install any DLLs.

For each DLL, copy the pair to `thirdparty/wine/dlls/<dll-name>/` and adapt the
`Makefile.in` there, for example for Connectivity:

```make
MODULE = windows.networking.connectivity.dll
IMPORTS = combase ole32
SOURCES = windows.networking.connectivity.c
```

Use `windows.devices.enumeration` accordingly for Enumeration. In a Wine tree
with existing implementations, replace their previous source files in `SOURCES`
so that exports are not defined twice. If the DLL directory is new, it also has
to be added to the Wine configuration. Then configure, build and install Wine.

The DLLs must be resolvable for their runtime classes in the target prefix.
A DLL override alone does not register a WinRT class: if the class entries
already present in the Wine build are missing, register the class under
`HKLM\Software\Microsoft\WindowsRuntime\ActivatableClassId\<runtime class>`
with `DllPath` (the respective DLL name) and `ThreadingModel` (`DWORD`, `3` for
Both). Then set the DLL overrides to `builtin` if needed.
A `REGDB_E_CLASSNOTREG` in the test points to a missing activation registration
or a DLL that is not installed.

## Building the test programs (MinGW)

From the project root, with an existing `build/`:

```sh
x86_64-w64-mingw32-gcc winrt/src/test_wifi.c -o build/test_wifi.exe -lruntimeobject -lole32
x86_64-w64-mingw32-gcc winrt/src/test_connectivity.c -o build/test_connectivity.exe -lruntimeobject -lole32
x86_64-w64-mingw32-gcc winrt/src/test_enumeration.c -o build/test_enumeration.exe -lruntimeobject -lole32
```

After integrating and registering the stubs in the target Wine:

```sh
runtime/bin/virtual build/test_wifi.exe
runtime/bin/virtual build/test_connectivity.exe
runtime/bin/virtual build/test_enumeration.exe
```

`test_wifi` is the existing factory smoke test; its message about
`FindAllAdaptersAsync` is not a check of that method.
The new tests check the actual return value and exit with code `1` on errors and
`0` on success.
`test_connectivity` checks the static interface, the COM identity, `NULL`/`S_OK`
and the handling of a missing output pointer.
`test_enumeration` checks all four overloads, completion status and callback,
the empty collection and iteration, reference handling of the handler, and
`Close`. These expectations apply to the stubs described here, not to a Windows
system with real devices or to other Wine implementations.

Expected success messages of the new tests:

```text
NetworkInformation: GetInternetConnectionProfile -> NULL, S_OK (Stub)
DeviceInformation: FindAllAsync -> Completed, 0 Geraete (Stub)
```

Verified: all three tests compile and link with the commands above
(MinGW-w64 13.0.0, GCC 15.2.0). The two new DLL sources additionally pass a
MinGW syntax check with `-Wall -Wextra -Werror -Wno-unused-parameter`.

## Runtime test without a Wine source build

Connectivity and Enumeration only need standard Windows headers. They can
therefore be built with MinGW as native PE DLLs and tested in any Wine. The WiFi
template uses `wine/debug.h` and only works inside the Wine tree.

```sh
for d in windows.networking.connectivity windows.devices.enumeration; do
  x86_64-w64-mingw32-gcc -shared -O2 -static-libgcc winrt/src/$d.c \
      winrt/src/winrt-stubs.def -o build/$d.dll -lruntimeobject -lole32
done
# copy into a TEST prefix (not your everyday prefix):
cp build/windows.*.dll "$WINEPREFIX/drive_c/windows/system32/"
WINEDLLOVERRIDES="winedbg.exe=d;windows.networking.connectivity,windows.devices.enumeration=n" \
    runtime/bin/virtual build/test_connectivity.exe
```

Wine already registers both classes under `ActivatableClassId` with a `DllPath`
pointing to `system32`; the override `n` (native) is enough to load the stubs
instead of Wine's own DLLs. `WINEDEBUG=+loaddll` shows which variant was
actually loaded.

Result on 2026-10-23 with wine-11.18 (Staging), fresh test prefix:

| Test | Loaded DLL | Exit | Output |
| --- | --- | --- | --- |
| `test_connectivity` | native (stub) | 0 | `GetInternetConnectionProfile -> NULL, S_OK (Stub)` |
| `test_enumeration` | native (stub) | 0 | `FindAllAsync -> Completed, 0 Geraete (Stub)` |

Cross-check with Wine's own DLLs: both tests crash. `test_connectivity`
deliberately passes a NULL output pointer; Wine's implementation does not check
for it and writes to address 0. The tests are therefore tailored specifically to
these stubs (see above).
