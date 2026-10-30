/* Exercise shared Direct3D reflection without starting an application or GPU. */
#define COBJMACROS
#include <windows.h>
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <stdio.h>
#include "shader_reflection_data.h"
static unsigned checks, failed;
static void check(BOOL condition, const char *name, const char *what)
{
    ++checks;
    if (!condition) { ++failed; printf("FAIL %s: %s\n",name,what); }
}
int wmain(int argc, WCHAR **argv)
{
    HMODULE compiler = LoadLibraryW(argc > 1 ? argv[1] : L"d3dcompiler_47.dll");
    typedef HRESULT (WINAPI *reflect_fn)(const void *, SIZE_T, REFIID, void **);
    reflect_fn reflect = compiler ? (reflect_fn)(void *)GetProcAddress(compiler,"D3DReflect") : NULL;
    if (!reflect) { printf("Shader reflection: compiler unavailable %lu\n",GetLastError()); return 2; }
    for (unsigned int i=0;i<sizeof(cases)/sizeof(cases[0]);++i)
    {
        const struct shader_case *test=&cases[i];
        ID3D11ShaderReflection *r=NULL;
        HRESULT hr=reflect(test->data,test->size,&IID_ID3D11ShaderReflection,(void**)&r);
        D3D_FEATURE_LEVEL level=(D3D_FEATURE_LEVEL)0xdeadbeef;
        check(SUCCEEDED(hr) && r,test->name,"D3DReflect");
        if (FAILED(hr) || !r) continue;
        hr=r->lpVtbl->GetMinFeatureLevel(r,&level);
        check(hr==S_OK && level==test->level,test->name,"actual minimum feature level");
        check(r->lpVtbl->GetRequiresFlags(r)==test->flags,test->name,"actual requirements flags");
        check(r->lpVtbl->GetMinFeatureLevel(r,NULL)==E_INVALIDARG,test->name,"null output rejected");
        r->lpVtbl->Release(r);
    }
    FreeLibrary(compiler);
    printf("SHADER_REFLECTION: %u/%u passed, %u-bit\n",checks-failed,checks,(unsigned)(sizeof(void*)*8));
    return failed!=0;
}
