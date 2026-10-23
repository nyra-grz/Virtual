/* Builtin WinRT stub; see winrt/README.md for Wine integration. */
#define COBJMACROS
#define CONST_VTABLE
#define INITGUID
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Networking
#define WIDL_using_Windows_Networking_Connectivity
#include <windows.h>
#include <objbase.h>
#include <activation.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.networking.connectivity.h>

static const WCHAR runtime_class[] = L"Windows.Networking.Connectivity.NetworkInformation";
static IActivationFactory factory;
static INetworkInformationStatics statics;

/* Both interfaces share the factory's COM identity and static lifetime. */
static HRESULT WINAPI factory_QueryInterface(IActivationFactory *iface, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IInspectable) ||
        IsEqualGUID(iid, &IID_IActivationFactory))
        *out = iface;
    else if (IsEqualGUID(iid, &IID_INetworkInformationStatics))
        *out = &statics;
    else
        return E_NOINTERFACE;
    IUnknown_AddRef((IUnknown *)*out);
    return S_OK;
}

static ULONG WINAPI factory_AddRef(IActivationFactory *iface) { return 2; }
static ULONG WINAPI factory_Release(IActivationFactory *iface) { return 1; }

static HRESULT WINAPI factory_GetIids(IActivationFactory *iface, ULONG *count, IID **iids)
{
    if (!count || !iids) return E_POINTER;
    *count = 0;
    *iids = CoTaskMemAlloc(sizeof(**iids));
    if (!*iids) return E_OUTOFMEMORY;
    **iids = IID_INetworkInformationStatics;
    *count = 1;
    return S_OK;
}

static HRESULT WINAPI factory_GetRuntimeClassName(IActivationFactory *iface, HSTRING *name)
{
    if (!name) return E_POINTER;
    return WindowsCreateString(runtime_class, ARRAYSIZE(runtime_class) - 1, name);
}

static HRESULT WINAPI factory_GetTrustLevel(IActivationFactory *iface, TrustLevel *level)
{
    if (!level) return E_POINTER;
    *level = BaseTrust;
    return S_OK;
}

static HRESULT WINAPI factory_ActivateInstance(IActivationFactory *iface, IInspectable **instance)
{
    if (!instance) return E_POINTER;
    *instance = NULL;
    return E_NOTIMPL; /* This runtime class exposes static methods only. */
}

static const IActivationFactoryVtbl factory_vtbl =
{
    factory_QueryInterface, factory_AddRef, factory_Release,
    factory_GetIids, factory_GetRuntimeClassName, factory_GetTrustLevel,
    factory_ActivateInstance,
};
static IActivationFactory factory = { &factory_vtbl };

static HRESULT WINAPI statics_QueryInterface(INetworkInformationStatics *iface, REFIID iid, void **out)
{
    return IActivationFactory_QueryInterface(&factory, iid, out);
}
static ULONG WINAPI statics_AddRef(INetworkInformationStatics *iface) { return 2; }
static ULONG WINAPI statics_Release(INetworkInformationStatics *iface) { return 1; }
static HRESULT WINAPI statics_GetIids(INetworkInformationStatics *iface, ULONG *count, IID **iids)
{
    return factory_GetIids(&factory, count, iids);
}
static HRESULT WINAPI statics_GetRuntimeClassName(INetworkInformationStatics *iface, HSTRING *name)
{
    return factory_GetRuntimeClassName(&factory, name);
}
static HRESULT WINAPI statics_GetTrustLevel(INetworkInformationStatics *iface, TrustLevel *level)
{
    return factory_GetTrustLevel(&factory, level);
}

static HRESULT WINAPI statics_GetConnectionProfiles(INetworkInformationStatics *iface,
        IVectorView_ConnectionProfile **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_GetInternetConnectionProfile(INetworkInformationStatics *iface,
        IConnectionProfile **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return S_OK;
}

static HRESULT WINAPI statics_GetLanIdentifiers(INetworkInformationStatics *iface,
        IVectorView_LanIdentifier **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_GetHostNames(INetworkInformationStatics *iface,
        IVectorView_HostName **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_GetProxyConfigurationAsync(INetworkInformationStatics *iface,
        IUriRuntimeClass *uri, IAsyncOperation_ProxyConfiguration **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_GetSortedEndpointPairs(INetworkInformationStatics *iface,
        IIterable_EndpointPair *endpoints, HostNameSortOptions options, IVectorView_EndpointPair **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_add_NetworkStatusChanged(INetworkInformationStatics *iface,
        INetworkStatusChangedEventHandler *handler, EventRegistrationToken *cookie)
{
    if (!cookie) return E_POINTER;
    cookie->value = 0;
    return E_NOTIMPL;
}

static HRESULT WINAPI statics_remove_NetworkStatusChanged(INetworkInformationStatics *iface,
        EventRegistrationToken cookie)
{
    return E_NOTIMPL;
}

static const INetworkInformationStaticsVtbl statics_vtbl =
{
    statics_QueryInterface, statics_AddRef, statics_Release,
    statics_GetIids, statics_GetRuntimeClassName, statics_GetTrustLevel,
    statics_GetConnectionProfiles, statics_GetInternetConnectionProfile,
    statics_GetLanIdentifiers, statics_GetHostNames, statics_GetProxyConfigurationAsync,
    statics_GetSortedEndpointPairs, statics_add_NetworkStatusChanged,
    statics_remove_NetworkStatusChanged,
};
static INetworkInformationStatics statics = { &statics_vtbl };

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}

/* Factories and empty collection objects have process lifetime. */
HRESULT WINAPI DllCanUnloadNow(void) { return S_FALSE; }

HRESULT WINAPI DllGetActivationFactory(HSTRING classid, IActivationFactory **out)
{
    UINT32 length;
    const WCHAR *name;
    if (!out) return E_POINTER;
    *out = NULL;
    name = WindowsGetStringRawBuffer(classid, &length);
    if (length != ARRAYSIZE(runtime_class) - 1 ||
        memcmp(name, runtime_class, length * sizeof(WCHAR)))
        return CLASS_E_CLASSNOTAVAILABLE;
    *out = &factory;
    IActivationFactory_AddRef(*out);
    return S_OK;
}
