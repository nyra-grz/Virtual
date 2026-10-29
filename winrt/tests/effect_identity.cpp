/* Regression: the factory's IUnknown and ID2D1EffectImpl may be distinct COM
 * pointers, as with managed effects. Exercise initialization, bound properties,
 * device feature reporting and balanced destruction through the real D2D API. */
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <d2d1_1.h>
#include <d2d1effectauthor.h>
#include <stdio.h>
static int checks, failures, initialized, destroyed, callbacks;
static IUnknown *identity;
static void check(bool ok, const char *what) { ++checks; if (!ok) {++failures; printf("FAIL: %s\n",what);} }
static const GUID effect_id={0x50f528a1,0xca11,0x41c9,{0x93,0x2b,0x40,0x2a,0xa1,0x71,0x43,0x19}};
class Effect;
class Identity final : public IUnknown {
public:
    Effect *owner;
    explicit Identity(Effect *o):owner(o){}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void **) override;
    ULONG STDMETHODCALLTYPE AddRef() override;
    ULONG STDMETHODCALLTYPE Release() override;
};
class Effect final : public ID2D1EffectImpl {
public:
    LONG refs=1; UINT32 value=42; Identity id;
    Effect():id(this){}
    ~Effect(){++destroyed;}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void **out) override {
        *out=nullptr;
        if (IsEqualIID(iid,IID_IUnknown)) *out=static_cast<IUnknown *>(&id);
        else if (IsEqualIID(iid,IID_ID2D1EffectImpl)) *out=static_cast<ID2D1EffectImpl *>(this);
        else return E_NOINTERFACE;
        AddRef(); return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override {return InterlockedIncrement(&refs);}
    ULONG STDMETHODCALLTYPE Release() override {ULONG r=InterlockedDecrement(&refs);if(!r)delete this;return r;}
    HRESULT STDMETHODCALLTYPE Initialize(ID2D1EffectContext *ctx,ID2D1TransformGraph *graph) override {
        ++initialized;
        D3D_FEATURE_LEVEL levels[]={D3D_FEATURE_LEVEL_9_1,D3D_FEATURE_LEVEL_12_1,D3D_FEATURE_LEVEL_10_0};
        D3D_FEATURE_LEVEL actual=static_cast<D3D_FEATURE_LEVEL>(0);
        check(ctx->GetMaximumSupportedFeatureLevel(levels,3,&actual)==S_OK,"effect queries real feature level");
        check(actual>=D3D_FEATURE_LEVEL_9_1 && actual<=D3D_FEATURE_LEVEL_10_0,"maximum candidate selected");
        check(ctx->GetMaximumSupportedFeatureLevel(nullptr,0,&actual)==E_INVALIDARG,"invalid feature list rejected");
        D3D_FEATURE_LEVEL impossible[]={D3D_FEATURE_LEVEL_12_1};
        check(ctx->GetMaximumSupportedFeatureLevel(impossible,1,&actual)==D2DERR_INSUFFICIENT_DEVICE_CAPABILITIES,"unsupported candidate rejected");
        graph->Clear(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE PrepareForRender(D2D1_CHANGE_TYPE) override {return S_OK;}
    HRESULT STDMETHODCALLTYPE SetGraph(ID2D1TransformGraph *) override {return E_NOTIMPL;}
};
HRESULT STDMETHODCALLTYPE Identity::QueryInterface(REFIID i,void **o){return owner->QueryInterface(i,o);}
ULONG STDMETHODCALLTYPE Identity::AddRef(){return owner->AddRef();}
ULONG STDMETHODCALLTYPE Identity::Release(){return owner->Release();}
static HRESULT CALLBACK create(IUnknown **out){Effect *e=new Effect;*out=&e->id;identity=*out;check(static_cast<void *>(*out)!=static_cast<void *>(static_cast<ID2D1EffectImpl *>(e)),"factory returns a distinct IUnknown");return S_OK;}
static HRESULT CALLBACK get(const IUnknown *u,BYTE *data,UINT32 size,UINT32 *actual){
    ++callbacks;check(u!=identity,"getter receives typed implementation interface");if(actual)*actual=4;if(!data)return S_OK;if(size<4)return E_INVALIDARG;
    const Effect *e=static_cast<const Effect *>(static_cast<const ID2D1EffectImpl *>(u));CopyMemory(data,&e->value,4);return S_OK;
}
static HRESULT CALLBACK set(IUnknown *u,const BYTE *data,UINT32 size){++callbacks;check(u!=identity,"setter receives typed implementation interface");if(!data||size!=4)return E_INVALIDARG;CopyMemory(&static_cast<Effect *>(static_cast<ID2D1EffectImpl *>(u))->value,data,4);return S_OK;}
int main(){
    ID3D11Device *d3d=nullptr;IDXGIDevice *dxgi=nullptr;ID2D1Factory1 *f=nullptr;ID2D1Device *device=nullptr;ID2D1DeviceContext *context=nullptr;ID2D1Effect *effect=nullptr;
    D3D_FEATURE_LEVEL level;
    HRESULT hr=D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&d3d,&level,nullptr);
    check(SUCCEEDED(hr),"D3D device");if(!d3d)return 1;
    hr=d3d->QueryInterface(IID_IDXGIDevice,reinterpret_cast<void **>(&dxgi));check(SUCCEEDED(hr),"DXGI interface");
    hr=D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,IID_ID2D1Factory1,nullptr,reinterpret_cast<void **>(&f));check(SUCCEEDED(hr),"D2D factory");
    if(!f||!dxgi)return 1;
    hr=f->CreateDevice(dxgi,&device);check(SUCCEEDED(hr),"D2D device");if(!device)return 1;
    hr=device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,&context);check(SUCCEEDED(hr),"D2D context");if(!context)return 1;
    D3D11_FEATURE_DATA_D3D10_X_HARDWARE_OPTIONS opts={};
    d3d->CheckFeatureSupport(D3D11_FEATURE_D3D10_X_HARDWARE_OPTIONS,&opts,sizeof(opts));
    printf("D2D_DEVICE level=%x compute4x=%d\n",level,opts.ComputeShaders_Plus_RawAndStructuredBuffers_Via_Shader_4_x);
    DXGI_FORMAT formats[]={DXGI_FORMAT_A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_R16G16B16A16_UNORM,DXGI_FORMAT_R16G16B16A16_FLOAT,DXGI_FORMAT_R32G32B32A32_FLOAT};
    for (DXGI_FORMAT format:formats) {
        UINT support=0;d3d->CheckFormatSupport(format,&support);
        printf("D2D_FORMAT %d support=%x reported=%d\n",format,support,context->IsDxgiFormatSupported(format));
        if ((support&(D3D11_FORMAT_SUPPORT_TEXTURE2D|D3D11_FORMAT_SUPPORT_SHADER_SAMPLE))==(D3D11_FORMAT_SUPPORT_TEXTURE2D|D3D11_FORMAT_SUPPORT_SHADER_SAMPLE)) {
            check(context->IsDxgiFormatSupported(format),"sampleable D2D bitmap format is reported");
            ID2D1Bitmap1 *bitmap=nullptr;D2D1_BITMAP_PROPERTIES1 properties={};
            properties.pixelFormat.format=format;properties.pixelFormat.alphaMode=D2D1_ALPHA_MODE_PREMULTIPLIED;
            D2D1_SIZE_U size={1,1};
            hr=context->CreateBitmap(size,nullptr,0,&properties,&bitmap);
            check(SUCCEEDED(hr)&&bitmap,"reported format creates a real D2D bitmap");
            if(bitmap)bitmap->Release();
        }
    }
    const WCHAR xml[]=L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Virtual identity'/><Property name='Author' type='string' value='Virtual'/><Property name='Category' type='string' value='Test'/><Property name='Description' type='string' value='COM ABI'/><Inputs/><Property name='Value' type='uint32'><Property name='Default' type='uint32' value='0'/></Property></Effect>";
    D2D1_PROPERTY_BINDING binding={L"Value",set,get};
    hr=f->RegisterEffectFromString(effect_id,xml,&binding,1,create);check(SUCCEEDED(hr),"register custom effect");
    hr=context->CreateEffect(effect_id,&effect);check(SUCCEEDED(hr)&&effect,"create split-identity effect");
    if(effect){UINT32 value=0;hr=effect->GetValue(0,D2D1_PROPERTY_TYPE_UINT32,reinterpret_cast<BYTE *>(&value),4);check(SUCCEEDED(hr)&&value==42,"getter returns implementation data");value=91;hr=effect->SetValue(0,D2D1_PROPERTY_TYPE_UINT32,reinterpret_cast<BYTE *>(&value),4);check(SUCCEEDED(hr),"bound setter");value=0;effect->GetValue(0,D2D1_PROPERTY_TYPE_UINT32,reinterpret_cast<BYTE *>(&value),4);check(value==91,"property update retained");effect->Release();}
    check(initialized==1,"typed Initialize called once");check(destroyed==1,"implementation destroyed exactly once");check(callbacks>=3,"property callbacks invoked");
    f->UnregisterEffect(effect_id);context->Release();device->Release();f->Release();dxgi->Release();d3d->Release();
    printf("EFFECT_ABI: %d/%d passed\n",checks-failures,checks);return failures!=0;
}
