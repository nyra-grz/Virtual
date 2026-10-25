/* Regression tests for CLR WinRT metadata discovery and generic interface IDs.
 * Run inside a disposable prefix containing the SDK WinMDs. */
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <winstring.h>
#include "projection-abi.h"
#include <stdio.h>
#include <string.h>

typedef HRESULT (WINAPI *resolve_fn)(HSTRING,HSTRING,DWORD,const HSTRING*,DWORD*,HSTRING**,DWORD*,HSTRING**);
typedef HRESULT (WINAPI *iid_fn)(UINT32,const WCHAR**,const IRoMetaDataLocator*,GUID*,ROPARAMIIDHANDLE*);
typedef const char *(WINAPI *signature_fn)(ROPARAMIIDHANDLE);
typedef void (WINAPI *free_fn)(ROPARAMIIDHANDLE);
static unsigned int checks, failures;
#define check(condition,label) do { ++checks; if (!(condition)) { ++failures; printf("FAIL: %s\n",label); } } while (0)

static HRESULT WINAPI locate(IRoMetaDataLocator *iface, const WCHAR *name, IRoSimpleMetaDataBuilder *builder)
{
    static const GUID iterable = {0xfaa585ea,0x6214,0x4217,{0xaf,0xda,0x7f,0x46,0xde,0x58,0x69,0xb3}};
    static const GUID view = {0xbbe1fa4c,0xb0e3,0x4583,{0xba,0xef,0x1f,0x1b,0x2e,0x48,0x3e,0x56}};
    if (!wcscmp(name,L"Iterable")) return IRoSimpleMetaDataBuilder_SetParameterizedInterface(builder,iterable,1);
    if (!wcscmp(name,L"View")) return IRoSimpleMetaDataBuilder_SetParameterizedInterface(builder,view,1);
    return E_INVALIDARG;
}
static IRoMetaDataLocatorVtbl locator_vtbl = {locate};

static void free_result(HSTRING *values, DWORD count)
{
    while (count) WindowsDeleteString(values[--count]);
    CoTaskMemFree(values);
}

int main(void)
{
    HMODULE combase = LoadLibraryW(L"combase.dll"), wintypes = LoadLibraryW(L"wintypes.dll");
    iid_fn iid = (iid_fn)GetProcAddress(combase,"RoGetParameterizedTypeInstanceIID");
    signature_fn signature = (signature_fn)GetProcAddress(combase,"RoParameterizedTypeExtraGetTypeSignature");
    free_fn free_extra = (free_fn)GetProcAddress(combase,"RoFreeParameterizedTypeExtra");
    resolve_fn resolve = (resolve_fn)GetProcAddress(wintypes,"RoResolveNamespace");
    IRoMetaDataLocator locator = {&locator_vtbl};
    static const GUID iterable_string = {0xe2fcc7c1,0x3bfc,0x5a0b,{0xb2,0xb0,0x72,0xe7,0x69,0xd1,0xcb,0x7e}};
    static const GUID view_string = {0x2f13c006,0xa03a,0x5f69,{0xb0,0x90,0x75,0xa4,0x3e,0x33,0x42,0x3e}};
    const WCHAR *args[] = {L"Iterable",L"String"}, *nested[] = {L"Iterable",L"View",L"String"};
    GUID actual;
    ROPARAMIIDHANDLE extra = NULL;
    HSTRING name, *paths = NULL, *names = NULL;
    DWORD count = 0, name_count = 0;
    HRESULT hr;

    check(iid && signature && free_extra && resolve,"all projection APIs exported");
    if (failures) return 1;
    hr = iid(2,args,&locator,&actual,&extra);
    check(hr == S_OK,"IIterable<String> resolves");
    check(IsEqualGUID(&actual,&iterable_string),"IIterable<String> canonical Windows IID");
    check(extra && !strcmp(signature(extra),"pinterface({faa585ea-6214-4217-afda-7f46de5869b3};string)"),"extra signature ownership and format");
    free_extra(extra);
    args[0] = L"View";
    check(iid(2,args,&locator,&actual,NULL) == S_OK && IsEqualGUID(&actual,&view_string),"IVectorView<String> canonical Windows IID");
    check(iid(3,nested,&locator,&actual,&extra) == S_OK,"nested generic arguments");
    check(extra && !strcmp(signature(extra),"pinterface({faa585ea-6214-4217-afda-7f46de5869b3};pinterface({bbe1fa4c-b0e3-4583-baef-1f1b2e483e56};string))"),"nested signature grammar");
    free_extra(extra);
    check(iid(1,args,&locator,&actual,NULL) == E_INVALIDARG,"missing generic argument rejected");
    check(iid(0,args,&locator,&actual,NULL) == E_INVALIDARG,"empty type rejected");
    check(iid(2,args,&locator,NULL,NULL) == E_INVALIDARG,"missing IID output rejected");
    args[0] = L"Unknown";
    check(iid(2,args,&locator,&actual,NULL) == E_INVALIDARG,"unknown type rejected");
    check(IsEqualGUID(&actual,&GUID_NULL),"failed IID output cleared");

    check(resolve(NULL,NULL,0,NULL,NULL,NULL,NULL,NULL) == E_INVALIDARG,"missing namespace outputs rejected");
    WindowsCreateString(L"Windows.Networking",18,&name);
    check(resolve(name,NULL,0,NULL,NULL,&paths,NULL,NULL) == E_INVALIDARG,"missing file count rejected");
    hr = resolve(name,NULL,0,NULL,&count,&paths,&name_count,&names);
    check(hr == S_OK && count > 0,"real networking namespace discovered from TypeDef metadata");
    if (hr == S_OK)
    {
        DWORD i;
        for (i = 0; i < count; ++i)
            check(GetFileAttributesW(WindowsGetStringRawBuffer(paths[i],NULL)) != INVALID_FILE_ATTRIBUTES,"returned metadata file exists");
    }
    free_result(paths,count); free_result(names,name_count); WindowsDeleteString(name);
    WindowsCreateString(L"Virtual.NoSuchNamespace",23,&name);
    paths = (HSTRING *)1; count = 123;
    hr = resolve(name,NULL,0,NULL,&count,&paths,NULL,NULL);
    check(hr == RO_E_METADATA_NAME_NOT_FOUND && count == 0 && paths == NULL,"unknown namespace returns empty failure");
    WindowsDeleteString(name);
    WindowsCreateString(L"Windows\0Devices",15,&name);
    check(resolve(name,NULL,0,NULL,&count,&paths,NULL,NULL) == E_INVALIDARG,"embedded null rejected");
    WindowsDeleteString(name);
    hr = resolve(NULL,NULL,0,NULL,NULL,NULL,&name_count,&names);
    check(hr == S_OK && name_count > 0,"top level namespace discovery");
    free_result(names,name_count);
    printf("WinRT projection: %u checks, %u failures\n",checks,failures);
    return failures ? 1 : 0;
}
