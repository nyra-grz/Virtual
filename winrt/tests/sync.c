/* Synchronisations-Messung: zwei Threads werfen sich ein Event zu (Ping-Pong), dazu
 * Mutex- und Semaphor-Runden. Ohne msync geht jede Runde über den wineserver; mit
 * WINEMSYNC=1 über Mach-Semaphoren. Gibt die Zeit pro Runde aus und prüft die Korrektheit. */
#include <windows.h>
#include <stdio.h>

#define ROUNDS 100000
static HANDLE ping, pong;
static volatile LONG counter;

static DWORD WINAPI partner(void *arg)
{
    for (int i = 0; i < ROUNDS; i++) {
        WaitForSingleObject(ping, INFINITE);
        InterlockedIncrement(&counter);
        SetEvent(pong);
    }
    return 0;
}

static double now_us(void)
{
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return t.QuadPart * 1e6 / f.QuadPart;
}

int main(void)
{
    int failures = 0;
    HANDLE thread, mutex, sem;
    double start, pingpong, locks;

    ping = CreateEventW(NULL, FALSE, FALSE, NULL);
    pong = CreateEventW(NULL, FALSE, FALSE, NULL);
    thread = CreateThread(NULL, 0, partner, NULL, 0, NULL);
    start = now_us();
    for (int i = 0; i < ROUNDS; i++) {
        SetEvent(ping);
        WaitForSingleObject(pong, INFINITE);
    }
    pingpong = (now_us() - start) / ROUNDS;
    WaitForSingleObject(thread, INFINITE);
    if (counter != ROUNDS) failures++;

    mutex = CreateMutexW(NULL, FALSE, NULL);
    sem = CreateSemaphoreW(NULL, 0, 1, NULL);
    start = now_us();
    for (int i = 0; i < ROUNDS; i++) {
        if (WaitForSingleObject(mutex, 0) != WAIT_OBJECT_0) failures++;
        ReleaseMutex(mutex);
        ReleaseSemaphore(sem, 1, NULL);
        if (WaitForSingleObject(sem, 0) != WAIT_OBJECT_0) failures++;
    }
    locks = (now_us() - start) / ROUNDS;
    /* Zeitlimit muss weiterhin greifen */
    if (WaitForSingleObject(sem, 50) != WAIT_TIMEOUT) failures++;

    printf("Sync: Ping-Pong %.2f us/Runde, Mutex+Semaphor %.2f us/Runde, failures=%d\n", pingpong, locks, failures);
    return failures != 0;
}
