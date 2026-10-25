/* Rendert mit Direct3D 9 und 11 wirklich etwas und liest das Bild zurück: Hintergrund
 * blau gelöscht, rotes Dreieck in der Mitte. Prüft damit die ganze Kette (DXVK bzw.
 * WineD3D → MoltenVK → Metal) statt nur das Anlegen eines Geräts. Bei D3D11 wird der
 * Shader zur Laufzeit mit D3DCompile übersetzt. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <stdio.h>

#define SIZE 64
static int checks, failures;
static void check(int ok, const char *what)
{
    checks++;
    if (!ok) { failures++; printf("FEHLER: %s\n", what); }
}
/* Farbe als 0xRRGGBB mit Toleranz (Rundung, sRGB) */
static int near_color(DWORD argb, DWORD rgb)
{
    for (int shift = 0; shift < 24; shift += 8)
        if (abs((int)((argb >> shift) & 0xff) - (int)((rgb >> shift) & 0xff)) > 8) return 0;
    return 1;
}

static void test_d3d9(HWND window)
{
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    D3DPRESENT_PARAMETERS pp = { SIZE, SIZE, D3DFMT_X8R8G8B8, 1 };
    IDirect3DDevice9 *dev = NULL;
    IDirect3DSurface9 *rt = NULL, *copy = NULL;
    D3DLOCKED_RECT lock;
    struct { float x, y, z, rhw; DWORD color; } tri[] = {
        { SIZE * 0.5f, SIZE * 0.1f, 0, 1, 0xffff0000 },
        { SIZE * 0.9f, SIZE * 0.9f, 0, 1, 0xffff0000 },
        { SIZE * 0.1f, SIZE * 0.9f, 0, 1, 0xffff0000 },
    };
    check(d3d != NULL, "D3D9: Direct3DCreate9");
    if (!d3d) return;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = window;
    pp.Windowed = TRUE;
    check(SUCCEEDED(IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                    D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev)), "D3D9: CreateDevice");
    if (dev) {
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0xff0000ff, 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLELIST, 1, tri, sizeof(tri[0]));
        IDirect3DDevice9_EndScene(dev);
        IDirect3DDevice9_GetRenderTarget(dev, 0, &rt);
        IDirect3DDevice9_CreateOffscreenPlainSurface(dev, SIZE, SIZE, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL);
        check(rt && copy && SUCCEEDED(IDirect3DDevice9_GetRenderTargetData(dev, rt, copy)), "D3D9: Bild zurücklesen");
        if (copy && SUCCEEDED(IDirect3DSurface9_LockRect(copy, &lock, NULL, D3DLOCK_READONLY))) {
            DWORD *row_mid = (DWORD *)((BYTE *)lock.pBits + lock.Pitch * (SIZE * 2 / 3));
            DWORD *row_top = (DWORD *)lock.pBits;
            check(near_color(row_top[1], 0x0000ff), "D3D9: Hintergrund blau");
            check(near_color(row_mid[SIZE / 2], 0xff0000), "D3D9: Dreieck rot");
            IDirect3DSurface9_UnlockRect(copy);
        }
        if (copy) IDirect3DSurface9_Release(copy);
        if (rt) IDirect3DSurface9_Release(rt);
        IDirect3DDevice9_Release(dev);
    }
    IDirect3D9_Release(d3d);
}

static const char shader[] =
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "    float2 p[3] = { float2(0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "    return float4(p[id], 0, 1);\n"
    "}\n"
    "float4 ps() : SV_Target { return float4(1, 0, 0, 1); }\n";

static void test_d3d11(void)
{
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11Texture2D *target = NULL, *staging = NULL;
    ID3D11RenderTargetView *view = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3DBlob *vs_code = NULL, *ps_code = NULL;
    D3D_FEATURE_LEVEL level;
    D3D11_TEXTURE2D_DESC desc = { SIZE, SIZE, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 },
                                  D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET };
    D3D11_VIEWPORT viewport = { 0, 0, SIZE, SIZE, 0, 1 };
    D3D11_MAPPED_SUBRESOURCE map;
    const float blue[4] = { 0, 0, 1, 1 };

    check(SUCCEEDED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                      &dev, &level, &ctx)), "D3D11: CreateDevice");
    if (!dev) return;
    check(SUCCEEDED(D3DCompile(shader, sizeof(shader) - 1, NULL, NULL, NULL, "vs", "vs_4_0", 0, 0, &vs_code, NULL)) &&
          SUCCEEDED(D3DCompile(shader, sizeof(shader) - 1, NULL, NULL, NULL, "ps", "ps_4_0", 0, 0, &ps_code, NULL)),
          "D3D11: Shader übersetzen (D3DCompile)");
    if (vs_code && ps_code) {
        ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vs_code), ID3D10Blob_GetBufferSize(vs_code), NULL, &vs);
        ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(ps_code), ID3D10Blob_GetBufferSize(ps_code), NULL, &ps);
    }
    ID3D11Device_CreateTexture2D(dev, &desc, NULL, &target);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Device_CreateTexture2D(dev, &desc, NULL, &staging);
    if (target) ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)target, NULL, &view);
    check(vs && ps && view && staging, "D3D11: Shader und Ziele anlegen");
    if (vs && ps && view && staging) {
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &view, NULL);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &viewport);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, view, blue);
        ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
        ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)target);
        if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &map))) {
            /* RGBA im Speicher → als 0x00BBGGRR gelesen; zum Vergleich umdrehen */
            DWORD top = ((DWORD *)map.pData)[1];
            DWORD mid = ((DWORD *)((BYTE *)map.pData + map.RowPitch * (SIZE * 2 / 3)))[SIZE / 2];
            #define RGB_OF(c) ((((c) & 0xff) << 16) | ((c) & 0xff00) | (((c) >> 16) & 0xff))
            check(near_color(RGB_OF(top), 0x0000ff), "D3D11: Hintergrund blau");
            check(near_color(RGB_OF(mid), 0xff0000), "D3D11: Dreieck rot");
            ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
        } else check(0, "D3D11: Bild zurücklesen");
    }
    if (view) ID3D11RenderTargetView_Release(view);
    if (staging) ID3D11Texture2D_Release(staging);
    if (target) ID3D11Texture2D_Release(target);
    if (vs) ID3D11VertexShader_Release(vs);
    if (ps) ID3D11PixelShader_Release(ps);
    if (vs_code) ID3D10Blob_Release(vs_code);
    if (ps_code) ID3D10Blob_Release(ps_code);
    ID3D11DeviceContext_Release(ctx);
    ID3D11Device_Release(dev);
    printf("D3D11 feature level %x\n", level);
}

int main(void)
{
    HWND window = CreateWindowExW(0, L"STATIC", L"Virtual D3D check", WS_OVERLAPPEDWINDOW,
                                  0, 0, SIZE, SIZE, NULL, NULL, NULL, NULL);
    test_d3d9(window);
    test_d3d11();
    if (window) DestroyWindow(window);
    printf("D3D: %d/%d\n", checks - failures, checks);
    return failures != 0;
}
