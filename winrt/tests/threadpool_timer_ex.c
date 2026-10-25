/* Standalone Win32 conformance probe. No app-specific workarounds.
 * Build with x86_64-w64-mingw32-gcc or i686-w64-mingw32-gcc. */
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stdio.h>

typedef BOOL (WINAPI *set_timer_ex_fn)(PTP_TIMER, FILETIME *, DWORD, DWORD);
static int checks, failures;
static HANDLE entered, release_callback;
static LONG callbacks;
static void check(int condition, const char *name)
{
    ++checks;
    if (!condition) { ++failures; printf("FAIL: %s\n", name); }
}
static FILETIME relative_time(LONGLONG ticks)
{
    ULARGE_INTEGER value;
    FILETIME due;
    value.QuadPart = (ULONGLONG)-ticks;
    due.dwLowDateTime = value.LowPart;
    due.dwHighDateTime = value.HighPart;
    return due;
}
static void CALLBACK timer_callback(PTP_CALLBACK_INSTANCE instance, void *context, PTP_TIMER timer)
{
    InterlockedIncrement(&callbacks);
    SetEvent(entered);
    if (context) WaitForSingleObject(release_callback, 5000);
}
struct race_context
{
    set_timer_ex_fn set_timer_ex;
    PTP_TIMER timer;
    HANDLE gate;
    LONG callbacks, snapshot;
    BOOL cancelled;
};
static void CALLBACK race_callback(PTP_CALLBACK_INSTANCE instance, void *context, PTP_TIMER timer)
{
    struct race_context *race = context;
    InterlockedIncrement(&race->callbacks);
}
static DWORD WINAPI race_set(void *context)
{
    struct race_context *race = context;
    FILETIME immediate = {0, 0};
    WaitForSingleObject(race->gate, INFINITE);
    race->set_timer_ex(race->timer, &immediate, 0, 0);
    return 0;
}
static DWORD WINAPI race_cancel(void *context)
{
    struct race_context *race = context;
    WaitForSingleObject(race->gate, INFINITE);
    race->cancelled = race->set_timer_ex(race->timer, NULL, 0, 0);
    race->snapshot = InterlockedCompareExchange(&race->callbacks, 0, 0);
    return 0;
}
static void test_immediate_cancel_race(set_timer_ex_fn set_timer_ex)
{
    unsigned int iteration;
    int failures_before = failures, cancellations = 0;
    for (iteration = 0; iteration < 256; ++iteration)
    {
        struct race_context race = {0};
        HANDLE threads[2];
        DWORD joined;
        race.set_timer_ex = set_timer_ex;
        race.gate = CreateEventA(NULL, TRUE, FALSE, NULL);
        race.timer = CreateThreadpoolTimer(race_callback, &race, NULL);
        if (!race.gate || !race.timer) { check(0, "create race fixture"); return; }
        threads[0] = CreateThread(NULL, 0, race_set, &race, 0, NULL);
        threads[1] = CreateThread(NULL, 0, race_cancel, &race, 0, NULL);
        if (!threads[0] || !threads[1]) { check(0, "create race threads"); ExitProcess(1); }
        SetEvent(race.gate);
        joined = WaitForMultipleObjects(2, threads, TRUE, 5000);
        if (joined != WAIT_OBJECT_0) { check(0, "join race threads"); ExitProcess(1); }
        WaitForThreadpoolTimerCallbacks(race.timer, FALSE);
        if (race.cancelled)
        {
            ++cancellations;
            if (race.callbacks != race.snapshot) check(0, "TRUE cancellation prevents later immediate callback");
        }
        CloseThreadpoolTimer(race.timer);
        CloseHandle(threads[0]); CloseHandle(threads[1]); CloseHandle(race.gate);
    }
    check(failures == failures_before, "immediate-set/cancel race preserves cancellation promise (256 rounds)");
    printf("RACE: %d successful cancellations observed\n", cancellations);
}
int main(void)
{
    set_timer_ex_fn set_timer_ex = (set_timer_ex_fn)GetProcAddress(GetModuleHandleA("kernel32.dll"), "SetThreadpoolTimerEx");
    set_timer_ex_fn kernelbase_ex = (set_timer_ex_fn)GetProcAddress(GetModuleHandleA("kernelbase.dll"), "SetThreadpoolTimerEx");
    FARPROC ntdll_ex = GetProcAddress(GetModuleHandleA("ntdll.dll"), "TpSetTimerEx");
    FILETIME future = relative_time(60LL * 10000000), immediate = {0, 0};
    PTP_TIMER timer;
    BOOL result;
    check(set_timer_ex != NULL, "kernel32 exports SetThreadpoolTimerEx");
    check(kernelbase_ex != NULL, "kernelbase exports SetThreadpoolTimerEx");
    check(ntdll_ex != NULL, "ntdll exports TpSetTimerEx");
    if (!set_timer_ex || !kernelbase_ex || !ntdll_ex) return 1;
    entered = CreateEventA(NULL, TRUE, FALSE, NULL);
    release_callback = CreateEventA(NULL, TRUE, FALSE, NULL);
    check(entered != NULL && release_callback != NULL, "create synchronization events");
    if (!entered || !release_callback) return 1;
    timer = CreateThreadpoolTimer(timer_callback, NULL, NULL);
    check(timer != NULL, "create timer");
    if (!timer) return 1;
    check(!IsThreadpoolTimerSet(timer), "new timer is unset");
    check(!set_timer_ex(timer, NULL, 0, 0), "cancel unset timer returns FALSE");
    check(!set_timer_ex(timer, &future, 0, 0), "first set returns FALSE");
    check(IsThreadpoolTimerSet(timer), "timer armed");
    check(kernelbase_ex(timer, &future, 0, 0), "rearm pending timer returns TRUE through kernelbase");
    check(set_timer_ex(timer, NULL, 0, 0), "cancel pending timer returns TRUE");
    check(!IsThreadpoolTimerSet(timer), "cancel disarms timer");
    check(!set_timer_ex(timer, NULL, 0, 0), "second cancellation returns FALSE");
    check(WaitForSingleObject(entered, 100) == WAIT_TIMEOUT, "cancelled timer does not fire");
    WaitForThreadpoolTimerCallbacks(timer, FALSE);
    check(callbacks == 0, "no callbacks after cancellation");
    /* The old void API and the new API must share the same state. */
    SetThreadpoolTimer(timer, &future, 0, 0);
    check(set_timer_ex(timer, NULL, 0, 0), "old SetThreadpoolTimer state is visible to Ex");
    CloseThreadpoolTimer(timer);

    /* A callback that has begun cannot be recalled: FALSE is essential for
     * callers deciding whether it is safe to free their callback context. */
    timer = CreateThreadpoolTimer(timer_callback, (void *)1, NULL);
    check(timer != NULL, "create blocking timer");
    if (!timer) return 1;
    result = set_timer_ex(timer, &immediate, 0, 0);
    check(!result, "first immediate set returns FALSE");
    check(WaitForSingleObject(entered, 3000) == WAIT_OBJECT_0, "real callback executes");
    check(!set_timer_ex(timer, NULL, 0, 0), "running callback cannot be recalled");
    check(!IsThreadpoolTimerSet(timer), "cancel running timer disarms it");
    SetEvent(release_callback);
    WaitForThreadpoolTimerCallbacks(timer, FALSE);
    check(callbacks == 1, "exactly one callback ran");
    CloseThreadpoolTimer(timer);
    CloseHandle(entered);
    CloseHandle(release_callback);
    test_immediate_cancel_race(set_timer_ex);
    printf("THREADPOOL_TIMER_EX: %d/%d passed\n", checks - failures, checks);
    return failures != 0;
}
