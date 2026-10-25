/* Keep a launched program and its descendants in one Windows job. In particular,
 * Wine's start /wait can return before a .lnk target exits. Closing this helper's
 * job handle terminates only this launch, including detached shortcut children. */
#include <windows.h>
#include <stdio.h>
#include <exdisp.h>
#include <wchar.h>

static WCHAR *command_line(int argc, WCHAR **argv)
{
    SIZE_T size = 1;
    int i;
    WCHAR *line, *out;
    for (i = 1; i < argc; ++i) size += 2 * wcslen(argv[i]) + 3;
    line = HeapAlloc(GetProcessHeap(), 0, size * sizeof(WCHAR));
    if (!line) return NULL;
    out = line;
    for (i = 1; i < argc; ++i)
    {
        const WCHAR *p = argv[i];
        if (i > 1) *out++ = L' ';
        /* Some Windows installers inspect GetCommandLine rather than argv.
         * Keep plain switches such as NSIS /S plain; quote only when needed. */
        if (*p && !wcspbrk(p, L" \t\r\n\v\f\""))
        {
            while (*p) *out++ = *p++;
            continue;
        }
        *out++ = L'"';
        for (;;)
        {
            SIZE_T slashes = 0, n;
            while (*p == L'\\') { ++slashes; ++p; }
            n = (*p == L'"' || !*p) ? 2 * slashes : slashes;
            while (n--) *out++ = L'\\';
            if (!*p) break;
            if (*p == L'"') *out++ = L'\\';
            *out++ = *p++;
        }
        *out++ = L'"';
    }
    *out = 0;
    return line;
}

int wmain(int argc, WCHAR **argv)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION child = {0};
    HANDLE job;
    WCHAR *line;
    DWORD status = 1;
    if (argc < 2 || !(line = command_line(argc, argv))) return 2;
    /* Start shared shell/COM services outside the application's job. Wine can
     * otherwise attach its lazily started rpcss/desktop to a shortcut's job. */
    IUnknown *shell = NULL;
    HRESULT com = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(com)) {
        CoCreateInstance(&CLSID_ShellWindows, NULL, CLSCTX_LOCAL_SERVER, &IID_IUnknown, (void **)&shell);
        if (shell) shell->lpVtbl->Release(shell);
        CoUninitialize();
    }
    job = CreateJobObjectW(NULL, NULL);
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
    {
        fputs("Windows-Prozessgruppe konnte nicht angelegt werden.\n", stderr);
        if (job) CloseHandle(job);
        HeapFree(GetProcessHeap(), 0, line);
        return 1;
    }
    startup.cb = sizeof(startup);
    if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &startup, &child))
        fprintf(stderr, "Programmstart fehlgeschlagen (Windows-Fehler %lu).\n", GetLastError());
    else if (!AssignProcessToJobObject(job, child.hProcess))
    {
        fputs("Programm konnte der Windows-Prozessgruppe nicht zugeordnet werden.\n", stderr);
        TerminateProcess(child.hProcess, 1);
    }
    else
    {
        ResumeThread(child.hThread);
        WaitForSingleObject(child.hProcess, INFINITE);
        GetExitCodeProcess(child.hProcess, &status);
        /* A shell shortcut can spawn another process and exit immediately. */
        while (QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), NULL)
               && accounting.ActiveProcesses) Sleep(50);
    }
    if (child.hThread) CloseHandle(child.hThread);
    if (child.hProcess) CloseHandle(child.hProcess);
    CloseHandle(job);
    HeapFree(GetProcessHeap(), 0, line);
    /* Preserve Windows' 32-bit result; the host process exit status only keeps
     * the low byte (for example, MSI success-with-reboot 3010 becomes 194). */
    printf("\nVIRTUAL_EXIT_CODE=%lu\n", status);
    return status;
}
