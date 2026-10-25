/* Public WinRT metadata-builder ABI for MinGW releases lacking roparameterizediid.h.
 * These are callback interfaces (no IUnknown prefix), in Windows vtable order. */
#ifndef VIRTUAL_PROJECTION_ABI_H
#define VIRTUAL_PROJECTION_ABI_H
#if __has_include(<roparameterizediid.h>)
#include <roparameterizediid.h>
#else
typedef void *ROPARAMIIDHANDLE;
typedef struct IRoSimpleMetaDataBuilder IRoSimpleMetaDataBuilder;
typedef struct IRoMetaDataLocator IRoMetaDataLocator;
typedef struct IRoSimpleMetaDataBuilderVtbl {
    HRESULT (WINAPI *SetWinRtInterface)(IRoSimpleMetaDataBuilder *, GUID);
    HRESULT (WINAPI *SetDelegate)(IRoSimpleMetaDataBuilder *, GUID);
    HRESULT (WINAPI *SetInterfaceGroupSimpleDefault)(IRoSimpleMetaDataBuilder *, const WCHAR *, const WCHAR *, const GUID *);
    HRESULT (WINAPI *SetInterfaceGroupParameterizedDefault)(IRoSimpleMetaDataBuilder *, const WCHAR *, UINT32, const WCHAR **);
    HRESULT (WINAPI *SetRuntimeClassSimpleDefault)(IRoSimpleMetaDataBuilder *, const WCHAR *, const WCHAR *, const GUID *);
    HRESULT (WINAPI *SetRuntimeClassParameterizedDefault)(IRoSimpleMetaDataBuilder *, const WCHAR *, UINT32, const WCHAR **);
    HRESULT (WINAPI *SetStruct)(IRoSimpleMetaDataBuilder *, const WCHAR *, UINT32, const WCHAR **);
    HRESULT (WINAPI *SetEnum)(IRoSimpleMetaDataBuilder *, const WCHAR *, const WCHAR *);
    HRESULT (WINAPI *SetParameterizedInterface)(IRoSimpleMetaDataBuilder *, GUID, UINT32);
    HRESULT (WINAPI *SetParameterizedDelegate)(IRoSimpleMetaDataBuilder *, GUID, UINT32);
} IRoSimpleMetaDataBuilderVtbl;
struct IRoSimpleMetaDataBuilder { const IRoSimpleMetaDataBuilderVtbl *lpVtbl; };
typedef struct IRoMetaDataLocatorVtbl {
    HRESULT (WINAPI *Locate)(IRoMetaDataLocator *, const WCHAR *, IRoSimpleMetaDataBuilder *);
} IRoMetaDataLocatorVtbl;
struct IRoMetaDataLocator { const IRoMetaDataLocatorVtbl *lpVtbl; };
#define IRoSimpleMetaDataBuilder_SetParameterizedInterface(p, guid, n) ((p)->lpVtbl->SetParameterizedInterface((p), (guid), (n)))
#endif
#ifndef RO_E_METADATA_NAME_NOT_FOUND
#define RO_E_METADATA_NAME_NOT_FOUND ((HRESULT)0x8000000f)
#endif
#endif
