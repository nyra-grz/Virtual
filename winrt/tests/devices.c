/* Checks Windows.Devices.Enumeration through the public WinRT activation API, prints the
 * devices it finds and exits with 1 on any failure.
 *
 *   x86_64-w64-mingw32-gcc winrt/tests/devices.c -o build/devices.exe -lruntimeobject -lole32 -luuid
 *   runtime/bin/virtual build/devices.exe
 */
#define COBJMACROS
#define INITGUID
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Devices_Enumeration
#define WIDL_using_Windows_Media_Devices
#include <stdio.h>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <activation.h>
#include <windows.foundation.h>
#include <windows.devices.enumeration.h>
#include <windows.media.devices.h>

static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    printf("FAIL line %d: %s – ", __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const char *str(HSTRING s)
{
    static char buf[4][512];
    static int n;
    char *out = buf[n++ % 4];
    UINT32 len;
    const WCHAR *w = WindowsGetStringRawBuffer(s, &len);
    out[len ? WideCharToMultiByte(CP_UTF8, 0, w, len, out, 511, NULL, NULL) : 0] = 0;
    return out;
}

static void *factory(const WCHAR *class_name, REFIID iid)
{
    HSTRING name = NULL;
    void *out = NULL;
    WindowsCreateString(class_name, wcslen(class_name), &name);
    if (FAILED(RoGetActivationFactory(name, iid, &out))) printf("no factory for %ls\n", class_name);
    WindowsDeleteString(name);
    return out;
}

static AsyncStatus wait_async(IUnknown *op)
{
    IAsyncInfo *info;
    AsyncStatus status = Started;
    int i;
    if (FAILED(IUnknown_QueryInterface(op, &IID_IAsyncInfo, (void **)&info))) return Error;
    for (i = 0; i < 1000 && SUCCEEDED(IAsyncInfo_get_Status(info, &status)) && status == Started; i++) Sleep(10);
    IAsyncInfo_Release(info);
    return status;
}

/* Prints one device and checks its basic properties; returns its id. */
static HSTRING show_device(IDeviceInformation *info, BOOL verbose)
{
    HSTRING id = NULL, name = NULL;
    boolean enabled = 2, is_default = 2;
    HRESULT hr;

    CHECK(IDeviceInformation_get_Id(info, &id) == S_OK && WindowsGetStringLen(id), "Id");
    hr = IDeviceInformation_get_Name(info, &name);
    CHECK(hr == S_OK && WindowsGetStringLen(name), "Name of %s (0x%08lx)", str(id), hr);
    CHECK(IDeviceInformation_get_IsEnabled(info, &enabled) == S_OK && enabled <= 1, "IsEnabled of %s", str(id));
    CHECK(IDeviceInformation_get_IsDefault(info, &is_default) == S_OK && is_default <= 1, "IsDefault of %s", str(id));
    if (verbose) printf("  %-40s %s%s%s\n", str(name), enabled == 1 ? "" : "[disabled] ", is_default == 1 ? "[default] " : "", str(id));
    WindowsDeleteString(name);
    return id;
}

/* Runs an async device query and returns its collection (or NULL). */
static IVectorView_DeviceInformation *collect(IAsyncOperation_DeviceInformationCollection *op)
{
    IVectorView_DeviceInformation *devices = NULL;
    if (!op) return NULL;
    CHECK(wait_async((IUnknown *)op) == Completed, "FindAllAsync completes");
    CHECK(IAsyncOperation_DeviceInformationCollection_GetResults(op, &devices) == S_OK && devices, "FindAllAsync results");
    IAsyncOperation_DeviceInformationCollection_Release(op);
    return devices;
}

static UINT32 show_collection(IVectorView_DeviceInformation *devices, UINT32 max, HSTRING *first_id)
{
    UINT32 count = 0, i;
    if (!devices) return 0;
    IVectorView_DeviceInformation_get_Size(devices, &count);
    for (i = 0; i < count; i++)
    {
        IDeviceInformation *info = NULL;
        HSTRING id;
        IVectorView_DeviceInformation_GetAt(devices, i, &info);
        if (!info) continue;
        id = show_device(info, i < max);
        if (first_id && !*first_id) *first_id = id;
        else WindowsDeleteString(id);
        IDeviceInformation_Release(info);
    }
    if (count > max) printf("  … and %u more\n", count - max);
    return count;
}

static HRESULT WINAPI handler_QueryInterface(ITypedEventHandler_DeviceWatcher_IInspectable *iface, REFIID iid, void **out)
{
    *out = iface;
    return S_OK;
}
static ULONG WINAPI handler_AddRef(ITypedEventHandler_DeviceWatcher_IInspectable *iface) { return 2; }
static ULONG WINAPI handler_Release(ITypedEventHandler_DeviceWatcher_IInspectable *iface) { return 1; }
static LONG completed;
static HRESULT WINAPI handler_Invoke(ITypedEventHandler_DeviceWatcher_IInspectable *iface, IDeviceWatcher *sender, IInspectable *args)
{
    InterlockedIncrement(&completed);
    return S_OK;
}
static ITypedEventHandler_DeviceWatcher_IInspectableVtbl handler_vtbl = { handler_QueryInterface, handler_AddRef, handler_Release, handler_Invoke };

int main(void)
{
    static const struct { DeviceClass cls; const char *name; } classes[] =
    {
        { DeviceClass_AudioCapture, "AudioCapture" },
        { DeviceClass_AudioRender, "AudioRender" },
        { DeviceClass_PortableStorageDevice, "PortableStorageDevice" },
        { DeviceClass_VideoCapture, "VideoCapture" },
        { DeviceClass_ImageScanner, "ImageScanner" },
        { DeviceClass_Location, "Location" },
    };
    IDeviceInformationStatics *statics;
    IDeviceInformationStatics2 *statics2 = NULL;
    IAsyncOperation_DeviceInformationCollection *op = NULL;
    IVectorView_DeviceInformation *devices;
    HSTRING first_id = NULL;
    UINT32 total, i;
    HRESULT hr;

    RoInitialize(RO_INIT_MULTITHREADED);
    statics = factory(L"Windows.Devices.Enumeration.DeviceInformation", &IID_IDeviceInformationStatics);
    if (!statics) return 1;
    IDeviceInformationStatics_QueryInterface(statics, &IID_IDeviceInformationStatics2, (void **)&statics2);
    CHECK(statics2 != NULL, "IDeviceInformationStatics2");

    printf("== All device interfaces\n");
    CHECK(IDeviceInformationStatics_FindAllAsync(statics, &op) == S_OK, "FindAllAsync");
    devices = collect(op);
    total = show_collection(devices, 15, &first_id);
    CHECK(total > 0, "devices found: %u", total);
    if (devices) IVectorView_DeviceInformation_Release(devices);

    for (i = 0; i < ARRAYSIZE(classes); i++)
    {
        HSTRING filter = NULL;
        op = NULL;
        printf("\n== DeviceClass %s\n", classes[i].name);
        if (statics2)
        {
            hr = IDeviceInformationStatics2_GetAqsFilterFromDeviceClass(statics2, classes[i].cls, &filter);
            CHECK(hr == S_OK && WindowsGetStringLen(filter), "GetAqsFilterFromDeviceClass(%s) 0x%08lx", classes[i].name, hr);
            printf("  AQS: %s\n", str(filter));
            WindowsDeleteString(filter);
        }
        hr = IDeviceInformationStatics_FindAllAsyncDeviceClass(statics, classes[i].cls, &op);
        CHECK(hr == S_OK, "FindAllAsync(%s) 0x%08lx", classes[i].name, hr);
        devices = collect(op);
        printf("  %u device(s)\n", show_collection(devices, 10, NULL));
        if (devices) IVectorView_DeviceInformation_Release(devices);
    }

    if (first_id)
    {
        IAsyncOperation_DeviceInformation *single = NULL;
        IDeviceInformation *info = NULL;
        printf("\n== CreateFromIdAsync(%s)\n", str(first_id));
        hr = IDeviceInformationStatics_CreateFromIdAsync(statics, first_id, &single);
        CHECK(hr == S_OK && single, "CreateFromIdAsync 0x%08lx", hr);
        if (single)
        {
            CHECK(wait_async((IUnknown *)single) == Completed, "CreateFromIdAsync completes");
            CHECK(IAsyncOperation_DeviceInformation_GetResults(single, &info) == S_OK && info, "CreateFromIdAsync result");
            if (info)
            {
                HSTRING id = show_device(info, TRUE);
                INT32 cmp = 1;
                WindowsCompareStringOrdinal(id, first_id, &cmp);
                CHECK(cmp == 0, "same id");
                WindowsDeleteString(id);
                IDeviceInformation_Release(info);
            }
            IAsyncOperation_DeviceInformation_Release(single);
        }
    }

    {
        IDeviceWatcher *watcher = NULL;
        ITypedEventHandler_DeviceWatcher_IInspectable handler = { &handler_vtbl };
        EventRegistrationToken t1 = {0}, t2 = {0}, t3 = {0};
        DeviceWatcherStatus status = -1;
        int w;
        printf("\n== DeviceWatcher\n");
        hr = IDeviceInformationStatics_CreateWatcher(statics, &watcher);
        CHECK(hr == S_OK && watcher, "CreateWatcher 0x%08lx", hr);
        if (watcher)
        {
            CHECK(IDeviceWatcher_get_Status(watcher, &status) == S_OK && status == DeviceWatcherStatus_Created, "status Created (%d)", status);
            CHECK(IDeviceWatcher_add_EnumerationCompleted(watcher, &handler, &t1) == S_OK, "add EnumerationCompleted");
            CHECK(IDeviceWatcher_add_Updated(watcher, (void *)&handler, &t2) == S_OK, "add Updated");
            CHECK(IDeviceWatcher_add_Removed(watcher, (void *)&handler, &t3) == S_OK, "add Removed");
            CHECK(IDeviceWatcher_Start(watcher) == S_OK, "Start");
            for (w = 0; w < 500 && !completed; w++) Sleep(10);
            CHECK(completed, "EnumerationCompleted fired");
            CHECK(IDeviceWatcher_get_Status(watcher, &status) == S_OK && status == DeviceWatcherStatus_EnumerationCompleted,
                  "status EnumerationCompleted (%d)", status);
            IDeviceWatcher_Stop(watcher);
            IDeviceWatcher_remove_Updated(watcher, t2);
            IDeviceWatcher_remove_Removed(watcher, t3);
            IDeviceWatcher_remove_EnumerationCompleted(watcher, t1);
            printf("  watcher ok, status %d\n", status);
            IDeviceWatcher_Release(watcher);
        }
    }

    {
        IDeviceAccessInformationStatics *access = factory(L"Windows.Devices.Enumeration.DeviceAccessInformation", &IID_IDeviceAccessInformationStatics);
        IDeviceAccessInformation *info = NULL;
        DeviceAccessStatus status = -1;
        if (access)
        {
            hr = IDeviceAccessInformationStatics_CreateFromDeviceClass(access, DeviceClass_AudioCapture, &info);
            CHECK(hr == S_OK && info, "DeviceAccessInformation.CreateFromDeviceClass 0x%08lx", hr);
            if (info)
            {
                CHECK(IDeviceAccessInformation_get_CurrentStatus(info, &status) == S_OK && status == DeviceAccessStatus_Allowed,
                      "CurrentStatus %d", status);
                printf("\n== DeviceAccessInformation(AudioCapture): status %d\n", status);
                IDeviceAccessInformation_Release(info);
            }
            IDeviceAccessInformationStatics_Release(access);
        }
    }

    {
        IMediaDeviceStatics *media = factory(L"Windows.Media.Devices.MediaDevice", &IID_IMediaDeviceStatics);
        HSTRING selector = NULL, default_id = NULL;
        if (media)
        {
            printf("\n== MediaDevice\n");
            hr = IMediaDeviceStatics_GetAudioRenderSelector(media, &selector);
            CHECK(hr == S_OK && WindowsGetStringLen(selector), "GetAudioRenderSelector 0x%08lx", hr);
            hr = IMediaDeviceStatics_GetDefaultAudioRenderId(media, AudioDeviceRole_Default, &default_id);
            CHECK(hr == S_OK && WindowsGetStringLen(default_id), "GetDefaultAudioRenderId 0x%08lx", hr);
            if (selector && default_id)
            {
                BOOL found = FALSE;
                UINT32 count = 0, k;
                op = NULL;
                IDeviceInformationStatics_FindAllAsyncAqsFilter(statics, selector, &op);
                devices = collect(op);
                if (devices) IVectorView_DeviceInformation_get_Size(devices, &count);
                for (k = 0; k < count; k++)
                {
                    IDeviceInformation *info = NULL;
                    HSTRING id = NULL;
                    boolean is_default = FALSE;
                    IVectorView_DeviceInformation_GetAt(devices, k, &info);
                    if (!info) continue;
                    IDeviceInformation_get_Id(info, &id);
                    IDeviceInformation_get_IsDefault(info, &is_default);
                    if (!_wcsicmp(WindowsGetStringRawBuffer(id, NULL), WindowsGetStringRawBuffer(default_id, NULL)))
                    {
                        found = TRUE;
                        CHECK(is_default, "default render device is marked IsDefault");
                    }
                    WindowsDeleteString(id);
                    IDeviceInformation_Release(info);
                }
                CHECK(count >= 1, "render selector finds %u device(s)", count);
                CHECK(found, "default render id %s is among them", str(default_id));
                printf("  selector finds %u render device(s), default %s\n", count, found ? "found" : "MISSING");
                if (devices) IVectorView_DeviceInformation_Release(devices);
            }
            WindowsDeleteString(selector);
            WindowsDeleteString(default_id);
            IMediaDeviceStatics_Release(media);
        }
    }

    WindowsDeleteString(first_id);
    if (statics2) IDeviceInformationStatics2_Release(statics2);
    IDeviceInformationStatics_Release(statics);
    RoUninitialize();
    printf("\n%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
