/* Tiny real-process fixtures for the app's job helper; no application install. */
#include <windows.h>
#include <wchar.h>

static int spawn(const WCHAR *mode, BOOL wait)
{
    WCHAR self[MAX_PATH], line[MAX_PATH + 32];
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION child = {0};
    startup.cb = sizeof(startup);
    GetModuleFileNameW(NULL, self, MAX_PATH);
    swprintf(line, MAX_PATH + 32, L"\"%ls\" %ls", self, mode);
    if (!CreateProcessW(NULL, line, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &child)) return 1;
    if (wait) WaitForSingleObject(child.hProcess, INFINITE);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    return 0;
}

int wmain(int argc, WCHAR **argv)
{
    int status;
    if (argc < 2) return 2;
    if (!wcscmp(argv[1], L"handoff")) return spawn(L"late", FALSE);
    if (!wcscmp(argv[1], L"nested")) return spawn(L"handoff", FALSE);
    if (!wcscmp(argv[1], L"success")) return spawn(L"done", FALSE);
    if (!wcscmp(argv[1], L"supervised")) return spawn(L"fail", TRUE);
    if (!wcscmp(argv[1], L"starter-error"))
    {
        status = spawn(L"late", FALSE);
        return status ? status : 7;
    }
    if (!wcscmp(argv[1], L"handoff-reboot"))
    {
        status = spawn(L"late", FALSE);
        return status ? status : ERROR_SUCCESS_REBOOT_REQUIRED;
    }
    if (!wcscmp(argv[1], L"wide-exit")) return 1603;
    if (!wcscmp(argv[1], L"reboot")) return ERROR_SUCCESS_REBOOT_REQUIRED;
    if (!wcscmp(argv[1], L"late") || !wcscmp(argv[1], L"done")) Sleep(500);
    return !wcscmp(argv[1], L"done") ? 0 : 41;
}
