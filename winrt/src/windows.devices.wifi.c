/*
 * windows.devices.wifi.dll — WinRT-Stub für Windows.Devices.WiFi
 *
 * Muster für eine eingebaute WinRT-DLL im Wine-Fork "Virtual".
 * Stand: Stub ("kein WLAN-Adapter"). Die mit "TODO CoreWLAN" markierte Stelle
 * ist der Anknüpfungspunkt für echte Daten über das macOS-CoreWLAN-Framework
 * (via wine_unix_call in einen .so-Unixlib-Teil).
 *
 * Übersetzen NUR im Wine-Baum (braucht Wine-Header und winebuild + die Spec).
 * Siehe winrt/README.md.
 */

#include <stdarg.h>
#define COBJMACROS
#include "windef.h"
#include "winbase.h"
#include "initguid.h"
#include "activation.h"
#include "roapi.h"
#include "winstring.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(winrt);

/* Laufzeitklassen-Name, den RoGetActivationFactory anfragt. */
static const WCHAR class_wifiadapter[] =
    L"Windows.Devices.WiFi.WiFiAdapter";

/* --- IActivationFactory: minimale, korrekte Implementierung ---------------- */

static HRESULT WINAPI factory_QueryInterface(IActivationFactory *iface,
                                             REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) ||
        IsEqualGUID(iid, &IID_IInspectable) ||
        IsEqualGUID(iid, &IID_IActivationFactory))
    {
        IActivationFactory_AddRef((*out = iface));
        return S_OK;
    }
    FIXME("Nicht unterstütztes Interface angefragt.\n");
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG WINAPI factory_AddRef(IActivationFactory *iface)   { return 2; }
static ULONG WINAPI factory_Release(IActivationFactory *iface)  { return 1; }

static HRESULT WINAPI factory_GetIids(IActivationFactory *iface,
                                      ULONG *count, IID **iids)
{
    *count = 0; *iids = NULL; return S_OK;
}
static HRESULT WINAPI factory_GetRuntimeClassName(IActivationFactory *iface,
                                                  HSTRING *name)
{
    return WindowsCreateString(class_wifiadapter,
                               ARRAYSIZE(class_wifiadapter) - 1, name);
}
static HRESULT WINAPI factory_GetTrustLevel(IActivationFactory *iface,
                                            TrustLevel *level)
{
    *level = BaseTrust; return S_OK;
}

/*
 * ActivateInstance: WiFiAdapter wird nicht direkt aktiviert, sondern über
 * statische Methoden (FindAllAdaptersAsync) der Klasse benutzt. Im Stub geben
 * wir bewusst "keine Instanz" zurück.
 *
 * TODO CoreWLAN: Hier bzw. in der statischen WiFiAdapterStatics-Factory die
 * echten Adapter über CoreWLAN (CWWiFiClient.sharedWiFiClient.interfaces)
 * liefern. Zugriff auf macOS-APIs gehört in den Unixlib-Teil (.so), angebunden
 * per __wine_unix_call — nicht direkt aus dem PE-seitigen Code.
 */
static HRESULT WINAPI factory_ActivateInstance(IActivationFactory *iface,
                                               IInspectable **inst)
{
    FIXME("WiFiAdapter: Stub — kein WLAN-Adapter (ActivateInstance).\n");
    *inst = NULL;
    return E_NOTIMPL;
}

static const IActivationFactoryVtbl factory_vtbl =
{
    factory_QueryInterface,
    factory_AddRef,
    factory_Release,
    factory_GetIids,
    factory_GetRuntimeClassName,
    factory_GetTrustLevel,
    factory_ActivateInstance,
};

static IActivationFactory wifi_factory = { &factory_vtbl };

/* --- DLL-Einsprungpunkte ---------------------------------------------------- */

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(inst);
    return TRUE;
}

HRESULT WINAPI DllCanUnloadNow(void) { return S_FALSE; }

HRESULT WINAPI DllGetActivationFactory(HSTRING classid, IActivationFactory **factory)
{
    const WCHAR *name = WindowsGetStringRawBuffer(classid, NULL);
    TRACE("classid %s\n", debugstr_w(name));

    if (name && !wcscmp(name, class_wifiadapter))
    {
        *factory = &wifi_factory;
        IActivationFactory_AddRef(*factory);
        return S_OK;
    }

    FIXME("Unbekannte Klasse %s angefragt.\n", debugstr_w(name));
    *factory = NULL;
    return REGDB_E_CLASSNOTREG;
}
