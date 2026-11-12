/* Virtual: Kosten häufiger Windows-Aufrufe unter Wine messen (ns pro Aufruf). */
#include <windows.h>
#include <stdio.h>
static LARGE_INTEGER freq;
static double now_ns(void) { LARGE_INTEGER c; QueryPerformanceCounter(&c); return (double)c.QuadPart * 1e9 / (double)freq.QuadPart; }
#define BENCH(name, n, stmt) do { volatile ULONGLONG sink = 0; double t0 = now_ns(); for (int i = 0; i < (n); i++) { stmt; } double t1 = now_ns(); \
    printf("%-32s %9.1f ns\n", name, (t1 - t0) / (n)); (void)sink; } while (0)
int main(int argc, char **argv)
{
    LARGE_INTEGER c; MSG msg; POINT pt; HANDLE ev = CreateEventW(NULL, TRUE, TRUE, NULL);
    QueryPerformanceFrequency(&freq);
    printf("QPC-Frequenz: %lld Hz\n", (long long)freq.QuadPart);
    /* Monotonie und Auflösung */
    { LONGLONG prev = 0, back = 0, minstep = 0x7fffffffffffffffLL; for (int i = 0; i < 2000000; i++) { QueryPerformanceCounter(&c);
        if (c.QuadPart < prev) back++; else if (c.QuadPart > prev && prev && c.QuadPart - prev < minstep) minstep = c.QuadPart - prev; prev = c.QuadPart; }
      printf("QPC rueckwaerts: %lld, kleinster Schritt: %lld Ticks\n", (long long)back, (long long)minstep); }
    BENCH("QueryPerformanceCounter", 2000000, QueryPerformanceCounter(&c); sink += c.QuadPart);
    BENCH("GetTickCount64", 2000000, sink += GetTickCount64());
    { FILETIME ft; BENCH("GetSystemTimePreciseAsFileTime", 1000000, GetSystemTimePreciseAsFileTime(&ft); sink += ft.dwLowDateTime); }
    BENCH("WaitForSingleObject(signal.)", 500000, sink += WaitForSingleObject(ev, 0));
    BENCH("SetEvent", 500000, sink += SetEvent(ev));
    BENCH("SwitchToThread", 200000, sink += SwitchToThread());
    BENCH("Sleep(0)", 200000, Sleep(0));
    BENCH("PeekMessageW (leer)", 200000, sink += PeekMessageW(&msg, NULL, 0, 0, PM_NOREMOVE));
    BENCH("GetAsyncKeyState", 200000, sink += GetAsyncKeyState(VK_SPACE));
    BENCH("GetCursorPos", 200000, GetCursorPos(&pt); sink += pt.x);
    BENCH("GetCurrentThreadId", 2000000, sink += GetCurrentThreadId());
    BENCH("TlsGetValue", 2000000, sink += (ULONG_PTR)TlsGetValue(0));
    return 0;
}
