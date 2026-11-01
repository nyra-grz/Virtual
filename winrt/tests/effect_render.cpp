/* Independent Direct2D graph, image bounds and real GPU pixel-readback tests. */
#define INITGUID
#include <cmath>
#include <cstdio>
#include <d2d1_1.h>
#include <d2d1effectauthor.h>
#include <d2d1effects.h>
#include <d3d11.h>
#include <windows.h>
static int checks, failures, prepares, destroyed;
static D2D1_CHANGE_TYPE last_change;
static ID2D1DeviceContext* reentry_context;
static ID2D1Image* reentry_image;
static void check(bool ok, const char* what)
{
    ++checks;
    if (!ok)
    {
        ++failures;
        printf("FAIL: %s\n", what);
    }
}
static const GUID alias_id
    = { 0x1f71ef22, 0x7f19, 0x41c6, { 0x83, 0x95, 0x28, 0x16, 0xa5, 0x68, 0xe2, 0x01 } };
class Alias final : public ID2D1EffectImpl
{
    LONG refs = 1;
    ID2D1TransformGraph* graph = nullptr;

public:
    UINT32 route = 0;
    ~Alias()
    {
        if (graph)
            graph->Release();
        ++destroyed;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override
    {
        *out = nullptr;
        if (iid != IID_IUnknown && iid != IID_ID2D1EffectImpl)
            return E_NOINTERFACE;
        *out = static_cast<ID2D1EffectImpl*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override
    {
        return InterlockedIncrement(&refs);
    }
    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG n = InterlockedDecrement(&refs);
        if (!n)
            delete this;
        return n;
    }
    HRESULT STDMETHODCALLTYPE Initialize(ID2D1EffectContext*, ID2D1TransformGraph* g) override
    {
        return SetGraph(g);
    }
    HRESULT STDMETHODCALLTYPE SetGraph(ID2D1TransformGraph* g) override
    {
        g->AddRef();
        if (graph)
            graph->Release();
        graph = g;
        return graph->SetPassthroughGraph(0);
    }
    HRESULT STDMETHODCALLTYPE PrepareForRender(D2D1_CHANGE_TYPE change) override
    {
        ++prepares;
        last_change = change;
        if (route == 99)
            return E_ABORT;
        if (route == 98)
        {
            D2D1_RECT_F r;
            return reentry_context->GetImageLocalBounds(reentry_image, &r);
        }
        return graph->SetPassthroughGraph(route);
    }
};
static HRESULT CALLBACK create(IUnknown** out)
{
    *out = new Alias;
    return S_OK;
}
static HRESULT CALLBACK set(IUnknown* u, const BYTE* d, UINT32 n)
{
    if (!d || n != 4)
        return E_INVALIDARG;
    CopyMemory(&static_cast<Alias*>(static_cast<ID2D1EffectImpl*>(u))->route, d, 4);
    return S_OK;
}
static HRESULT CALLBACK get(const IUnknown* u, BYTE* d, UINT32 n, UINT32* actual)
{
    if (actual)
        *actual = 4;
    if (!d)
        return S_OK;
    if (n < 4)
        return E_INVALIDARG;
    CopyMemory(d, &static_cast<const Alias*>(static_cast<const ID2D1EffectImpl*>(u))->route, 4);
    return S_OK;
}
static bool rect_is(D2D1_RECT_F r, float l, float t, float right, float b)
{
    return fabsf(r.left - l) < .001f && fabsf(r.top - t) < .001f && fabsf(r.right - right) < .001f
        && fabsf(r.bottom - b) < .001f;
}
static void route(ID2D1Effect* e, UINT32 n)
{
    check(SUCCEEDED(e->SetValue(0, D2D1_PROPERTY_TYPE_UINT32, reinterpret_cast<BYTE*>(&n), 4)),
        "property set");
}
static ID2D1Image* output(ID2D1Effect* e)
{
    ID2D1Image* i = nullptr;
    e->GetOutput(&i);
    return i;
}
static void sample(
    ID2D1Bitmap1* target, ID2D1Bitmap1* readback, UINT x, UINT y, UINT32 expected, const char* what)
{
    HRESULT h = readback->CopyFromBitmap(nullptr, target, nullptr);
    check(SUCCEEDED(h), "copy rendered pixels");
    if (FAILED(h))
        return;
    D2D1_MAPPED_RECT map = { };
    h = readback->Map(D2D1_MAP_OPTIONS_READ, &map);
    check(SUCCEEDED(h), "map rendered pixels");
    if (FAILED(h))
        return;
    UINT32 actual = 0;
    CopyMemory(&actual, map.bits + y * map.pitch + x * 4, 4);
    check(actual == expected, what);
    readback->Unmap();
}
int main(int argc, char**)
{
    ID3D11Device* d3d = nullptr;
    IDXGIDevice* dxgi = nullptr;
    ID2D1Factory1* f = nullptr;
    ID2D1Device* device = nullptr;
    ID2D1DeviceContext* c = nullptr;
    HRESULT h = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &d3d, nullptr, nullptr);
    check(SUCCEEDED(h), "D3D device");
    if (!d3d)
        return 1;
    d3d->QueryInterface(IID_IDXGIDevice, reinterpret_cast<void**>(&dxgi));
    h = D2D1CreateFactory(
        D2D1_FACTORY_TYPE_MULTI_THREADED, IID_ID2D1Factory1, nullptr, reinterpret_cast<void**>(&f));
    check(SUCCEEDED(h) && dxgi, "factory and DXGI");
    if (!f || !dxgi)
        return 1;
    f->CreateDevice(dxgi, &device);
    if (!device)
        return 1;
    device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &c);
    check(c, "device context");
    if (!c)
        return 1;
    const WCHAR xml[]
        = L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='Alias "
          L"graph'/><Property name='Author' type='string' value='Virtual tests'/><Property "
          L"name='Category' type='string' value='Test'/><Property name='Description' type='string' "
          L"value='Independent graph contract'/><Inputs minimum='1' maximum='2'><Input "
          L"name='First'/><Input name='Second'/></Inputs><Property name='Route' "
          L"type='uint32'/></Effect>";
    D2D1_PROPERTY_BINDING binding = { L"Route", set, get };
    h = f->RegisterEffectFromString(alias_id, xml, &binding, 1, create);
    check(SUCCEEDED(h), "register graph implementation");
    ID2D1Effect* e = nullptr;
    c->CreateEffect(alias_id, &e);
    check(e, "effect");
    if (!e)
        return 1;
    D2D1_BITMAP_PROPERTIES1 bp = { };
    bp.pixelFormat = { DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED };
    bp.dpiX = bp.dpiY = 96;
    const UINT32 green[4] = { 0xff00ff00, 0xff00ff00, 0xff00ff00, 0xff00ff00 };
    const UINT32 red[4] = { 0xffff0000, 0xffff0000, 0xffff0000, 0xffff0000 };
    ID2D1Bitmap1 *a = nullptr, *b = nullptr, *target = nullptr, *readback = nullptr,
                 *dpi_bitmap = nullptr;
    c->CreateBitmap(D2D1_SIZE_U { 2, 2 }, green, 8, &bp, &a);
    c->CreateBitmap(D2D1_SIZE_U { 2, 2 }, red, 8, &bp, &b);
    bp.dpiX = bp.dpiY = 192;
    c->CreateBitmap(D2D1_SIZE_U { 8, 4 }, nullptr, 0, &bp, &dpi_bitmap);
    bp.dpiX = bp.dpiY = 96;
    bp.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET;
    c->CreateBitmap(D2D1_SIZE_U { 16, 16 }, nullptr, 0, &bp, &target);
    bp.bitmapOptions = static_cast<D2D1_BITMAP_OPTIONS>(
        D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
    c->CreateBitmap(D2D1_SIZE_U { 16, 16 }, nullptr, 0, &bp, &readback);
    check(a && b && dpi_bitmap && target && readback, "real GPU and staging bitmaps");
    if (!a || !b || !dpi_bitmap || !target || !readback)
        return 1;
    e->SetInput(0, dpi_bitmap);
    e->SetInput(1, b);
    ID2D1Image* image = output(e);
    D2D1_RECT_F rect = { };
    c->SetTarget(target);
    h = c->GetImageLocalBounds(image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 0, 0, 4, 2), "effect local bounds preserve bitmap DPI");
    D2D1_MATRIX_3X2_F transform = { 2, 1, -1, 3, 10, -4 };
    c->SetTransform(transform);
    h = c->GetImageWorldBounds(image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 8, -4, 18, 6),
        "world bounds enclose all transformed corners");
    c->SetUnitMode(D2D1_UNIT_MODE_PIXELS);
    h = c->GetImageLocalBounds(image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 0, 0, 8, 4), "pixel unit bounds");
    h = c->GetImageWorldBounds(image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 6, -4, 26, 16), "pixel world bounds");
    c->SetUnitMode(D2D1_UNIT_MODE_DIPS);
    D2D1_MATRIX_3X2_F id = { 1, 0, 0, 1, 0, 0 };
    c->SetTransform(id);
    e->SetInput(0, a);
    D2D1_COLOR_F clear = { 0, 0, 0, 0 };
    D2D1_POINT_2F offset = { 3, 4 };
    c->BeginDraw();
    c->Clear(clear);
    c->DrawImage(image, &offset);
    h = c->EndDraw();
    check(SUCCEEDED(h), "effect output draws successfully");
    sample(target, readback, 3, 4, 0xff00ff00, "effect produces a real green pixel at offset");
    sample(target, readback, 4, 5, 0xff00ff00, "effect image extent");
    sample(target, readback, 2, 4, 0, "left outside remains clear");
    sample(target, readback, 5, 4, 0, "right outside remains clear");
    if (argc > 1)
    {
        printf("EFFECT_RENDER_BASELINE: %d/%d passed\n", checks - failures, checks);
        return failures != 0;
    }
    int before = prepares;
    c->BeginDraw();
    c->DrawImage(image, &offset);
    h = c->EndDraw();
    check(SUCCEEDED(h) && prepares == before, "unchanged effect does not repeat preparation");
    route(e, 1);
    c->BeginDraw();
    c->Clear(clear);
    c->DrawImage(image, &offset);
    h = c->EndDraw();
    check(SUCCEEDED(h) && prepares == before + 1 && (last_change & D2D1_CHANGE_TYPE_PROPERTIES),
        "property change prepares effect");
    sample(target, readback, 3, 4, 0xffff0000, "property update routes real red input");
    ID2D1Effect* chain = nullptr;
    c->CreateEffect(alias_id, &chain);
    check(chain, "second effect");
    if (!chain)
        return 1;
    chain->SetInput(0, image);
    ID2D1Image* chain_image = output(chain);
    c->BeginDraw();
    c->Clear(clear);
    c->DrawImage(chain_image, &offset);
    h = c->EndDraw();
    check(SUCCEEDED(h), "nested graph draws");
    sample(target, readback, 3, 4, 0xffff0000, "nested graph preserves source pixels");
    c->BeginDraw();
    c->Clear(clear);
    c->PushAxisAlignedClip(D2D1_RECT_F { 4, 4, 5, 6 }, D2D1_ANTIALIAS_MODE_ALIASED);
    h = c->GetImageLocalBounds(chain_image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 0, 0, 2, 2), "bounds ignore current clip");
    c->DrawImage(chain_image, &offset);
    c->PopAxisAlignedClip();
    h = c->EndDraw();
    check(SUCCEEDED(h), "clip applied to effect output");
    sample(target, readback, 3, 4, 0, "clip excludes left pixel");
    sample(target, readback, 4, 4, 0xffff0000, "clip retains right pixel");
    route(e, 0);
    e->SetInput(0, nullptr);
    h = c->GetImageLocalBounds(image, &rect);
    check(h == D2DERR_INVALID_GRAPH_CONFIGURATION, "null input detached safely");
    c->BeginDraw();
    c->DrawImage(image);
    h = c->EndDraw();
    check(h == D2DERR_INVALID_GRAPH_CONFIGURATION, "missing input reported by EndDraw");
    e->SetInput(0, a);
    route(e, 99);
    c->SetTags(123, 456);
    c->BeginDraw();
    c->DrawImage(image);
    D2D1_TAG t1 = 0, t2 = 0;
    h = c->EndDraw(&t1, &t2);
    check(h == E_ABORT && t1 == 123 && t2 == 456, "preparation failure and draw tags propagated");
    route(e, 0);
    e->SetInput(0, chain_image);
    h = c->GetImageLocalBounds(chain_image, &rect);
    check(h == D2DERR_CYCLIC_GRAPH, "graph cycle rejected without recursion");
    e->SetInput(0, a);
    c->BeginDraw();
    c->DrawImage(chain_image);
    h = c->EndDraw();
    check(SUCCEEDED(h), "context recovers after graph error");
    reentry_context = c;
    reentry_image = image;
    route(e, 98);
    h = c->GetImageLocalBounds(image, &rect);
    check(h == D2DERR_CYCLIC_GRAPH, "reentrant preparation rejected");
    route(e, 0);
    ID2D1Effect* unsupported = nullptr;
    h = c->CreateEffect(CLSID_D2D1ColorMatrix, &unsupported);
    check(SUCCEEDED(h) && unsupported, "existing unsupported graph created");
    if (unsupported)
    {
        unsupported->SetInput(0, a);
        c->BeginDraw();
        c->DrawImage(unsupported);
        h = c->EndDraw();
        check(h == E_NOTIMPL,
            "unsupported processing is reported instead of silently drawing nothing");
        unsupported->SetInput(0, nullptr);
        unsupported->Release();
    }
    check(c->GetImageLocalBounds(nullptr, &rect) == E_INVALIDARG, "null image rejected");
    check(c->GetImageWorldBounds(image, nullptr) == E_INVALIDARG, "null world bounds rejected");
    int before_matrix = prepares;
    D2D1_MATRIX_3X2_F moved = { 1, 0, 0, 1, 2, 3 };
    c->SetTransform(moved);
    h = c->GetImageWorldBounds(image, &rect);
    check(SUCCEEDED(h) && rect_is(rect, 2, 3, 4, 5) && prepares > before_matrix,
        "context transform refreshes preparation and bounds");
    c->SetTransform(id);
    ID2D1DeviceContext* other = nullptr;
    device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &other);
    check(other, "second context in the same domain");
    if (other)
    {
        ID2D1Bitmap1* other_target = nullptr;
        bp.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET;
        other->CreateBitmap(D2D1_SIZE_U { 16, 16 }, nullptr, 0, &bp, &other_target);
        if (!other_target)
            return 1;
        other->SetTarget(other_target);
        int previous_prepares = prepares;
        other->BeginDraw();
        other->Clear(clear);
        other->DrawImage(image);
        h = other->EndDraw();
        check(SUCCEEDED(h) && prepares > previous_prepares
                && (last_change & D2D1_CHANGE_TYPE_CONTEXT),
            "same-domain context change refreshes preparation");
        sample(other_target, readback, 0, 0, 0xff00ff00, "second context receives source pixels");
        other->SetTarget(nullptr);
        other_target->Release();
        other->Release();
    }
    ID2D1Device* foreign_device = nullptr;
    f->CreateDevice(dxgi, &foreign_device);
    check(foreign_device && foreign_device != device,
        "separate device creates a distinct resource domain");
    if (foreign_device)
    {
        ID2D1DeviceContext* foreign = nullptr;
        foreign_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &foreign);
        if (!foreign)
            return 1;
        h = foreign->GetImageLocalBounds(image, &rect);
        check(h == D2DERR_WRONG_RESOURCE_DOMAIN, "foreign effect domain rejected");
        foreign->Release();
        foreign_device->Release();
    }
    c->BeginDraw();
    c->DrawImage(static_cast<ID2D1Image*>(nullptr));
    h = c->EndDraw();
    check(h == E_INVALIDARG, "null draw image rejected");
    ID2D1Effect* deep[40] = { };
    ID2D1Image* deep_image[40] = { };
    ID2D1Image* previous = image;
    for (int i = 0; i < 40; i++)
    {
        c->CreateEffect(alias_id, &deep[i]);
        if (!deep[i])
            return 1;
        deep[i]->SetInput(0, previous);
        deep_image[i] = output(deep[i]);
        previous = deep_image[i];
    }
    c->BeginDraw();
    c->Clear(clear);
    c->DrawImage(previous, &offset);
    h = c->EndDraw();
    check(SUCCEEDED(h), "deep graph is not limited to a small fixed stack");
    sample(target, readback, 3, 4, 0xff00ff00, "deep graph pixel readback");
    for (int i = 39; i >= 0; i--)
    {
        deep[i]->SetInput(0, nullptr);
        deep_image[i]->Release();
        deep[i]->Release();
    }
    chain->SetInput(0, nullptr);
    e->SetInput(0, nullptr);
    e->SetInput(1, nullptr);
    chain_image->Release();
    chain->Release();
    image->Release();
    e->Release();
    check(destroyed == 42, "graph implementations released exactly once");
    c->SetTarget(nullptr);
    a->Release();
    b->Release();
    dpi_bitmap->Release();
    target->Release();
    readback->Release();
    c->Release();
    device->Release();
    f->UnregisterEffect(alias_id);
    f->Release();
    dxgi->Release();
    d3d->Release();
    printf("EFFECT_RENDER: %d/%d passed\n", checks - failures, checks);
    return failures != 0;
}
