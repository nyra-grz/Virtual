/* Test the NetworkInformation stub through the public WinRT activation API. */
#define COBJMACROS
#define INITGUID
#define WIDL_using_Windows_Networking_Connectivity
#include <stdio.h>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <activation.h>
#include <windows.networking.connectivity.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s (hr=0x%08lx)\n", __LINE__, #condition, (unsigned long)hr); \
    goto cleanup; } } while (0)

int main(void)
{
    static const WCHAR name[] = L"Windows.Networking.Connectivity.NetworkInformation";
    HSTRING classid = NULL;
    IActivationFactory *factory = NULL;
    INetworkInformationStatics *statics = NULL, *direct = NULL;
    IConnectionProfile *profile = NULL;
    IUnknown *identity = NULL;
    int result = 1;
    HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
    if (FAILED(hr))
    {
        fprintf(stderr, "RoInitialize failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    hr = WindowsCreateString(name, ARRAYSIZE(name) - 1, &classid);
    CHECK(hr == S_OK);
    hr = RoGetActivationFactory(classid, &IID_IActivationFactory, (void **)&factory);
    CHECK(hr == S_OK && factory);
    hr = IActivationFactory_QueryInterface(factory, &IID_INetworkInformationStatics, (void **)&statics);
    CHECK(hr == S_OK && statics);
    hr = INetworkInformationStatics_QueryInterface(statics, &IID_IUnknown, (void **)&identity);
    CHECK(hr == S_OK && identity == (IUnknown *)factory);
    hr = RoGetActivationFactory(classid, &IID_INetworkInformationStatics, (void **)&direct);
    CHECK(hr == S_OK && direct);
    hr = INetworkInformationStatics_GetInternetConnectionProfile(statics, NULL);
    CHECK(hr == E_POINTER);
    /* A sentinel verifies that success actually clears the output pointer. */
    profile = (IConnectionProfile *)(ULONG_PTR)1;
    hr = INetworkInformationStatics_GetInternetConnectionProfile(statics, &profile);
    CHECK(hr == S_OK && profile == NULL);
    puts("NetworkInformation: GetInternetConnectionProfile -> NULL, S_OK (Stub)");
    result = 0;

cleanup:
    if (profile && profile != (IConnectionProfile *)(ULONG_PTR)1) IConnectionProfile_Release(profile);
    if (identity) IUnknown_Release(identity);
    if (direct) INetworkInformationStatics_Release(direct);
    if (statics) INetworkInformationStatics_Release(statics);
    if (factory) IActivationFactory_Release(factory);
    WindowsDeleteString(classid);
    RoUninitialize();
    return result;
}
