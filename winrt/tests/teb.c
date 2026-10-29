/* Direct TEB access is part of the Windows ABI, used by Qt, CRTs and fibers.
 * Run unchanged on Windows and Virtual; do not substitute API calls for the
 * inline accesses under test. No app-specific DLLs or headers required. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static LONG checks, failures;
static DWORD tls_index;
static HANDLE ready;

#ifdef _WIN64
#define READ_SEG(off, value) __asm__ volatile("movq %%gs:%c1,%0" : "=r"(value) : "i"(off))
#define SELF 0x30
#define PID 0x40
#define TID 0x48
#define LAST_ERROR 0x68
#define STACK_BASE 0x08
#define STACK_LIMIT 0x10
#define FIBER 0x20
#else
#define READ_SEG(off, value) __asm__ volatile("movl %%fs:%c1,%0" : "=r"(value) : "i"(off))
#define SELF 0x18
#define PID 0x20
#define TID 0x24
#define LAST_ERROR 0x34
#define STACK_BASE 0x04
#define STACK_LIMIT 0x08
#define FIBER 0x10
#endif

static void check(int pass, const char *label)
{
    InterlockedIncrement(&checks);
    if (!pass && InterlockedIncrement(&failures) <= 8) printf("FAIL: %s\n", label);
}

static void inspect(void)
{
    uintptr_t self, pid, tid, base, limit;
    DWORD error;
    READ_SEG(SELF, self);
    READ_SEG(PID, pid);
    READ_SEG(TID, tid);
    READ_SEG(STACK_BASE, base);
    READ_SEG(STACK_LIMIT, limit);
    check(self == (uintptr_t)NtCurrentTeb(), "inline Self matches NtCurrentTeb");
    check(pid == GetCurrentProcessId(), "inline process ID matches API");
    check(tid == GetCurrentThreadId(), "inline thread ID matches API");
    check(limit < (uintptr_t)&self && (uintptr_t)&self < base, "inline stack bounds contain current stack");
    SetLastError(0x1234abcd);
#ifdef _WIN64
    __asm__ volatile("movl %%gs:%c1,%0" : "=r"(error) : "i"(LAST_ERROR));
#else
    __asm__ volatile("movl %%fs:%c1,%0" : "=r"(error) : "i"(LAST_ERROR));
#endif
    check(error == 0x1234abcd, "inline LastError matches SetLastError");
    check(GetLastError() == 0x1234abcd, "inline read preserves LastError");
}

static DWORD WINAPI worker(void *arg)
{
    int i;
    if (WaitForSingleObject(ready, 5000) != WAIT_OBJECT_0) return 1;
    TlsSetValue(tls_index, arg);
    for (i = 0; i < 32; i++)
    {
        inspect();
        check(TlsGetValue(tls_index) == arg, "TLS remains private across system calls");
        Sleep(0);
    }
    return 0;
}

static void *primary_fiber;
static void WINAPI fiber_proc(void *arg)
{
    uintptr_t fiber;
    READ_SEG(FIBER, fiber);
    check(fiber == *(uintptr_t *)((char *)NtCurrentTeb() + FIBER), "inline fiber pointer matches TEB");
    if (fiber && fiber == *(uintptr_t *)((char *)NtCurrentTeb() + FIBER))
        check(*(void **)fiber == arg, "inline fiber data matches argument");
    inspect();
    SwitchToFiber(primary_fiber);
}

static LRESULT CALLBACK window_proc(HWND window, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_APP)
    {
        inspect();
        return 0x4321;
    }
    return DefWindowProcW(window, msg, wp, lp);
}

int main(void)
{
    HANDLE threads[8]; DWORD status; int i;
    WNDCLASSW cls = {0}; HWND window; void *fiber;
    uintptr_t inline_fiber;
    inspect();
    tls_index = TlsAlloc();
    ready = CreateEventW(NULL, TRUE, FALSE, NULL);
    check(tls_index != TLS_OUT_OF_INDEXES && ready != NULL, "worker prerequisites");
    if (tls_index == TLS_OUT_OF_INDEXES || !ready) return 1;
    for (i = 0; i < 8; i++)
    {
        threads[i] = CreateThread(NULL, 0, worker, (void *)(uintptr_t)(i + 1), 0, NULL);
        check(threads[i] != NULL, "create worker");
    }
    SetEvent(ready);
    for (i = 0; i < 8; i++) if (threads[i])
    {
        check(WaitForSingleObject(threads[i], 10000) == WAIT_OBJECT_0, "worker finishes");
        GetExitCodeThread(threads[i], &status);
        check(status == 0, "worker succeeds");
        CloseHandle(threads[i]);
    }
    TlsFree(tls_index); CloseHandle(ready);
    primary_fiber = ConvertThreadToFiber((void *)(uintptr_t)0xabcdef);
    check(primary_fiber != NULL, "convert thread to fiber");
    if (primary_fiber)
    {
        READ_SEG(FIBER, inline_fiber);
        check(inline_fiber == (uintptr_t)primary_fiber, "inline primary fiber pointer");
        if (inline_fiber == (uintptr_t)primary_fiber)
            check(*(void **)inline_fiber == (void *)(uintptr_t)0xabcdef, "inline primary fiber data");
        fiber = CreateFiber(0, fiber_proc, (void *)(uintptr_t)0x123456);
        check(fiber != NULL, "create fiber");
        if (fiber) { SwitchToFiber(fiber); DeleteFiber(fiber); }
        READ_SEG(FIBER, inline_fiber);
        check(inline_fiber == (uintptr_t)primary_fiber, "primary fiber pointer restored");
        check(ConvertFiberToThread(), "convert fiber back to thread");
    }
    cls.hInstance = GetModuleHandleW(NULL); cls.lpszClassName = L"VirtualTebProbe";
    cls.lpfnWndProc = window_proc;
    check(RegisterClassW(&cls) != 0, "register callback window");
    window = CreateWindowW(cls.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, cls.hInstance, NULL);
    check(window != NULL, "create callback window");
    if (window)
    {
        check(SendMessageW(window, WM_APP, 0, 0) == 0x4321, "user callback returns with correct ABI");
        DestroyWindow(window);
    }
    UnregisterClassW(cls.lpszClassName, cls.hInstance);
    inspect();
    printf("teb: %ld checks, %ld failures, %u-bit\n", checks, failures, (unsigned)(sizeof(void *) * 8));
    return failures != 0;
}
