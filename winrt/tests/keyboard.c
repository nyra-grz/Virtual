/* Regression for Wine upstream 3b1ab640: HKL low word is the user locale,
 * not necessarily the language of the Mac's current input source. */
#include <windows.h>
#include <stdio.h>
int main(void)
{
    HWND window = CreateWindowExW(0, L"STATIC", L"Virtual keyboard check", WS_OVERLAPPEDWINDOW,
                                  0, 0, 100, 100, NULL, NULL, NULL, NULL);
    HKL layouts[128], current = GetKeyboardLayout(0);
    LCID locale = GetUserDefaultLCID();
    int i, count = GetKeyboardLayoutList(128, layouts), failures = 0;
    if (count <= 0) failures++;
    for (i = 0; i < count; i++)
        if (LOWORD((ULONG_PTR)layouts[i]) != LOWORD(locale)) failures++;
    if (!ActivateKeyboardLayout(current, 0)) failures++;
    printf("Keyboard: locale=%04lx current=%p layouts=%d failures=%d\n", locale, current, count, failures);
    if (window) DestroyWindow(window);
    return failures != 0;
}
