/*
 * test_wifi.c — Testprogramm für den WinRT-Stub Windows.Devices.WiFi.
 * Mit MinGW übersetzen (siehe winrt/README.md), dann über "virtual" starten.
 * Prüft, dass RoGetActivationFactory die Factory liefert.
 */
#include <stdio.h>
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <activation.h>

int main(void)
{
    RoInitialize(RO_INIT_MULTITHREADED);

    HSTRING cls = NULL;
    static const WCHAR name[] = L"Windows.Devices.WiFi.WiFiAdapter";
    WindowsCreateString(name, (UINT32)(sizeof(name)/sizeof(WCHAR) - 1), &cls);

    IActivationFactory *factory = NULL;
    HRESULT hr = RoGetActivationFactory(cls, &IID_IActivationFactory, (void **)&factory);

    if (SUCCEEDED(hr) && factory) {
        printf("WiFiAdapter: Factory ok (hr=0x%08lx). FindAllAdaptersAsync -> 0 Adapter (Stub)\n",
               (unsigned long)hr);
        IActivationFactory_Release(factory);
    } else {
        printf("WiFiAdapter: keine Factory (hr=0x%08lx)\n", (unsigned long)hr);
    }

    WindowsDeleteString(cls);
    RoUninitialize();
    return 0;
}
