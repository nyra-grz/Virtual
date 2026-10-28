/* Minimal Electron/Node-like images for command-line compatibility tests.
 * The .def file decides whether the image exposes Electron's fuse API, Node's
 * registration entry alone, or neither. No real browser installation needed. */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

void probe_napi_register(void) {}
BOOL probe_electron_fuse(void) { return TRUE; }

static int run_node_child(void)
{
    WCHAR path[MAX_PATH], command[MAX_PATH + 64];
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION child = {0};
    DWORD status = 1;
    startup.cb = sizeof(startup);
    SetEnvironmentVariableW(L"ELECTRON_RUN_AS_NODE", L"1");
    GetModuleFileNameW(NULL, path, MAX_PATH);
    swprintf(command, MAX_PATH + 64, L"\"%ls\" --expect-plain", path);
    if (!CreateProcessW(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child)) return 2;
    if (WaitForSingleObject(child.hProcess, 10000) == WAIT_OBJECT_0)
        GetExitCodeProcess(child.hProcess, &status);
    else
        TerminateProcess(child.hProcess, 3);
    CloseHandle(child.hProcess);
    CloseHandle(child.hThread);
    return status;
}

int wmain(int argc, WCHAR **argv)
{
    int i, gpu = 0, sandbox = 0, expected = -1, spawn = 0;
    for (i = 1; i < argc; ++i)
    {
        if (!wcscmp(argv[i], L"--in-process-gpu")) ++gpu;
        if (!wcscmp(argv[i], L"--no-sandbox")) ++sandbox;
        if (!wcscmp(argv[i], L"--expect-compat")) expected = 1;
        if (!wcscmp(argv[i], L"--expect-plain")) expected = 0;
        if (!wcscmp(argv[i], L"--spawn-node")) spawn = 1;
    }
    if (expected < 0 || gpu != expected || sandbox != expected)
    {
        printf("CHROMIUM_OPTIONS: expected=%d gpu=%d sandbox=%d FAIL\n", expected, gpu, sandbox);
        return 1;
    }
    if (spawn)
    {
        int status = run_node_child();
        if (status) return status;
    }
    printf("CHROMIUM_OPTIONS: expected=%d gpu=%d sandbox=%d passed\n", expected, gpu, sandbox);
    return 0;
}
