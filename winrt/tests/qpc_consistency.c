#include <windows.h>
#include <stdio.h>
typedef LONG (WINAPI *NtQPC)(LARGE_INTEGER *, LARGE_INTEGER *);
int main(void)
{
    NtQPC nt = (NtQPC)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryPerformanceCounter");
    LARGE_INTEGER a, b, c, f, prev = {0}; long long bad = 0, back = 0, maxgap = 0;
    QueryPerformanceFrequency(&f);
    for (int i = 0; i < 1000000; i++) {
        QueryPerformanceCounter(&a); nt(&b, NULL); QueryPerformanceCounter(&c);
        if (!(a.QuadPart <= b.QuadPart && b.QuadPart <= c.QuadPart)) bad++;
        if (a.QuadPart < prev.QuadPart) back++;
        if (c.QuadPart - a.QuadPart > maxgap) maxgap = c.QuadPart - a.QuadPart;
        prev = c;
    }
    printf("Frequenz %lld, Reihenfolge verletzt: %lld, rueckwaerts: %lld, groesster Abstand: %lld Ticks\n", (long long)f.QuadPart, bad, back, maxgap);
    QueryPerformanceCounter(&a); nt(&b, NULL); printf("schnell=%lld  Systemaufruf=%lld  Differenz=%lld\n", (long long)a.QuadPart, (long long)b.QuadPart, (long long)(b.QuadPart - a.QuadPart));
    return 0;
}
