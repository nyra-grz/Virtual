/* Checks Windows.Networking.Connectivity and Windows.Networking.HostName through the
 * public WinRT activation API, prints what it finds and exits with 1 on any failure.
 *
 *   x86_64-w64-mingw32-gcc winrt/tests/network.c -o build/network.exe -lruntimeobject -lole32 -luuid
 *   runtime/bin/virtual build/network.exe
 */
#define COBJMACROS
#define INITGUID
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Networking
#define WIDL_using_Windows_Networking_Connectivity
#include <stdio.h>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <activation.h>
#include <windows.foundation.h>
#include <windows.networking.connectivity.h>

static int failures, checks;
static const GUID null_guid;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    printf("FAIL line %d: %s – ", __LINE__, #cond); printf(__VA_ARGS__); printf("\n"); } } while (0)

static const char *str(HSTRING s)
{
    static char buf[4][512];
    static int n;
    char *out = buf[n++ % 4];
    UINT32 len;
    const WCHAR *w = WindowsGetStringRawBuffer(s, &len);
    out[len < 511 ? WideCharToMultiByte(CP_UTF8, 0, w, len, out, 511, NULL, NULL) : 511] = 0;
    return out;
}

static HSTRING hs(const WCHAR *w)
{
    HSTRING s = NULL;
    WindowsCreateString(w, wcslen(w), &s);
    return s;
}

static void *factory(const WCHAR *class_name, REFIID iid)
{
    HSTRING name = hs(class_name);
    void *out = NULL;
    HRESULT hr = RoGetActivationFactory(name, iid, &out);
    WindowsDeleteString(name);
    if (FAILED(hr)) printf("RoGetActivationFactory(%ls) failed: 0x%08lx\n", class_name, hr);
    return out;
}

/* Waits for an IAsyncOperation by polling IAsyncInfo; returns its status. */
static AsyncStatus wait_async(IUnknown *op)
{
    IAsyncInfo *info;
    AsyncStatus status = Started;
    int i;
    if (FAILED(IUnknown_QueryInterface(op, &IID_IAsyncInfo, (void **)&info))) return Error;
    for (i = 0; i < 500 && SUCCEEDED(IAsyncInfo_get_Status(info, &status)) && status == Started; i++) Sleep(10);
    IAsyncInfo_Release(info);
    return status;
}

static void guid_str(const GUID *g, char *out)
{
    sprintf(out, "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}", g->Data1, g->Data2, g->Data3,
            g->Data4[0], g->Data4[1], g->Data4[2], g->Data4[3], g->Data4[4], g->Data4[5], g->Data4[6], g->Data4[7]);
}

static void test_hostname(void)
{
    static const struct { const WCHAR *raw; HostNameType type; const char *canonical; } tests[] =
    {
        { L"WWW.Example.COM", HostNameType_DomainName, "www.example.com" },
        { L"localhost",       HostNameType_DomainName, "localhost" },
        { L"192.168.1.10",    HostNameType_Ipv4,       "192.168.1.10" },
        { L"::1",             HostNameType_Ipv6,       "::1" },
        { L"FE80::1",         HostNameType_Ipv6,       "fe80::1" },
        { L"2001:DB8:0:0:0:0:0:1", HostNameType_Ipv6,  "2001:db8::1" },
    };
    IHostNameFactory *hf = factory(L"Windows.Networking.HostName", &IID_IHostNameFactory);
    IHostNameStatics *hstat = factory(L"Windows.Networking.HostName", &IID_IHostNameStatics);
    unsigned i;

    printf("\n== HostName\n");
    if (!hf) { CHECK(0, "no IHostNameFactory"); return; }
    for (i = 0; i < ARRAYSIZE(tests); i++)
    {
        HSTRING raw = hs(tests[i].raw), canonical = NULL, display = NULL, raw_out = NULL;
        IHostName *name = NULL, *other = NULL;
        IIPInformation *ip = (IIPInformation *)1;
        HostNameType type = -1;
        boolean equal = FALSE;
        HRESULT hr = IHostNameFactory_CreateHostName(hf, raw, &name);
        CHECK(hr == S_OK && name, "CreateHostName(%ls) 0x%08lx", tests[i].raw, hr);
        if (!name) { WindowsDeleteString(raw); continue; }
        CHECK(IHostName_get_Type(name, &type) == S_OK && type == tests[i].type, "%ls: type %d", tests[i].raw, type);
        CHECK(IHostName_get_RawName(name, &raw_out) == S_OK && !wcscmp(WindowsGetStringRawBuffer(raw_out, NULL), tests[i].raw),
              "%ls: RawName %s", tests[i].raw, str(raw_out));
        CHECK(IHostName_get_CanonicalName(name, &canonical) == S_OK && !strcmp(str(canonical), tests[i].canonical),
              "%ls: CanonicalName %s", tests[i].raw, str(canonical));
        CHECK(IHostName_get_DisplayName(name, &display) == S_OK && WindowsGetStringLen(display),
              "%ls: DisplayName %s", tests[i].raw, str(display));
        CHECK(IHostName_get_IPInformation(name, &ip) == S_OK && !ip, "%ls: own HostName has no IPInformation", tests[i].raw);
        IHostNameFactory_CreateHostName(hf, canonical, &other);
        CHECK(other && IHostName_IsEqual(name, other, &equal) == S_OK && equal, "%ls: IsEqual(canonical)", tests[i].raw);
        printf("  %-24ls type %d, canonical %s, display %s\n", tests[i].raw, type, str(canonical), str(display));
        if (other) IHostName_Release(other);
        IHostName_Release(name);
        WindowsDeleteString(raw); WindowsDeleteString(raw_out); WindowsDeleteString(canonical); WindowsDeleteString(display);
    }
    if (hstat)
    {
        HSTRING a = hs(L"Example.com"), b = hs(L"example.COM"), c = hs(L"zzz.example");
        INT32 r = 99;
        CHECK(IHostNameStatics_Compare(hstat, a, b, &r) == S_OK && r == 0, "Compare equal -> %d", r);
        CHECK(IHostNameStatics_Compare(hstat, a, c, &r) == S_OK && r < 0, "Compare less -> %d", r);
        WindowsDeleteString(a); WindowsDeleteString(b); WindowsDeleteString(c);
        IHostNameStatics_Release(hstat);
    }
    else CHECK(0, "no IHostNameStatics");
    IHostNameFactory_Release(hf);
}

/* Prints a profile and checks it; returns the IANA interface type (0 if unknown). */
static UINT32 test_profile(IConnectionProfile *profile, const char *label, GUID *adapter_id)
{
    HSTRING name = NULL;
    NetworkConnectivityLevel level = -1;
    IVectorView_HSTRING *names = NULL;
    IConnectionCost *cost = NULL;
    IDataPlanStatus *plan = NULL;
    INetworkAdapter *adapter = NULL;
    INetworkItem *item = NULL;
    INetworkSecuritySettings *security = NULL;
    IConnectionProfile2 *profile2 = NULL;
    IReference_UINT32 *limit = (IReference_UINT32 *)1;
    UINT32 iana = 0, count = 0;
    UINT64 in_bps = 0, out_bps = 0;
    GUID network_id = {0};
    NetworkTypes types = 0;
    char id[64], net[64];

    printf("\n== %s\n", label);
    CHECK(IConnectionProfile_get_ProfileName(profile, &name) == S_OK && WindowsGetStringLen(name), "ProfileName");
    CHECK(IConnectionProfile_GetNetworkConnectivityLevel(profile, &level) == S_OK && level <= NetworkConnectivityLevel_InternetAccess, "level %d", level);
    printf("  ProfileName %s, ConnectivityLevel %d\n", str(name), level);

    CHECK(IConnectionProfile_GetNetworkNames(profile, &names) == S_OK && names, "GetNetworkNames");
    if (names)
    {
        HSTRING first = NULL;
        IVectorView_HSTRING_get_Size(names, &count);
        CHECK(count >= 1 && IVectorView_HSTRING_GetAt(names, 0, &first) == S_OK && !strcmp(str(first), str(name)),
              "NetworkNames[0] == ProfileName (%u)", count);
        WindowsDeleteString(first);
        IVectorView_HSTRING_Release(names);
    }

    CHECK(IConnectionProfile_GetConnectionCost(profile, &cost) == S_OK && cost, "GetConnectionCost");
    if (cost)
    {
        NetworkCostType ct = -1;
        boolean roaming = 2, over = 2, approaching = 2;
        IConnectionCost_get_NetworkCostType(cost, &ct);
        IConnectionCost_get_Roaming(cost, &roaming);
        IConnectionCost_get_OverDataLimit(cost, &over);
        IConnectionCost_get_ApproachingDataLimit(cost, &approaching);
        CHECK(ct <= NetworkCostType_Variable && roaming <= 1 && over <= 1 && approaching <= 1, "cost values");
        printf("  Cost type %d, roaming %d, over %d, approaching %d\n", ct, roaming, over, approaching);
        IConnectionCost_Release(cost);
    }

    CHECK(IConnectionProfile_GetDataPlanStatus(profile, &plan) == S_OK && plan, "GetDataPlanStatus");
    if (plan)
    {
        CHECK(IDataPlanStatus_get_DataLimitInMegabytes(plan, &limit) == S_OK && !limit, "no data limit");
        IDataPlanStatus_Release(plan);
    }

    CHECK(IConnectionProfile_get_NetworkAdapter(profile, &adapter) == S_OK && adapter, "NetworkAdapter");
    if (adapter)
    {
        INetworkAdapter_get_IanaInterfaceType(adapter, &iana);
        INetworkAdapter_get_InboundMaxBitsPerSecond(adapter, &in_bps);
        INetworkAdapter_get_OutboundMaxBitsPerSecond(adapter, &out_bps);
        CHECK(INetworkAdapter_get_NetworkAdapterId(adapter, adapter_id) == S_OK && !IsEqualGUID(adapter_id, &null_guid), "NetworkAdapterId");
        CHECK(iana != 0 && iana != 24, "IanaInterfaceType %u", iana);
        CHECK(INetworkAdapter_get_NetworkItem(adapter, &item) == S_OK && item, "NetworkItem");
        if (item)
        {
            CHECK(INetworkItem_get_NetworkId(item, &network_id) == S_OK && !IsEqualGUID(&network_id, &null_guid), "NetworkId");
            CHECK(INetworkItem_GetNetworkTypes(item, &types) == S_OK, "GetNetworkTypes");
            INetworkItem_Release(item);
        }
        guid_str(adapter_id, id); guid_str(&network_id, net);
        printf("  Adapter %s, IANA type %u, %llu/%llu bit/s, network %s, types 0x%x\n",
               id, iana, (unsigned long long)in_bps, (unsigned long long)out_bps, net, types);
        {
            IAsyncOperation_ConnectionProfile *op = NULL;
            IConnectionProfile *connected = NULL;
            CHECK(INetworkAdapter_GetConnectedProfileAsync(adapter, &op) == S_OK && op, "GetConnectedProfileAsync");
            if (op)
            {
                CHECK(wait_async((IUnknown *)op) == Completed, "GetConnectedProfileAsync completes");
                CHECK(IAsyncOperation_ConnectionProfile_GetResults(op, &connected) == S_OK && connected, "connected profile");
                if (connected) IConnectionProfile_Release(connected);
                IAsyncOperation_ConnectionProfile_Release(op);
            }
        }
        INetworkAdapter_Release(adapter);
    }

    CHECK(IConnectionProfile_get_NetworkSecuritySettings(profile, &security) == S_OK && security, "NetworkSecuritySettings");
    if (security)
    {
        NetworkAuthenticationType auth = -1;
        NetworkEncryptionType enc = -1;
        INetworkSecuritySettings_get_NetworkAuthenticationType(security, &auth);
        INetworkSecuritySettings_get_NetworkEncryptionType(security, &enc);
        printf("  Security auth %d, encryption %d\n", auth, enc);
        INetworkSecuritySettings_Release(security);
    }

    if (SUCCEEDED(IConnectionProfile_QueryInterface(profile, &IID_IConnectionProfile2, (void **)&profile2)))
    {
        boolean wlan = 2, wwan = 2;
        DomainConnectivityLevel domain = -1;
        IWlanConnectionProfileDetails *wlan_details = NULL;
        IConnectionProfile2_get_IsWlanConnectionProfile(profile2, &wlan);
        IConnectionProfile2_get_IsWwanConnectionProfile(profile2, &wwan);
        CHECK(wlan == (iana == 71), "IsWlan %d matches IANA type %u", wlan, iana);
        CHECK(wwan == FALSE, "IsWwan %d", wwan);
        CHECK(IConnectionProfile2_GetDomainConnectivityLevel(profile2, &domain) == S_OK && domain == DomainConnectivityLevel_None,
              "domain level %d", domain);
        if (wlan)
        {
            HSTRING ssid = NULL;
            CHECK(IConnectionProfile2_get_WlanConnectionProfileDetails(profile2, &wlan_details) == S_OK && wlan_details, "WlanDetails");
            if (wlan_details)
            {
                CHECK(IWlanConnectionProfileDetails_GetConnectedSsid(wlan_details, &ssid) == S_OK, "GetConnectedSsid");
                printf("  WLAN, SSID \"%s\"\n", str(ssid));
                WindowsDeleteString(ssid);
                IWlanConnectionProfileDetails_Release(wlan_details);
            }
        }
        IConnectionProfile2_Release(profile2);
    }
    else CHECK(0, "IConnectionProfile2 missing");
    WindowsDeleteString(name);
    return iana;
}

static void __stdcall dummy(void) {}

static HRESULT WINAPI handler_QueryInterface(INetworkStatusChangedEventHandler *iface, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_INetworkStatusChangedEventHandler))
    {
        *out = iface;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI handler_AddRef(INetworkStatusChangedEventHandler *iface) { return 2; }
static ULONG WINAPI handler_Release(INetworkStatusChangedEventHandler *iface) { return 1; }
static HRESULT WINAPI handler_Invoke(INetworkStatusChangedEventHandler *iface, IInspectable *sender) { return S_OK; }
static INetworkStatusChangedEventHandlerVtbl handler_vtbl = { handler_QueryInterface, handler_AddRef, handler_Release, handler_Invoke };

int main(void)
{
    INetworkInformationStatics *statics;
    IConnectionProfile *internet = NULL;
    IVectorView_ConnectionProfile *profiles = NULL;
    IVectorView_HostName *hostnames = NULL;
    IVectorView_LanIdentifier *lans = NULL;
    INetworkStatusChangedEventHandler handler = { &handler_vtbl };
    EventRegistrationToken t1 = {0}, t2 = {0};
    GUID internet_adapter = {0};
    UINT32 count = 0, i;
    HRESULT hr;

    (void)dummy;
    RoInitialize(RO_INIT_MULTITHREADED);
    test_hostname();

    statics = factory(L"Windows.Networking.Connectivity.NetworkInformation", &IID_INetworkInformationStatics);
    if (!statics) return 1;

    hr = INetworkInformationStatics_GetInternetConnectionProfile(statics, &internet);
    CHECK(hr == S_OK, "GetInternetConnectionProfile 0x%08lx", hr);
    if (internet) test_profile(internet, "Internet connection profile", &internet_adapter);
    else printf("\n(offline: no internet profile)\n");

    hr = INetworkInformationStatics_GetConnectionProfiles(statics, &profiles);
    CHECK(hr == S_OK && profiles, "GetConnectionProfiles 0x%08lx", hr);
    if (profiles)
    {
        BOOL found = !internet;
        IVectorView_ConnectionProfile_get_Size(profiles, &count);
        CHECK(count >= (internet ? 1u : 0u), "profile count %u", count);
        for (i = 0; i < count; i++)
        {
            IConnectionProfile *p = NULL;
            GUID id;
            char label[64];
            if (FAILED(IVectorView_ConnectionProfile_GetAt(profiles, i, &p)) || !p) { CHECK(0, "GetAt(%u)", i); continue; }
            sprintf(label, "Connection profile %u of %u", i + 1, count);
            test_profile(p, label, &id);
            if (IsEqualGUID(&id, &internet_adapter)) found = TRUE;
            IConnectionProfile_Release(p);
        }
        CHECK(found, "internet profile is among GetConnectionProfiles");
        IVectorView_ConnectionProfile_Release(profiles);
    }

    printf("\n== Host names\n");
    hr = INetworkInformationStatics_GetHostNames(statics, &hostnames);
    CHECK(hr == S_OK && hostnames, "GetHostNames 0x%08lx", hr);
    if (hostnames)
    {
        BOOL have_domain = FALSE, have_ip_info = FALSE;
        IVectorView_HostName_get_Size(hostnames, &count);
        CHECK(count >= 1, "host name count %u", count);
        for (i = 0; i < count; i++)
        {
            IHostName *h = NULL;
            HSTRING raw = NULL;
            HostNameType type = -1;
            IIPInformation *ip = NULL;
            IVectorView_HostName_GetAt(hostnames, i, &h);
            if (!h) continue;
            IHostName_get_RawName(h, &raw);
            IHostName_get_Type(h, &type);
            IHostName_get_IPInformation(h, &ip);
            if (type == HostNameType_DomainName) have_domain = TRUE;
            if (ip)
            {
                IReference_BYTE *prefix = NULL;
                INetworkAdapter *a = NULL;
                BYTE len = 0;
                IIPInformation_get_PrefixLength(ip, &prefix);
                if (prefix) { IReference_BYTE_get_Value(prefix, &len); IReference_BYTE_Release(prefix); }
                CHECK(IIPInformation_get_NetworkAdapter(ip, &a) == S_OK && a, "IPInformation adapter");
                if (a) INetworkAdapter_Release(a);
                CHECK(type != HostNameType_DomainName && len > 0, "prefix length %u for %s", len, str(raw));
                have_ip_info = TRUE;
                printf("  %-40s type %d, /%u\n", str(raw), type, len);
                IIPInformation_Release(ip);
            }
            else printf("  %-40s type %d\n", str(raw), type);
            WindowsDeleteString(raw);
            IHostName_Release(h);
        }
        CHECK(have_domain, "a DomainName host name");
        CHECK(have_ip_info || !internet, "an address with IPInformation");
        IVectorView_HostName_Release(hostnames);
    }

    hr = INetworkInformationStatics_GetLanIdentifiers(statics, &lans);
    CHECK(hr == S_OK && lans, "GetLanIdentifiers 0x%08lx", hr);
    if (lans) IVectorView_LanIdentifier_Release(lans);

    {
        IUriRuntimeClassFactory *uf = factory(L"Windows.Foundation.Uri", &IID_IUriRuntimeClassFactory);
        IUriRuntimeClass *uri = NULL;
        IAsyncOperation_ProxyConfiguration *op = NULL;
        IProxyConfiguration *proxy = NULL;
        HSTRING s = hs(L"https://www.winehq.org/");
        if (uf) IUriRuntimeClassFactory_CreateUri(uf, s, &uri);
        CHECK(uri != NULL, "create Uri");
        hr = INetworkInformationStatics_GetProxyConfigurationAsync(statics, uri, &op);
        CHECK(hr == S_OK && op, "GetProxyConfigurationAsync 0x%08lx", hr);
        if (op)
        {
            boolean direct = 2;
            CHECK(wait_async((IUnknown *)op) == Completed, "proxy configuration completes");
            CHECK(IAsyncOperation_ProxyConfiguration_GetResults(op, &proxy) == S_OK && proxy, "proxy result");
            if (proxy)
            {
                IProxyConfiguration_get_CanConnectDirectly(proxy, &direct);
                printf("\n== Proxy: CanConnectDirectly %d\n", direct);
                IProxyConfiguration_Release(proxy);
            }
            IAsyncOperation_ProxyConfiguration_Release(op);
        }
        if (uri) IUriRuntimeClass_Release(uri);
        if (uf) IUriRuntimeClassFactory_Release(uf);
        WindowsDeleteString(s);
    }

    CHECK(INetworkInformationStatics_add_NetworkStatusChanged(statics, &handler, &t1) == S_OK, "add NetworkStatusChanged");
    CHECK(INetworkInformationStatics_add_NetworkStatusChanged(statics, &handler, &t2) == S_OK && t1.value != t2.value,
          "distinct event tokens");
    CHECK(INetworkInformationStatics_remove_NetworkStatusChanged(statics, t1) == S_OK, "remove NetworkStatusChanged");
    CHECK(INetworkInformationStatics_remove_NetworkStatusChanged(statics, t2) == S_OK, "remove second handler");

    if (internet) IConnectionProfile_Release(internet);
    INetworkInformationStatics_Release(statics);
    RoUninitialize();
    printf("\n%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
