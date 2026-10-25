/* Inspect only windows owned by the current isolated Wine server. No host
 * screenshots, desktop capture, input synthesis or macOS accessibility API. */
#include <windows.h>
#include <stdio.h>
static int details;
static BOOL CALLBACK child_text(HWND window, LPARAM unused)
{
    WCHAR title[512]; char text[2048];
    (void)unused;
    if (GetWindowTextW(window, title, 512) && IsWindowVisible(window))
    {
        WideCharToMultiByte(CP_UTF8, 0, title, -1, text, sizeof(text), NULL, NULL);
        printf("control: %s\n", text);
    }
    return TRUE;
}
static BOOL CALLBACK inspect(HWND window, LPARAM unused)
{
    WCHAR title[256]; RECT rect; DWORD pid;
    char utf8[1024]; int i;
    (void)unused;
    if (!IsWindowVisible(window) || !GetWindowRect(window, &rect)) return TRUE;
    if (rect.right - rect.left < 120 || rect.bottom - rect.top < 80) return TRUE;
    GetWindowThreadProcessId(window, &pid);
    GetWindowTextW(window, title, 256);
    WideCharToMultiByte(CP_UTF8, 0, title, -1, utf8, sizeof(utf8), NULL, NULL);
    for (i = 0; utf8[i]; i++) if (utf8[i] == '\n' || utf8[i] == '\r' || utf8[i] == '|') utf8[i] = ' ';
    printf("%lu|%p|%ld|%ld|%s\n", pid, window, rect.right - rect.left, rect.bottom - rect.top, utf8);
    if (details) EnumChildWindows(window, child_text, 0);
    return TRUE;
}
int main(int argc, char **argv) { (void)argv; details = argc > 1; EnumWindows(inspect, 0); return 0; }
