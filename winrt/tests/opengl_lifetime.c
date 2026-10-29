#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
static int checks,failures;
static void check(int p,const char*s){checks++;if(!p){failures++;printf("FAIL: %s\n",s);}}
int main(void){int i;for(i=0;i<3;i++){
 HMODULE module=LoadLibraryW(L"opengl32.dll");HGLRC(WINAPI *create)(HDC);BOOL(WINAPI *make)(HDC,HGLRC), (WINAPI *del)(HGLRC);HGLRC(WINAPI *current)(void);const GLubyte *(WINAPI *get_string)(GLenum);HWND window;HDC dc;HGLRC rc;int fmt;
 PIXELFORMATDESCRIPTOR pfd={0},actual;
 pfd.nSize=sizeof(pfd);pfd.nVersion=1;pfd.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER;pfd.iPixelType=PFD_TYPE_RGBA;pfd.cColorBits=32;pfd.cDepthBits=24;pfd.cStencilBits=8;

 check(module!=NULL,"load renderer");if(!module)return 1;
 create=(void*)GetProcAddress(module,"wglCreateContext");make=(void*)GetProcAddress(module,"wglMakeCurrent");del=(void*)GetProcAddress(module,"wglDeleteContext");current=(void*)GetProcAddress(module,"wglGetCurrentContext");get_string=(void*)GetProcAddress(module,"glGetString");
 window=CreateWindowW(L"STATIC",L"Virtual OpenGL lifetime",WS_OVERLAPPEDWINDOW,0,0,64,64,NULL,NULL,NULL,NULL);dc=GetDC(window);fmt=ChoosePixelFormat(dc,&pfd);check(fmt!=0,"GDI chooses pixel format");check(SetPixelFormat(dc,fmt,&pfd),"GDI sets pixel format");check(GetPixelFormat(dc)==fmt,"GDI returns pixel format");check(DescribePixelFormat(dc,fmt,sizeof(actual),&actual)>0,"GDI describes format");
 rc=create(dc);check(rc!=NULL&&make(dc,rc),"current context");if(rc){check(get_string(GL_VERSION)!=NULL,"actual current-context version query");check(SwapBuffers(dc),"GDI swaps buffers");check(del(rc),"delete current context");check(current()==NULL,"deletion unbinds context");}
 ReleaseDC(window,dc);DestroyWindow(window);check(FreeLibrary(module),"release caller reference");check(GetModuleHandleW(L"opengl32.dll")==NULL,"GDI does not pin renderer after probe");
 }
 printf("OPENGL_LIFETIME: %d/%d passed\n",checks-failures,checks);return failures!=0;
}
