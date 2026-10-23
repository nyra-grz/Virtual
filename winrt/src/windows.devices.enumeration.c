/* Builtin WinRT stub; see winrt/README.md for Wine integration. */
#define COBJMACROS
#define CONST_VTABLE
#define INITGUID
#define WIDL_using_Windows_Foundation
#define WIDL_using_Windows_Foundation_Collections
#define WIDL_using_Windows_Devices_Enumeration
#include <windows.h>
#include <objbase.h>
#include <activation.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.devices.enumeration.h>

/* Missing from some MinGW winerror.h versions; Windows SDK HRESULT values. */
#ifndef RO_E_CLOSED
#define RO_E_CLOSED ((HRESULT)0x80000013)
#endif
#ifndef E_ILLEGAL_DELEGATE_ASSIGNMENT
#define E_ILLEGAL_DELEGATE_ASSIGNMENT ((HRESULT)0x80000018)
#endif

static const WCHAR runtime_class[] = L"Windows.Devices.Enumeration.DeviceInformation";
static IActivationFactory factory;
static IDeviceInformationStatics statics;

/* Both interfaces share the factory's COM identity and static lifetime. */
static HRESULT WINAPI factory_QueryInterface(IActivationFactory *iface, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IInspectable) ||
        IsEqualGUID(iid, &IID_IActivationFactory))
        *out = iface;
    else if (IsEqualGUID(iid, &IID_IDeviceInformationStatics))
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
    **iids = IID_IDeviceInformationStatics;
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

static HRESULT WINAPI statics_QueryInterface(IDeviceInformationStatics *iface, REFIID iid, void **out)
{
    return IActivationFactory_QueryInterface(&factory, iid, out);
}
static ULONG WINAPI statics_AddRef(IDeviceInformationStatics *iface) { return 2; }
static ULONG WINAPI statics_Release(IDeviceInformationStatics *iface) { return 1; }
static HRESULT WINAPI statics_GetIids(IDeviceInformationStatics *iface, ULONG *count, IID **iids)
{
    return factory_GetIids(&factory, count, iids);
}
static HRESULT WINAPI statics_GetRuntimeClassName(IDeviceInformationStatics *iface, HSTRING *name)
{
    return factory_GetRuntimeClassName(&factory, name);
}
static HRESULT WINAPI statics_GetTrustLevel(IDeviceInformationStatics *iface, TrustLevel *level)
{
    return factory_GetTrustLevel(&factory, level);
}

/* The immutable empty collection and its exhausted iterator are singletons. */
static IVectorView_DeviceInformation empty_view;
static IIterable_DeviceInformation empty_iterable;
static IIterator_DeviceInformation empty_iterator;

static HRESULT WINAPI view_QueryInterface(IVectorView_DeviceInformation *iface, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IInspectable) ||
        IsEqualGUID(iid, &IID_IVectorView_DeviceInformation))
        *out = &empty_view;
    else if (IsEqualGUID(iid, &IID_IIterable_DeviceInformation))
        *out = &empty_iterable;
    else return E_NOINTERFACE;
    IUnknown_AddRef((IUnknown *)*out);
    return S_OK;
}

static HRESULT WINAPI iterable_QueryInterface(IIterable_DeviceInformation *iface, REFIID iid, void **out)
{
    return view_QueryInterface(&empty_view, iid, out);
}

static HRESULT WINAPI iterator_QueryInterface(IIterator_DeviceInformation *iface, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    if (!IsEqualGUID(iid, &IID_IUnknown) && !IsEqualGUID(iid, &IID_IInspectable) &&
        !IsEqualGUID(iid, &IID_IIterator_DeviceInformation)) return E_NOINTERFACE;
    *out = iface;
    IIterator_DeviceInformation_AddRef(iface);
    return S_OK;
}

static ULONG WINAPI view_AddRef(IVectorView_DeviceInformation *iface) { return 2; }
static ULONG WINAPI view_Release(IVectorView_DeviceInformation *iface) { return 1; }
static HRESULT WINAPI view_GetIids(IVectorView_DeviceInformation *iface, ULONG *count, IID **iids)
{
    if (!count || !iids) return E_POINTER;
    *count = 0;
    *iids = CoTaskMemAlloc(2 * sizeof(**iids));
    if (!*iids) return E_OUTOFMEMORY;
    (*iids)[0] = IID_IVectorView_DeviceInformation;
    (*iids)[1] = IID_IIterable_DeviceInformation;
    *count = 2;
    return S_OK;
}
static HRESULT WINAPI view_GetRuntimeClassName(IVectorView_DeviceInformation *iface, HSTRING *name)
{
    static const WCHAR name_string[] = L"Windows.Devices.Enumeration.DeviceInformationCollection";
    if (!name) return E_POINTER;
    return WindowsCreateString(name_string, ARRAYSIZE(name_string) - 1, name);
}
static HRESULT WINAPI view_GetTrustLevel(IVectorView_DeviceInformation *iface, TrustLevel *level)
{
    if (!level) return E_POINTER;
    *level = BaseTrust;
    return S_OK;
}

static ULONG WINAPI iterable_AddRef(IIterable_DeviceInformation *iface) { return 2; }
static ULONG WINAPI iterable_Release(IIterable_DeviceInformation *iface) { return 1; }
static HRESULT WINAPI iterable_GetIids(IIterable_DeviceInformation *iface, ULONG *count, IID **iids)
{
    return view_GetIids(&empty_view, count, iids);
}
static HRESULT WINAPI iterable_GetRuntimeClassName(IIterable_DeviceInformation *iface, HSTRING *name)
{
    return view_GetRuntimeClassName(&empty_view, name);
}
static HRESULT WINAPI iterable_GetTrustLevel(IIterable_DeviceInformation *iface, TrustLevel *level)
{
    if (!level) return E_POINTER;
    *level = BaseTrust;
    return S_OK;
}

static ULONG WINAPI iterator_AddRef(IIterator_DeviceInformation *iface) { return 2; }
static ULONG WINAPI iterator_Release(IIterator_DeviceInformation *iface) { return 1; }
static HRESULT WINAPI iterator_GetIids(IIterator_DeviceInformation *iface, ULONG *count, IID **iids)
{
    if (!count || !iids) return E_POINTER;
    *count = 0;
    *iids = CoTaskMemAlloc(sizeof(**iids));
    if (!*iids) return E_OUTOFMEMORY;
    **iids = IID_IIterator_DeviceInformation;
    *count = 1;
    return S_OK;
}
static HRESULT WINAPI iterator_GetRuntimeClassName(IIterator_DeviceInformation *iface, HSTRING *name)
{
    if (!name) return E_POINTER;
    *name = NULL;
    return E_NOTIMPL;
}
static HRESULT WINAPI iterator_GetTrustLevel(IIterator_DeviceInformation *iface, TrustLevel *level)
{
    if (!level) return E_POINTER;
    *level = BaseTrust;
    return S_OK;
}

static HRESULT WINAPI view_GetAt(IVectorView_DeviceInformation *iface, UINT32 index, IDeviceInformation **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_BOUNDS;
}
static HRESULT WINAPI view_get_Size(IVectorView_DeviceInformation *iface, UINT32 *size)
{
    if (!size) return E_POINTER;
    *size = 0;
    return S_OK;
}
static HRESULT WINAPI view_IndexOf(IVectorView_DeviceInformation *iface, IDeviceInformation *value,
        UINT32 *index, boolean *found)
{
    if (!index || !found) return E_POINTER;
    *index = 0;
    *found = FALSE;
    return S_OK;
}
static HRESULT WINAPI view_GetMany(IVectorView_DeviceInformation *iface, UINT32 start, UINT32 capacity,
        IDeviceInformation **items, UINT32 *actual)
{
    if (!actual) return E_POINTER;
    *actual = 0;
    if (capacity && !items) return E_POINTER;
    return start ? E_BOUNDS : S_OK;
}
static HRESULT WINAPI iterable_First(IIterable_DeviceInformation *iface, IIterator_DeviceInformation **iterator)
{
    if (!iterator) return E_POINTER;
    *iterator = &empty_iterator;
    IIterator_DeviceInformation_AddRef(*iterator);
    return S_OK;
}
static HRESULT WINAPI iterator_get_Current(IIterator_DeviceInformation *iface, IDeviceInformation **value)
{
    if (!value) return E_POINTER;
    *value = NULL;
    return E_BOUNDS;
}
static HRESULT WINAPI iterator_get_HasCurrent(IIterator_DeviceInformation *iface, boolean *value)
{
    if (!value) return E_POINTER;
    *value = FALSE;
    return S_OK;
}
static HRESULT WINAPI iterator_MoveNext(IIterator_DeviceInformation *iface, boolean *value)
{
    return iterator_get_HasCurrent(iface, value);
}
static HRESULT WINAPI iterator_GetMany(IIterator_DeviceInformation *iface, UINT32 capacity,
        IDeviceInformation **items, UINT32 *actual)
{
    if (!actual) return E_POINTER;
    *actual = 0;
    return capacity && !items ? E_POINTER : S_OK;
}

static const IVectorView_DeviceInformationVtbl view_vtbl =
{
    view_QueryInterface, view_AddRef, view_Release,
    view_GetIids, view_GetRuntimeClassName, view_GetTrustLevel,
    view_GetAt, view_get_Size, view_IndexOf, view_GetMany,
};
static IVectorView_DeviceInformation empty_view = { &view_vtbl };
static const IIterable_DeviceInformationVtbl iterable_vtbl =
{
    iterable_QueryInterface, iterable_AddRef, iterable_Release,
    iterable_GetIids, iterable_GetRuntimeClassName, iterable_GetTrustLevel,
    iterable_First,
};
static IIterable_DeviceInformation empty_iterable = { &iterable_vtbl };
static const IIterator_DeviceInformationVtbl iterator_vtbl =
{
    iterator_QueryInterface, iterator_AddRef, iterator_Release,
    iterator_GetIids, iterator_GetRuntimeClassName, iterator_GetTrustLevel,
    iterator_get_Current, iterator_get_HasCurrent, iterator_MoveNext, iterator_GetMany,
};
static IIterator_DeviceInformation empty_iterator = { &iterator_vtbl };

/* Each call gets an independent, already-completed operation. */
struct async_operation
{
    IAsyncOperation_DeviceInformationCollection operation;
    IAsyncInfo info;
    LONG refs;
    CRITICAL_SECTION lock;
    BOOL closed, handler_assigned;
    IAsyncOperationCompletedHandler_DeviceInformationCollection *handler;
};

static struct async_operation *impl_from_operation(IAsyncOperation_DeviceInformationCollection *iface)
{
    return CONTAINING_RECORD(iface, struct async_operation, operation);
}
static struct async_operation *impl_from_info(IAsyncInfo *iface)
{
    return CONTAINING_RECORD(iface, struct async_operation, info);
}
static ULONG WINAPI operation_AddRef(IAsyncOperation_DeviceInformationCollection *iface)
{
    return InterlockedIncrement(&impl_from_operation(iface)->refs);
}
static ULONG WINAPI operation_Release(IAsyncOperation_DeviceInformationCollection *iface)
{
    struct async_operation *impl = impl_from_operation(iface);
    ULONG refs = InterlockedDecrement(&impl->refs);
    if (!refs)
    {
        if (impl->handler) IAsyncOperationCompletedHandler_DeviceInformationCollection_Release(impl->handler);
        DeleteCriticalSection(&impl->lock);
        HeapFree(GetProcessHeap(), 0, impl);
    }
    return refs;
}
static HRESULT WINAPI operation_QueryInterface(IAsyncOperation_DeviceInformationCollection *iface,
        REFIID iid, void **out)
{
    struct async_operation *impl = impl_from_operation(iface);
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IInspectable) ||
        IsEqualGUID(iid, &IID_IAsyncOperation_DeviceInformationCollection))
        *out = iface;
    else if (IsEqualGUID(iid, &IID_IAsyncInfo))
        *out = &impl->info;
    else return E_NOINTERFACE;
    operation_AddRef(iface);
    return S_OK;
}
static HRESULT WINAPI operation_GetIids(IAsyncOperation_DeviceInformationCollection *iface, ULONG *count, IID **iids)
{
    if (!count || !iids) return E_POINTER;
    *count = 0;
    *iids = CoTaskMemAlloc(2 * sizeof(**iids));
    if (!*iids) return E_OUTOFMEMORY;
    (*iids)[0] = IID_IAsyncOperation_DeviceInformationCollection;
    (*iids)[1] = IID_IAsyncInfo;
    *count = 2;
    return S_OK;
}
static HRESULT WINAPI operation_GetRuntimeClassName(IAsyncOperation_DeviceInformationCollection *iface, HSTRING *name)
{
    if (!name) return E_POINTER;
    *name = NULL;
    return E_NOTIMPL;
}
static HRESULT WINAPI operation_GetTrustLevel(IAsyncOperation_DeviceInformationCollection *iface, TrustLevel *level)
{
    if (!level) return E_POINTER;
    *level = BaseTrust;
    return S_OK;
}
static HRESULT WINAPI operation_put_Completed(IAsyncOperation_DeviceInformationCollection *iface,
        IAsyncOperationCompletedHandler_DeviceInformationCollection *handler)
{
    struct async_operation *impl = impl_from_operation(iface);
    HRESULT hr = S_OK;
    if (!handler) return E_INVALIDARG;
    EnterCriticalSection(&impl->lock);
    if (impl->closed) hr = RO_E_CLOSED;
    else if (impl->handler_assigned) hr = E_ILLEGAL_DELEGATE_ASSIGNMENT;
    else
    {
        impl->handler_assigned = TRUE;
        impl->handler = handler;
        IAsyncOperationCompletedHandler_DeviceInformationCollection_AddRef(handler);
    }
    LeaveCriticalSection(&impl->lock);
    if (FAILED(hr)) return hr;
    /* Invoke outside the lock; the callback may retrieve results or close us. */
    operation_AddRef(iface);
    IAsyncOperationCompletedHandler_DeviceInformationCollection_AddRef(handler);
    IAsyncOperationCompletedHandler_DeviceInformationCollection_Invoke(handler, iface, Completed);
    IAsyncOperationCompletedHandler_DeviceInformationCollection_Release(handler);
    operation_Release(iface);
    return S_OK;
}
static HRESULT WINAPI operation_get_Completed(IAsyncOperation_DeviceInformationCollection *iface,
        IAsyncOperationCompletedHandler_DeviceInformationCollection **handler)
{
    struct async_operation *impl = impl_from_operation(iface);
    HRESULT hr;
    if (!handler) return E_POINTER;
    *handler = NULL;
    EnterCriticalSection(&impl->lock);
    hr = impl->closed ? RO_E_CLOSED : S_OK;
    if (SUCCEEDED(hr) && (*handler = impl->handler))
        IAsyncOperationCompletedHandler_DeviceInformationCollection_AddRef(*handler);
    LeaveCriticalSection(&impl->lock);
    return hr;
}
static HRESULT WINAPI operation_GetResults(IAsyncOperation_DeviceInformationCollection *iface,
        IVectorView_DeviceInformation **results)
{
    struct async_operation *impl = impl_from_operation(iface);
    HRESULT hr;
    if (!results) return E_POINTER;
    *results = NULL;
    EnterCriticalSection(&impl->lock);
    hr = impl->closed ? RO_E_CLOSED : S_OK;
    if (SUCCEEDED(hr))
    {
        *results = &empty_view;
        IVectorView_DeviceInformation_AddRef(*results);
    }
    LeaveCriticalSection(&impl->lock);
    return hr;
}

static HRESULT WINAPI info_QueryInterface(IAsyncInfo *iface, REFIID iid, void **out)
{
    return operation_QueryInterface(&impl_from_info(iface)->operation, iid, out);
}
static ULONG WINAPI info_AddRef(IAsyncInfo *iface)
{
    return operation_AddRef(&impl_from_info(iface)->operation);
}
static ULONG WINAPI info_Release(IAsyncInfo *iface)
{
    return operation_Release(&impl_from_info(iface)->operation);
}
static HRESULT WINAPI info_GetIids(IAsyncInfo *iface, ULONG *count, IID **iids)
{
    return operation_GetIids(&impl_from_info(iface)->operation, count, iids);
}
static HRESULT WINAPI info_GetRuntimeClassName(IAsyncInfo *iface, HSTRING *name)
{
    return operation_GetRuntimeClassName(&impl_from_info(iface)->operation, name);
}
static HRESULT WINAPI info_GetTrustLevel(IAsyncInfo *iface, TrustLevel *level)
{
    return operation_GetTrustLevel(&impl_from_info(iface)->operation, level);
}
static HRESULT info_check_open(IAsyncInfo *iface)
{
    struct async_operation *impl = impl_from_info(iface);
    HRESULT hr;
    EnterCriticalSection(&impl->lock);
    hr = impl->closed ? RO_E_CLOSED : S_OK;
    LeaveCriticalSection(&impl->lock);
    return hr;
}
static HRESULT WINAPI info_get_Id(IAsyncInfo *iface, UINT32 *id)
{
    if (!id) return E_POINTER;
    *id = 1;
    return info_check_open(iface);
}
static HRESULT WINAPI info_get_Status(IAsyncInfo *iface, AsyncStatus *status)
{
    if (!status) return E_POINTER;
    *status = Completed;
    return info_check_open(iface);
}
static HRESULT WINAPI info_get_ErrorCode(IAsyncInfo *iface, HRESULT *error)
{
    if (!error) return E_POINTER;
    *error = S_OK;
    return info_check_open(iface);
}
static HRESULT WINAPI info_Cancel(IAsyncInfo *iface)
{
    return info_check_open(iface); /* Already completed: cancellation is a no-op. */
}
static HRESULT WINAPI info_Close(IAsyncInfo *iface)
{
    struct async_operation *impl = impl_from_info(iface);
    IAsyncOperationCompletedHandler_DeviceInformationCollection *handler;
    EnterCriticalSection(&impl->lock);
    impl->closed = TRUE;
    handler = impl->handler;
    impl->handler = NULL;
    LeaveCriticalSection(&impl->lock);
    if (handler) IAsyncOperationCompletedHandler_DeviceInformationCollection_Release(handler);
    return S_OK;
}
static const IAsyncOperation_DeviceInformationCollectionVtbl operation_vtbl =
{
    operation_QueryInterface, operation_AddRef, operation_Release,
    operation_GetIids, operation_GetRuntimeClassName, operation_GetTrustLevel,
    operation_put_Completed, operation_get_Completed, operation_GetResults,
};
static const IAsyncInfoVtbl info_vtbl =
{
    info_QueryInterface, info_AddRef, info_Release,
    info_GetIids, info_GetRuntimeClassName, info_GetTrustLevel,
    info_get_Id, info_get_Status, info_get_ErrorCode, info_Cancel, info_Close,
};

static HRESULT WINAPI statics_FindAllAsync(IDeviceInformationStatics *iface,
        IAsyncOperation_DeviceInformationCollection **out)
{
    struct async_operation *impl;
    if (!out) return E_POINTER;
    *out = NULL;
    impl = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*impl));
    if (!impl) return E_OUTOFMEMORY;
    impl->operation.lpVtbl = &operation_vtbl;
    impl->info.lpVtbl = &info_vtbl;
    impl->refs = 1;
    InitializeCriticalSection(&impl->lock);
    *out = &impl->operation;
    return S_OK;
}
static HRESULT WINAPI statics_FindAllAsyncDeviceClass(IDeviceInformationStatics *iface,
        DeviceClass device_class, IAsyncOperation_DeviceInformationCollection **out)
{
    return statics_FindAllAsync(iface, out);
}
static HRESULT WINAPI statics_FindAllAsyncAqsFilter(IDeviceInformationStatics *iface,
        HSTRING filter, IAsyncOperation_DeviceInformationCollection **out)
{
    return statics_FindAllAsync(iface, out);
}
static HRESULT WINAPI statics_FindAllAsyncAqsFilterAndAdditionalProperties(IDeviceInformationStatics *iface,
        HSTRING filter, IIterable_HSTRING *properties, IAsyncOperation_DeviceInformationCollection **out)
{
    return statics_FindAllAsync(iface, out);
}
static HRESULT WINAPI statics_CreateFromIdAsync(IDeviceInformationStatics *iface,
        HSTRING id, IAsyncOperation_DeviceInformation **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    return E_NOTIMPL;
}
static HRESULT WINAPI statics_CreateFromIdAsyncAdditionalProperties(IDeviceInformationStatics *iface,
        HSTRING id, IIterable_HSTRING *properties, IAsyncOperation_DeviceInformation **out)
{
    return statics_CreateFromIdAsync(iface, id, out);
}
static HRESULT WINAPI statics_CreateWatcher(IDeviceInformationStatics *iface, IDeviceWatcher **out)
{
    if (!out) return E_POINTER;
    *out = NULL;
    return E_NOTIMPL;
}
static HRESULT WINAPI statics_CreateWatcherDeviceClass(IDeviceInformationStatics *iface,
        DeviceClass device_class, IDeviceWatcher **out)
{
    return statics_CreateWatcher(iface, out);
}
static HRESULT WINAPI statics_CreateWatcherAqsFilter(IDeviceInformationStatics *iface,
        HSTRING filter, IDeviceWatcher **out)
{
    return statics_CreateWatcher(iface, out);
}
static HRESULT WINAPI statics_CreateWatcherAqsFilterAndAdditionalProperties(IDeviceInformationStatics *iface,
        HSTRING filter, IIterable_HSTRING *properties, IDeviceWatcher **out)
{
    return statics_CreateWatcher(iface, out);
}
static const IDeviceInformationStaticsVtbl statics_vtbl =
{
    statics_QueryInterface, statics_AddRef, statics_Release,
    statics_GetIids, statics_GetRuntimeClassName, statics_GetTrustLevel,
    statics_CreateFromIdAsync, statics_CreateFromIdAsyncAdditionalProperties,
    statics_FindAllAsync, statics_FindAllAsyncDeviceClass, statics_FindAllAsyncAqsFilter,
    statics_FindAllAsyncAqsFilterAndAdditionalProperties,
    statics_CreateWatcher, statics_CreateWatcherDeviceClass, statics_CreateWatcherAqsFilter,
    statics_CreateWatcherAqsFilterAndAdditionalProperties,
};
static IDeviceInformationStatics statics = { &statics_vtbl };

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
