/* Preserve Win32 topmost/ownership semantics while macOS owns native planes.
 * These are hidden windows belonging only to this test process. */
#include <windows.h>
#include <stdio.h>
static unsigned checks, failures;
static void check(BOOL ok, const char *name)
{
    ++checks;
    if (!ok) { ++failures; printf("FAIL: %s (%lu)\n", name, GetLastError()); }
}
int main(void)
{
    WNDCLASSW cls = {0};
    HWND owner, dialog;
    RECT before, after;
    cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = L"VirtualWindowOrderTest";
    check(RegisterClassW(&cls) != 0, "register test class");
    owner = CreateWindowExW(0, cls.lpszClassName, L"Owner", WS_OVERLAPPEDWINDOW,
            20, 20, 320, 200, NULL, NULL, cls.hInstance, NULL);
    check(owner != NULL, "create hidden owner");
    if (!owner) return 1;
    dialog = CreateWindowExW(WS_EX_DLGMODALFRAME, cls.lpszClassName, L"Owned dialog",
            WS_POPUP | WS_CAPTION, 40, 40, 160, 100, owner, NULL, cls.hInstance, NULL);
    check(dialog != NULL, "create hidden owned dialog");
    check(GetWindow(dialog, GW_OWNER) == owner, "owned-window relation preserved");
    GetWindowRect(owner, &before);
    check(SetWindowPos(owner, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE), "topmost operation retained");
    check((GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0,
            "Win32 topmost flag retained");
    GetWindowRect(owner, &after);
    check(EqualRect(&before, &after), "ordering does not move or resize");
    check(SetWindowPos(owner, HWND_NOTOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE), "topmost can be removed");
    check(!(GetWindowLongPtrW(owner, GWL_EXSTYLE) & WS_EX_TOPMOST), "normal Win32 state restored");
    check(GetWindow(dialog, GW_OWNER) == owner, "owner relation survives ordering changes");
    check(!IsWindowVisible(owner) && !IsWindowVisible(dialog), "test windows stay hidden");
    if (dialog) DestroyWindow(dialog);
    DestroyWindow(owner);
    UnregisterClassW(cls.lpszClassName, cls.hInstance);
    printf("WINDOW_ORDER: %u/%u passed, %u-bit\n", checks-failures, checks,
            (unsigned)(sizeof(void *) * 8));
    return failures != 0;
}
