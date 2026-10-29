#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <icm.h>
#include <stdio.h>
static int checks, failures;
static HRESULT (WINAPI *declare_support)(void);
static HANDLE ready;
static LONG successes, duplicates;
static void check(int p,const char *s){checks++;if(!p){failures++;printf("FAIL: %s\n",s);}}
static DWORD WINAPI worker(void *p){HRESULT hr;(void)p;WaitForSingleObject(ready,5000);hr=declare_support();if(hr==S_OK)InterlockedIncrement(&successes);else if(hr==DXGI_ERROR_ALREADY_EXISTS)InterlockedIncrement(&duplicates);return 0;}
int main(int argc,char **argv){
 HMODULE dxgi=LoadLibraryW(L"dxgi.dll"),cms=LoadLibraryW(L"mscms.dll");
 HPROFILE (WINAPI *convert)(HPROFILE,DWORD); WCHAR path[MAX_PATH];DWORD size=sizeof(path);PROFILE profile;HPROFILE h;DWORD bytes=0,again=0;BYTE *a,*b;
 declare_support=(void *)GetProcAddress(dxgi,"DXGIDeclareAdapterRemovalSupport");convert=(void *)GetProcAddress(cms,"WcsCreateIccProfile");check(declare_support&&convert,"required exports");if(!declare_support||!convert)return 1;
 if(argc>1 && argv[1][0]=='l'){
  ID3D11Device *dev=NULL;D3D_FEATURE_LEVEL level;HRESULT hr=D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&dev,&level,NULL);
  check(SUCCEEDED(hr)&&dev,"create device before declaration");if(dev){check(declare_support()==DXGI_ERROR_INVALID_CALL,"late declaration rejected");ID3D11Device_Release(dev);}
 }else{
  HANDLE threads[8];int i;ready=CreateEventW(NULL,TRUE,FALSE,NULL);
  for(i=0;i<8;i++)threads[i]=CreateThread(NULL,0,worker,NULL,0,NULL);
  SetEvent(ready);check(WaitForMultipleObjects(8,threads,TRUE,10000)==WAIT_OBJECT_0,"concurrent callers finish");
  check(successes==1&&duplicates==7,"exactly one process declaration succeeds");
  for(i=0;i<8;i++) { CloseHandle(threads[i]); }
  CloseHandle(ready);
  check(declare_support()==DXGI_ERROR_ALREADY_EXISTS,"repeat declaration rejected");
 }
 SetLastError(0);check(!convert(NULL,0)&&GetLastError()==ERROR_INVALID_HANDLE,"invalid profile rejected without exception");
 SetLastError(0);check(!convert(NULL,2)&&GetLastError()==ERROR_INVALID_PARAMETER,"reserved flags rejected");
 check(GetStandardColorSpaceProfileW(NULL,0x73524742,path,&size),"obtain real standard ICC profile");
 profile.dwType=PROFILE_FILENAME;profile.pProfileData=path;profile.cbDataSize=(lstrlenW(path)+1)*sizeof(WCHAR);h=OpenColorProfileW(&profile,PROFILE_READ,FILE_SHARE_READ,OPEN_EXISTING);check(h!=NULL,"open standard ICC");
 if(h){GetColorProfileFromHandle(h,NULL,&bytes);a=HeapAlloc(GetProcessHeap(),0,bytes);b=HeapAlloc(GetProcessHeap(),0,bytes);again=bytes;check(a&&b&&GetColorProfileFromHandle(h,a,&again),"read ICC before WCS query");
  check(!convert(h,0x10000)&&GetLastError()==ERROR_NOT_SUPPORTED,"ICC-only conversion has regular unsupported result");again=bytes;check(GetColorProfileFromHandle(h,b,&again)&&again==bytes&&!memcmp(a,b,bytes),"source ICC remains valid and unchanged");check(CloseColorProfile(h),"source handle remains owned by caller");HeapFree(GetProcessHeap(),0,a);HeapFree(GetProcessHeap(),0,b);
 }
 printf("GRAPHICS_CONTRACTS: %d/%d passed\n",checks-failures,checks);return failures!=0;
}
