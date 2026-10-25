/* Checks Windows.Devices.WiFi through the public WinRT activation API: access, adapter,
 * its NetworkAdapter, the network report, a scan with the AvailableNetworksChanged event,
 * and DeviceInformation/FromIdAsync. Connection changes require --change-network. Prints what it finds and exits with 1 on any failure.
 * MinGW has no windows.devices.wifi.h, so the few interfaces are declared here.
 *
 *   x86_64-w64-mingw32-gcc winrt/tests/wifi.c -o build/wifi.exe -lruntimeobject -lole32
 *   runtime/bin/virtual build/wifi.exe
 */
#define COBJMACROS
#define INITGUID
#include <stdio.h>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <inspectable.h>
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Devices_Enumeration
#include <windows.foundation.h>
#include <windows.devices.enumeration.h>

static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    printf("FAIL line %d: %s – ", __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const GUID IID_IWiFiAdapterStatics = {0xda25fddd, 0xd24c, 0x43e3, {0xaa, 0xbd, 0xc4, 0x65, 0x9f, 0x73, 0x0f, 0x99}};
static const GUID IID_IAsyncInfo_ = {0x00000036, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

typedef struct { INT64 v; } I64;
#define INSPECTABLE_METHODS(T) \
    HRESULT (WINAPI *QueryInterface)(T *, REFIID, void **); ULONG (WINAPI *AddRef)(T *); ULONG (WINAPI *Release)(T *); \
    HRESULT (WINAPI *GetIids)(T *, ULONG *, IID **); HRESULT (WINAPI *GetRuntimeClassName)(T *, HSTRING *); \
    HRESULT (WINAPI *GetTrustLevel)(T *, int *)
#define DECLARE(T, ...) typedef struct T T; struct T { const struct { INSPECTABLE_METHODS(T); __VA_ARGS__; } *v; }

DECLARE(Obj, void *dummy);
DECLARE(AsyncInfo, HRESULT (WINAPI *get_Id)(AsyncInfo *, UINT32 *); HRESULT (WINAPI *get_Status)(AsyncInfo *, int *);
        HRESULT (WINAPI *get_ErrorCode)(AsyncInfo *, HRESULT *));
DECLARE(AsyncOp, HRESULT (WINAPI *put_Completed)(AsyncOp *, void *); HRESULT (WINAPI *get_Completed)(AsyncOp *, void **);
        HRESULT (WINAPI *GetResults)(AsyncOp *, void *));
DECLARE(VectorView, HRESULT (WINAPI *GetAt)(VectorView *, UINT32, Obj **); HRESULT (WINAPI *get_Size)(VectorView *, UINT32 *));
DECLARE(Statics, HRESULT (WINAPI *FindAllAdaptersAsync)(Statics *, AsyncOp **); HRESULT (WINAPI *GetDeviceSelector)(Statics *, HSTRING *);
        HRESULT (WINAPI *FromIdAsync)(Statics *, HSTRING, AsyncOp **); HRESULT (WINAPI *RequestAccessAsync)(Statics *, AsyncOp **));
DECLARE(Adapter, HRESULT (WINAPI *get_NetworkAdapter)(Adapter *, Obj **); HRESULT (WINAPI *ScanAsync)(Adapter *, AsyncOp **);
        HRESULT (WINAPI *get_NetworkReport)(Adapter *, Obj **); HRESULT (WINAPI *add_Changed)(Adapter *, void *, I64 *);
        HRESULT (WINAPI *remove_Changed)(Adapter *, I64); HRESULT (WINAPI *ConnectAsync)(Adapter *, Obj *, int, AsyncOp **);
        void *c2; void *c3; HRESULT (WINAPI *Disconnect)(Adapter *));
DECLARE(Report, HRESULT (WINAPI *get_Timestamp)(Report *, INT64 *); HRESULT (WINAPI *get_AvailableNetworks)(Report *, VectorView **));
DECLARE(Network, HRESULT (WINAPI *get_Uptime)(Network *, INT64 *); HRESULT (WINAPI *get_Ssid)(Network *, HSTRING *);
        HRESULT (WINAPI *get_Bssid)(Network *, HSTRING *); HRESULT (WINAPI *get_Frequency)(Network *, INT32 *);
        HRESULT (WINAPI *get_Rssi)(Network *, double *); HRESULT (WINAPI *get_SignalBars)(Network *, BYTE *);
        HRESULT (WINAPI *get_NetworkKind)(Network *, int *); HRESULT (WINAPI *get_PhyKind)(Network *, int *);
        HRESULT (WINAPI *get_SecuritySettings)(Network *, Obj **); HRESULT (WINAPI *get_BeaconInterval)(Network *, INT64 *);
        HRESULT (WINAPI *get_IsWiFiDirect)(Network *, boolean *));
DECLARE(Security, HRESULT (WINAPI *get_Auth)(Security *, int *); HRESULT (WINAPI *get_Encryption)(Security *, int *));
DECLARE(NetAdapter, HRESULT (WINAPI *get_OutboundMaxBitsPerSecond)(NetAdapter *, UINT64 *);
        HRESULT (WINAPI *get_InboundMaxBitsPerSecond)(NetAdapter *, UINT64 *); HRESULT (WINAPI *get_IanaInterfaceType)(NetAdapter *, UINT32 *));
DECLARE(ConnResult, HRESULT (WINAPI *get_ConnectionStatus)(ConnResult *, int *));

/* TypedEventHandler<WiFiAdapter, IInspectable>; the IID is only checked loosely. */
typedef struct { const struct { HRESULT (WINAPI *QueryInterface)(void *, REFIID, void **); ULONG (WINAPI *AddRef)(void *);
                 ULONG (WINAPI *Release)(void *); HRESULT (WINAPI *Invoke)(void *, Adapter *, IInspectable *); } *v; LONG calls; } Handler;
static HRESULT WINAPI h_QI(void *iface, REFIID iid, void **out) { *out = iface; return S_OK; }
static ULONG WINAPI h_AddRef(void *iface) { return 2; }
static ULONG WINAPI h_Release(void *iface) { return 1; }
static HRESULT WINAPI h_Invoke(void *iface, Adapter *sender, IInspectable *args) { InterlockedIncrement(&((Handler *)iface)->calls); return S_OK; }
static const struct { void *a, *b, *c, *d; } handler_vtbl = { h_QI, h_AddRef, h_Release, h_Invoke };

static int wait(AsyncOp *op)
{
    AsyncInfo *info;
    int status = 0, i;
    if (FAILED(op->v->QueryInterface(op, &IID_IAsyncInfo_, (void **)&info))) return -1;
    for (i = 0; i < 300 && SUCCEEDED(info->v->get_Status(info, &status)) && status == 0; i++) Sleep(50);
    info->v->Release(info);
    return status; /* 1 = Completed */
}

static const char *str(HSTRING s)
{
    static char buf[4][256];
    static int n;
    char *b = buf[n++ % 4];
    WideCharToMultiByte(CP_UTF8, 0, WindowsGetStringRawBuffer(s, NULL), -1, b, 256, NULL, NULL);
    return b;
}

int main(int argc, char **argv)
{
    static const WCHAR name[] = L"Windows.Devices.WiFi.WiFiAdapter";
    Handler handler = { (void *)&handler_vtbl };
    HSTRING class_name, selector, ssid, bssid;
    Statics *statics;
    AsyncOp *op;
    VectorView *adapters, *networks;
    Adapter *adapter;
    Report *report;
    Obj *obj;
    UINT32 count = 0, i;
    INT64 stamp;
    I64 token;
    int access = -1, status;
    HRESULT hr;
    UINT32 direct_count, enumerated_count = 0;
    BOOL change_network = argc == 2 && !strcmp(argv[1], "--change-network");

    RoInitialize(RO_INIT_MULTITHREADED);
    WindowsCreateString(name, ARRAYSIZE(name) - 1, &class_name);
    hr = RoGetActivationFactory(class_name, &IID_IWiFiAdapterStatics, (void **)&statics);
    CHECK(hr == S_OK, "RoGetActivationFactory %#lx", hr);
    if (FAILED(hr)) return 1;

    hr = statics->v->GetDeviceSelector(statics, &selector);
    CHECK(hr == S_OK && WindowsGetStringLen(selector), "GetDeviceSelector %#lx", hr);
    printf("selector: %s\n", str(selector));

    hr = statics->v->RequestAccessAsync(statics, &op);
    CHECK(hr == S_OK && wait(op) == 1, "RequestAccessAsync %#lx", hr);
    op->v->GetResults(op, &access);
    CHECK(access == 1, "access %d", access);
    op->v->Release(op);

    hr = statics->v->FindAllAdaptersAsync(statics, &op);
    CHECK(hr == S_OK && wait(op) == 1, "FindAllAdaptersAsync %#lx", hr);
    hr = op->v->GetResults(op, &adapters);
    CHECK(hr == S_OK && adapters, "GetResults %#lx", hr);
    op->v->Release(op);
    adapters->v->get_Size(adapters, &count);
    direct_count = count;
    printf("adapters: %u\n", count);
    {
        HSTRING device_class;
        IDeviceInformationStatics *devices = NULL;
        IAsyncOperation_DeviceInformationCollection *query = NULL;
        IVectorView_DeviceInformation *view = NULL;
        WindowsCreateString(L"Windows.Devices.Enumeration.DeviceInformation", 45, &device_class);
        hr = RoGetActivationFactory(device_class, &IID_IDeviceInformationStatics, (void **)&devices);
        WindowsDeleteString(device_class);
        CHECK(hr == S_OK && devices, "DeviceInformation factory %#lx", hr);
        if (devices) {
            hr = IDeviceInformationStatics_FindAllAsyncAqsFilter(devices, selector, &query);
            CHECK(hr == S_OK && query && wait((AsyncOp *)query) == 1, "DeviceInformation.FindAllAsync %#lx", hr);
            if (query) {
                hr = IAsyncOperation_DeviceInformationCollection_GetResults(query, &view);
                CHECK(hr == S_OK && view, "DeviceInformation results %#lx", hr);
                IAsyncOperation_DeviceInformationCollection_Release(query);
            }
            if (view) {
                IVectorView_DeviceInformation_get_Size(view, &enumerated_count);
                CHECK(enumerated_count == direct_count, "DeviceInformation count %u, direct %u", enumerated_count, direct_count);
                for (i = 0; i < enumerated_count; i++) {
                    IDeviceInformation *device = NULL;
                    HSTRING id = NULL, device_name = NULL;
                    Adapter *from_id = NULL;
                    boolean enabled = FALSE;
                    IVectorView_DeviceInformation_GetAt(view, i, &device);
                    IDeviceInformation_get_Id(device, &id);
                    IDeviceInformation_get_Name(device, &device_name);
                    IDeviceInformation_get_IsEnabled(device, &enabled);
                    CHECK(enabled && WindowsGetStringLen(device_name), "enabled adapter with name");
                    hr = statics->v->FromIdAsync(statics, id, &op);
                    CHECK(hr == S_OK && wait(op) == 1, "FromIdAsync %#lx", hr);
                    hr = op->v->GetResults(op, &from_id);
                    CHECK(hr == S_OK && from_id, "FromIdAsync adapter %#lx", hr);
                    if (from_id) from_id->v->Release(from_id);
                    op->v->Release(op);
                    WindowsDeleteString(id);
                    WindowsDeleteString(device_name);
                    IDeviceInformation_Release(device);
                }
                IVectorView_DeviceInformation_Release(view);
            }
            IDeviceInformationStatics_Release(devices);
        }
    }
    if (!count) { printf("no Wi-Fi adapter on this machine\n"); return failures ? 1 : 0; }

    adapters->v->GetAt(adapters, 0, (Obj **)&adapter);
    hr = adapter->v->get_NetworkAdapter(adapter, &obj);
    CHECK(hr == S_OK && obj, "get_NetworkAdapter %#lx %p", hr, obj);
    if (obj)
    {
        UINT32 type = 0;
        ((NetAdapter *)obj)->v->get_IanaInterfaceType((NetAdapter *)obj, &type);
        CHECK(type == 71, "IanaInterfaceType %u", type);
        obj->v->Release(obj);
    }

    hr = adapter->v->get_NetworkReport(adapter, (Obj **)&report);
    CHECK(hr == S_OK, "get_NetworkReport %#lx", hr);
    report->v->get_Timestamp(report, &stamp);
    CHECK(stamp > 0, "timestamp %lld", stamp);
    report->v->get_AvailableNetworks(report, &networks);
    networks->v->get_Size(networks, &count);
    printf("networks before scan: %u\n", count);
    report->v->Release(report);

    hr = adapter->v->add_Changed(adapter, &handler, &token);
    CHECK(hr == S_OK, "add_AvailableNetworksChanged %#lx", hr);
    hr = adapter->v->ScanAsync(adapter, &op);
    CHECK(hr == S_OK, "ScanAsync %#lx", hr);
    status = wait(op);
    CHECK(status == 1, "scan status %d", status);
    op->v->Release(op);
    CHECK(handler.calls == 1, "AvailableNetworksChanged calls %ld", handler.calls);
    adapter->v->remove_Changed(adapter, token);

    adapter->v->get_NetworkReport(adapter, (Obj **)&report);
    report->v->get_AvailableNetworks(report, &networks);
    networks->v->get_Size(networks, &count);
    printf("networks after scan: %u\n", count);
    for (i = 0; i < count; i++)
    {
        Network *net;
        Security *sec;
        INT32 freq = 0;
        double rssi = 0;
        BYTE bars = 0;
        int kind = 0, phy = 0, auth = -1, enc = -1;

        networks->v->GetAt(networks, i, (Obj **)&net);
        net->v->get_Ssid(net, &ssid);
        net->v->get_Bssid(net, &bssid);
        net->v->get_Frequency(net, &freq);
        net->v->get_Rssi(net, &rssi);
        net->v->get_SignalBars(net, &bars);
        net->v->get_NetworkKind(net, &kind);
        net->v->get_PhyKind(net, &phy);
        net->v->get_SecuritySettings(net, (Obj **)&sec);
        sec->v->get_Auth(sec, &auth);
        sec->v->get_Encryption(sec, &enc);
        sec->v->Release(sec);
        if (i < 8) printf("  %-20s %-17s %7d kHz %5.0f dBm %u bars kind %d phy %d auth %d enc %d\n",
                          WindowsGetStringLen(ssid) ? str(ssid) : "(verborgen)", str(bssid), freq, rssi, bars, kind, phy, auth, enc);
        CHECK(rssi < 0 && rssi > -120, "rssi %f", rssi);
        CHECK(kind == 1 || kind == 2, "kind %d", kind);
        if (change_network && i == 0)
        {
            ConnResult *result;
            int conn = -1;
            hr = adapter->v->ConnectAsync(adapter, (Obj *)net, 0, &op);
            CHECK(hr == S_OK && wait(op) == 1, "ConnectAsync %#lx", hr);
            op->v->GetResults(op, &result);
            result->v->get_ConnectionStatus(result, &conn);
            printf("  connect to first network: status %d\n", conn);
            result->v->Release(result);
            op->v->Release(op);
        }
        net->v->Release(net);
    }
    if (change_network) CHECK(adapter->v->Disconnect(adapter) == S_OK, "Disconnect");

    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
