/* Exercise completed operations, empty collections, and their COM lifetimes. */
#define COBJMACROS
#define CONST_VTABLE
#define INITGUID
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Devices_Enumeration
#include <stdio.h>
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <activation.h>
#include <windows.devices.enumeration.h>

/* Windows SDK constants absent from some MinGW winerror.h versions. */
#ifndef RO_E_CLOSED
#define RO_E_CLOSED ((HRESULT)0x80000013)
#endif
#ifndef E_ILLEGAL_DELEGATE_ASSIGNMENT
#define E_ILLEGAL_DELEGATE_ASSIGNMENT ((HRESULT)0x80000018)
#endif

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s (hr=0x%08lx)\n", __LINE__, #condition, (unsigned long)hr); \
    goto cleanup; } } while (0)

struct completion_handler
{
    IAsyncOperationCompletedHandler_DeviceInformationCollection iface;
    LONG refs;
    unsigned int calls;
    BOOL valid;
};

static ULONG WINAPI handler_AddRef(IAsyncOperationCompletedHandler_DeviceInformationCollection *iface)
{
    struct completion_handler *handler = CONTAINING_RECORD(iface, struct completion_handler, iface);
    return InterlockedIncrement(&handler->refs);
}
static ULONG WINAPI handler_Release(IAsyncOperationCompletedHandler_DeviceInformationCollection *iface)
{
    struct completion_handler *handler = CONTAINING_RECORD(iface, struct completion_handler, iface);
    return InterlockedDecrement(&handler->refs);
}
static HRESULT WINAPI handler_QueryInterface(IAsyncOperationCompletedHandler_DeviceInformationCollection *iface,
        REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (!IsEqualGUID(iid, &IID_IUnknown) &&
        !IsEqualGUID(iid, &IID_IAsyncOperationCompletedHandler_DeviceInformationCollection))
        return E_NOINTERFACE;
    *out = iface;
    handler_AddRef(iface);
    return S_OK;
}
static HRESULT WINAPI handler_Invoke(IAsyncOperationCompletedHandler_DeviceInformationCollection *iface,
        IAsyncOperation_DeviceInformationCollection *operation, AsyncStatus status)
{
    struct completion_handler *handler = CONTAINING_RECORD(iface, struct completion_handler, iface);
    IVectorView_DeviceInformation *view = NULL;
    UINT32 size = ~0u;
    HRESULT hr = IAsyncOperation_DeviceInformationCollection_GetResults(operation, &view);
    ++handler->calls;
    handler->valid = status == Completed && hr == S_OK && view;
    if (view)
    {
        hr = IVectorView_DeviceInformation_get_Size(view, &size);
        handler->valid = handler->valid && hr == S_OK && !size;
        IVectorView_DeviceInformation_Release(view);
    }
    return S_OK;
}
static const IAsyncOperationCompletedHandler_DeviceInformationCollectionVtbl handler_vtbl =
{
    handler_QueryInterface, handler_AddRef, handler_Release, handler_Invoke,
};

static int check_operation(IAsyncOperation_DeviceInformationCollection *operation)
{
    struct completion_handler handler = { { &handler_vtbl }, 1, 0, FALSE };
    IAsyncOperationCompletedHandler_DeviceInformationCollection *registered = NULL;
    IAsyncInfo *info = NULL;
    IVectorView_DeviceInformation *view = NULL, *again = NULL;
    IIterable_DeviceInformation *iterable = NULL;
    IIterator_DeviceInformation *iterator = NULL;
    IDeviceInformation *item = NULL;
    IUnknown *identity = NULL;
    AsyncStatus status = Started;
    boolean found = TRUE;
    UINT32 size = ~0u, count = ~0u, index = ~0u;
    HRESULT error = E_FAIL, hr = S_OK;
    int result = 1;

    hr = IAsyncOperation_DeviceInformationCollection_QueryInterface(operation, &IID_IAsyncInfo, (void **)&info);
    CHECK(hr == S_OK && info);
    hr = IAsyncInfo_QueryInterface(info, &IID_IUnknown, (void **)&identity);
    CHECK(hr == S_OK && identity == (IUnknown *)operation);
    hr = IAsyncInfo_get_Status(info, &status);
    CHECK(hr == S_OK && status == Completed);
    hr = IAsyncInfo_get_ErrorCode(info, &error);
    CHECK(hr == S_OK && error == S_OK);
    hr = IAsyncOperation_DeviceInformationCollection_get_Completed(operation, &registered);
    CHECK(hr == S_OK && !registered);
    hr = IAsyncOperation_DeviceInformationCollection_put_Completed(operation, &handler.iface);
    CHECK(hr == S_OK && handler.calls == 1 && handler.valid);
    hr = IAsyncOperation_DeviceInformationCollection_put_Completed(operation, &handler.iface);
    CHECK(hr == E_ILLEGAL_DELEGATE_ASSIGNMENT && handler.calls == 1);
    hr = IAsyncOperation_DeviceInformationCollection_get_Completed(operation, &registered);
    CHECK(hr == S_OK && registered == &handler.iface);
    IAsyncOperationCompletedHandler_DeviceInformationCollection_Release(registered);
    registered = NULL;
    hr = IAsyncOperation_DeviceInformationCollection_GetResults(operation, NULL);
    CHECK(hr == E_POINTER);
    hr = IAsyncOperation_DeviceInformationCollection_GetResults(operation, &view);
    CHECK(hr == S_OK && view);
    hr = IAsyncOperation_DeviceInformationCollection_GetResults(operation, &again);
    CHECK(hr == S_OK && again);
    IVectorView_DeviceInformation_Release(again);
    again = NULL;
    hr = IVectorView_DeviceInformation_get_Size(view, &size);
    CHECK(hr == S_OK && !size);
    hr = IVectorView_DeviceInformation_GetAt(view, 0, &item);
    CHECK(hr == E_BOUNDS && !item);
    hr = IVectorView_DeviceInformation_IndexOf(view, NULL, &index, &found);
    CHECK(hr == S_OK && !found && !index);
    hr = IVectorView_DeviceInformation_GetMany(view, 0, 1, &item, &count);
    CHECK(hr == S_OK && !count && !item);
    hr = IVectorView_DeviceInformation_GetMany(view, 1, 0, NULL, &count);
    CHECK(hr == E_BOUNDS && !count);
    hr = IVectorView_DeviceInformation_QueryInterface(view, &IID_IIterable_DeviceInformation, (void **)&iterable);
    CHECK(hr == S_OK && iterable);
    hr = IIterable_DeviceInformation_First(iterable, &iterator);
    CHECK(hr == S_OK && iterator);
    hr = IIterator_DeviceInformation_get_HasCurrent(iterator, &found);
    CHECK(hr == S_OK && !found);
    hr = IIterator_DeviceInformation_get_Current(iterator, &item);
    CHECK(hr == E_BOUNDS && !item);
    hr = IIterator_DeviceInformation_MoveNext(iterator, &found);
    CHECK(hr == S_OK && !found);
    hr = IIterator_DeviceInformation_GetMany(iterator, 1, &item, &count);
    CHECK(hr == S_OK && !count && !item);
    hr = IAsyncInfo_Cancel(info);
    CHECK(hr == S_OK);
    hr = IAsyncInfo_get_Status(info, &status);
    CHECK(hr == S_OK && status == Completed);
    hr = IAsyncInfo_Close(info);
    CHECK(hr == S_OK && handler.refs == 1);
    hr = IAsyncOperation_DeviceInformationCollection_GetResults(operation, &again);
    CHECK(hr == RO_E_CLOSED && !again);
    /* Results already handed to the caller survive closing the operation. */
    hr = IVectorView_DeviceInformation_get_Size(view, &size);
    CHECK(hr == S_OK && !size);
    result = 0;

cleanup:
    if (info) IAsyncInfo_Close(info); /* Release any retained stack callback. */
    if (registered) IAsyncOperationCompletedHandler_DeviceInformationCollection_Release(registered);
    if (identity) IUnknown_Release(identity);
    if (item) IDeviceInformation_Release(item);
    if (iterator) IIterator_DeviceInformation_Release(iterator);
    if (iterable) IIterable_DeviceInformation_Release(iterable);
    if (again) IVectorView_DeviceInformation_Release(again);
    if (view) IVectorView_DeviceInformation_Release(view);
    if (info) IAsyncInfo_Release(info);
    if (handler.refs != 1) result = 1;
    return result;
}

int main(void)
{
    static const WCHAR name[] = L"Windows.Devices.Enumeration.DeviceInformation";
    HSTRING classid = NULL;
    IActivationFactory *factory = NULL;
    IDeviceInformationStatics *statics = NULL;
    IAsyncOperation_DeviceInformationCollection *operation = NULL;
    unsigned int overload;
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
    hr = IActivationFactory_QueryInterface(factory, &IID_IDeviceInformationStatics, (void **)&statics);
    CHECK(hr == S_OK && statics);
    hr = IDeviceInformationStatics_FindAllAsync(statics, NULL);
    CHECK(hr == E_POINTER);
    for (overload = 0; overload < 4; ++overload)
    {
        switch (overload)
        {
        case 0: hr = IDeviceInformationStatics_FindAllAsync(statics, &operation); break;
        case 1: hr = IDeviceInformationStatics_FindAllAsyncDeviceClass(statics, DeviceClass_All, &operation); break;
        case 2: hr = IDeviceInformationStatics_FindAllAsyncAqsFilter(statics, NULL, &operation); break;
        default: hr = IDeviceInformationStatics_FindAllAsyncAqsFilterAndAdditionalProperties(statics, NULL, NULL, &operation); break;
        }
        CHECK(hr == S_OK && operation);
        CHECK(check_operation(operation) == 0);
        IAsyncOperation_DeviceInformationCollection_Release(operation);
        operation = NULL;
    }
    puts("DeviceInformation: FindAllAsync -> Completed, 0 Geraete (Stub)");
    result = 0;

cleanup:
    if (operation) IAsyncOperation_DeviceInformationCollection_Release(operation);
    if (statics) IDeviceInformationStatics_Release(statics);
    if (factory) IActivationFactory_Release(factory);
    WindowsDeleteString(classid);
    RoUninitialize();
    return result;
}
