/* Keep a launched program and its descendants in one Windows job. In particular,
 * Wine's start /wait can return before a .lnk target exits. Closing this helper's
 * job handle terminates only this launch, including detached shortcut children. */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <exdisp.h>
#include <wchar.h>

#define JOB_KEY 1
#define CONTROL_INTERVAL 250

struct close_control
{
    WCHAR stop[MAX_PATH], window[MAX_PATH];
    ULONGLONG next_check, force_at, watch_until, empty_since;
};

struct job_windows
{
    HANDLE job;
    BOOL request_close, visible, incomplete;
};

static BOOL CALLBACK inspect_window(HWND hwnd, LPARAM data)
{
    struct job_windows *windows = (void *)data;
    DWORD pid;
    HANDLE process;
    BOOL member = FALSE;
    RECT rect;

    if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, &rect) || IsRectEmpty(&rect)) return TRUE;
    if (!GetWindowThreadProcessId(hwnd, &pid)
            || !(process = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, pid))) return TRUE;
    IsProcessInJob(process, windows->job, &member);
    CloseHandle(process);
    if (member)
    {
        windows->visible = TRUE;
        if (windows->request_close && !GetWindow(hwnd, GW_OWNER)) PostMessageW(hwnd, WM_CLOSE, 0, 0);
    }
    return TRUE;
}

static BOOL CALLBACK inspect_desktop(WCHAR *name, LPARAM data)
{
    struct job_windows *windows = (void *)data;
    HDESK desktop = OpenDesktopW(name, 0, FALSE, DESKTOP_READOBJECTS);
    if (!desktop) windows->incomplete = TRUE;
    else
    {
        if (!EnumDesktopWindows(desktop, inspect_window, data)) windows->incomplete = TRUE;
        CloseDesktop(desktop);
    }
    return TRUE;
}

static BOOL has_job_windows(HANDLE job, BOOL request_close)
{
    struct job_windows windows = { .job = job, .request_close = request_close };
    return !EnumDesktopsW(GetProcessWindowStation(), inspect_desktop, (LPARAM)&windows)
           || windows.incomplete || windows.visible;
}

static void read_request_path(const WCHAR *name, WCHAR path[MAX_PATH])
{
    DWORD length = GetEnvironmentVariableW(name, path, MAX_PATH);
    if (!length || length >= MAX_PATH) path[0] = 0;
}

/* Return FALSE if the explicit shutdown could not be issued. The job's
 * kill-on-close limit is still a fallback when the helper exits. */
static BOOL handle_close_requests(HANDLE job, struct close_control *control)
{
    ULONGLONG now;
    if (!control->stop[0] && !control->window[0]) return TRUE;
    now = GetTickCount64();
    if (now < control->next_check) return TRUE;
    control->next_check = now + CONTROL_INTERVAL;

    if (!control->force_at && control->stop[0] && GetFileAttributesW(control->stop) != INVALID_FILE_ATTRIBUTES)
    {
        has_job_windows(job, TRUE);
        control->force_at = now + 2000;
    }
    if (control->force_at)
    {
        if (now < control->force_at) return TRUE;
        control->stop[0] = control->window[0] = 0;
        return TerminateJobObject(job, 0);
    }

    if (control->window[0] && DeleteFileW(control->window))
    {
        control->watch_until = now + 30000;
        control->empty_since = 0;
    }
    if (now < control->watch_until)
    {
        if (has_job_windows(job, FALSE)) control->empty_since = 0;
        else if (!control->empty_since) control->empty_since = now;
        else if (now - control->empty_since >= 1000)
        {
            control->stop[0] = control->window[0] = 0;
            return TerminateJobObject(job, 0);
        }
    }
    return TRUE;
}

/* Result rule: the start process decides, unless it reported success while
 * processes it handed over were still running (a bootstrapper or shortcut stub
 * starting the real installer or app). A job process whose parent had already
 * exited is such an orphan: nobody is left to judge its exit code, so the last
 * orphan that fails decides instead. Helpers that end while their parent still
 * runs are left out; their parent judged them (installers routinely run probes
 * such as reg query that fail on purpose). */
struct member
{
    DWORD pid, parent;
    HANDLE process;
};

struct launch
{
    HANDLE job;
    DWORD starter;
    BOOL starter_exited;
    struct member *members;
    SIZE_T count, capacity;
    DWORD failed_pid, failed_status;
};

static BOOL succeeded(DWORD code)
{
    return code == 0 || code == ERROR_SUCCESS_REBOOT_REQUIRED || code == ERROR_SUCCESS_REBOOT_INITIATED;
}

static SSIZE_T find_member(const struct launch *launch, DWORD pid)
{
    SIZE_T i;
    for (i = 0; i < launch->count; ++i) if (launch->members[i].pid == pid) return i;
    return -1;
}

static DWORD parent_id(HANDLE process)
{
    typedef NTSTATUS (WINAPI *query_fn)(HANDLE, PROCESSINFOCLASS, void *, ULONG, ULONG *);
    static query_fn query;
    PROCESS_BASIC_INFORMATION info;
    if (!query) query = (query_fn)(void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess");
    if (!query || query(process, ProcessBasicInformation, &info, sizeof(info), NULL) < 0) return 0;
    return (DWORD)info.InheritedFromUniqueProcessId;
}

/* Open each new job process at once: the held handle keeps its exit code readable
 * after it ends, which a later OpenProcess on the reported PID cannot promise. */
static void add_member(struct launch *launch, DWORD pid)
{
    /* Wine's IsProcessInJob needs PROCESS_QUERY_INFORMATION. A limited-query
     * handle opens successfully but fails that membership check with access
     * denied, silently dropping every child and its eventual failure. */
    struct member member = { pid, 0, OpenProcess(PROCESS_QUERY_INFORMATION | SYNCHRONIZE, FALSE, pid) };
    BOOL in_job = FALSE;
    if (member.process && (!IsProcessInJob(member.process, launch->job, &in_job) || !in_job))
    {
        CloseHandle(member.process);   /* PID already reused by an unrelated process */
        member.process = NULL;
    }
    if (member.process) member.parent = parent_id(member.process);
    if (launch->count == launch->capacity)
    {
        SIZE_T capacity = launch->capacity ? 2 * launch->capacity : 16;
        struct member *grown = launch->members
            ? HeapReAlloc(GetProcessHeap(), 0, launch->members, capacity * sizeof(*grown))
            : HeapAlloc(GetProcessHeap(), 0, capacity * sizeof(*grown));
        if (!grown)
        {
            if (member.process) CloseHandle(member.process);
            return;
        }
        launch->members = grown;
        launch->capacity = capacity;
    }
    launch->members[launch->count++] = member;
}

static void member_exited(struct launch *launch, DWORD pid)
{
    struct member member;
    DWORD code = STILL_ACTIVE;
    SSIZE_T i;
    BOOL parent_alive;
    if (pid == launch->starter)
    {
        launch->starter_exited = TRUE;
        return;
    }
    if ((i = find_member(launch, pid)) < 0) return;
    member = launch->members[i];
    launch->members[i] = launch->members[--launch->count];
    if (!member.process) return;
    if (WaitForSingleObject(member.process, 1000) == WAIT_OBJECT_0) GetExitCodeProcess(member.process, &code);
    CloseHandle(member.process);
    parent_alive = member.parent == launch->starter ? !launch->starter_exited : find_member(launch, member.parent) >= 0;
    if (member.parent && !parent_alive && code != STILL_ACTIVE && !succeeded(code))
    {
        launch->failed_pid = pid;
        launch->failed_status = code;
    }
}

static BOOL job_is_empty(HANDLE job)
{
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
    return QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), NULL)
           && !accounting.ActiveProcesses;
}

/* Job messages arrive in event order, so the member list always shows which
 * processes were alive when a message was posted. */
static BOOL wait_for_job(struct launch *launch, HANDLE port, HANDLE starter)
{
    struct close_control control = {0};
    BOOL idle = FALSE;
    read_request_path(L"WINMAC_STOP_REQUEST", control.stop);
    read_request_path(L"WINMAC_WINDOW_REQUEST", control.window);
    for (;;)
    {
        DWORD message;
        ULONG_PTR key;
        OVERLAPPED *data;
        if (!idle && !handle_close_requests(launch->job, &control)) return FALSE;
        if (port && GetQueuedCompletionStatus(port, &message, &key, &data, idle ? 0 : CONTROL_INTERVAL))
        {
            if (key != JOB_KEY) continue;
            if (message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) idle = TRUE;
            else if (message == JOB_OBJECT_MSG_NEW_PROCESS && (DWORD)(ULONG_PTR)data != launch->starter)
                add_member(launch, (DWORD)(ULONG_PTR)data);
            else if (message == JOB_OBJECT_MSG_EXIT_PROCESS || message == JOB_OBJECT_MSG_ABNORMAL_EXIT_PROCESS)
                member_exited(launch, (DWORD)(ULONG_PTR)data);
            continue;
        }
        if (idle) break;   /* remaining messages read after the job became empty */
        if (!port) Sleep(CONTROL_INTERVAL);
        /* Without job messages: a shell shortcut can spawn another process and exit
         * immediately, so wait until the whole job is empty. */
        if (WaitForSingleObject(starter, 0) == WAIT_OBJECT_0 && job_is_empty(launch->job)) idle = TRUE;
    }
    return TRUE;
}

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

/* Imported Unix pipes can be read/written by Wine, but do not implement the
 * Windows pipe-state API used by libuv (SetNamedPipeHandleState fails with
 * ERROR_INVALID_HANDLE). Give children real Windows pipes and relay every byte
 * to the original log sink. Regular files, consoles and existing Windows pipes
 * keep their original handles. There is no application-specific detection. */
struct output_relay
{
    HANDLE reader, writer, destination, thread;
    volatile LONG stopping;
    DWORD error;
};

static DWORD WINAPI relay_output(void *arg)
{
    struct output_relay *relay = arg;
    BYTE buffer[16384];
    DWORD count, written;

    while (!InterlockedCompareExchange(&relay->stopping, 0, 0))
    {
        if (!ReadFile(relay->reader, buffer, sizeof(buffer), &count, NULL))
        {
            DWORD error = GetLastError();
            if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED) relay->error = error;
            break;
        }
        if (!count) break;
        for (DWORD offset = 0; offset < count; offset += written)
        {
            if (!WriteFile(relay->destination, buffer + offset, count - offset, &written, NULL) || !written)
            {
                relay->error = GetLastError();
                if (!relay->error) relay->error = ERROR_WRITE_FAULT;
                goto done;
            }
        }
    }
done:
    /* Closing the read end also gives the child a broken-pipe error if the
     * host log sink fails, instead of leaving it blocked on a full pipe. */
    CloseHandle(relay->reader);
    relay->reader = NULL;
    return 0;
}

static BOOL prepare_output_relay(struct output_relay **out, HANDLE *handle)
{
    SECURITY_ATTRIBUTES attributes = { sizeof(attributes), NULL, TRUE };
    struct output_relay *relay;
    DWORD mode, error;

    *out = NULL;
    if (GetFileType(*handle) != FILE_TYPE_PIPE
            || GetNamedPipeHandleStateW(*handle, &mode, NULL, NULL, NULL, NULL, 0)) return TRUE;
    if (!(relay = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*relay))))
    {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return FALSE;
    }
    relay->destination = *handle;
    if (!CreatePipe(&relay->reader, &relay->writer, &attributes, 65536)
            || !SetHandleInformation(relay->reader, HANDLE_FLAG_INHERIT, 0)
            || !(relay->thread = CreateThread(NULL, 0, relay_output, relay, 0, NULL)))
    {
        error = GetLastError();
        if (relay->reader) CloseHandle(relay->reader);
        if (relay->writer) CloseHandle(relay->writer);
        HeapFree(GetProcessHeap(), 0, relay);
        SetLastError(error);
        return FALSE;
    }
    *handle = relay->writer;
    *out = relay;
    return TRUE;
}

static void close_relay_writer(struct output_relay *relay)
{
    if (relay && relay->writer)
    {
        CloseHandle(relay->writer);
        relay->writer = NULL;
    }
}

static DWORD finish_output_relay(struct output_relay *relay)
{
    DWORD error;
    if (!relay) return 0;
    close_relay_writer(relay);
    /* The whole application job has ended. Normally EOF drains the pipe at
     * once. A process outside the job may still hold an inherited writer; do
     * not let that process keep this launch alive forever. Cancel only after
     * allowing queued output to drain. Never free a relay still used by a
     * thread; process teardown will reclaim it if a sink cannot be cancelled. */
    if (WaitForSingleObject(relay->thread, 5000) != WAIT_OBJECT_0)
    {
        InterlockedExchange(&relay->stopping, 1);
        for (unsigned int i = 0; i < 40; ++i)
        {
            CancelSynchronousIo(relay->thread);
            if (WaitForSingleObject(relay->thread, 50) == WAIT_OBJECT_0) break;
        }
        if (WaitForSingleObject(relay->thread, 0) != WAIT_OBJECT_0) return ERROR_TIMEOUT;
    }
    error = relay->error;
    CloseHandle(relay->thread);
    HeapFree(GetProcessHeap(), 0, relay);
    return error;
}

int wmain(int argc, WCHAR **argv)
{
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    JOBOBJECT_ASSOCIATE_COMPLETION_PORT completion = {0};
    STARTUPINFOW startup = {0};
    PROCESS_INFORMATION child = {0};
    struct launch launch = {0};
    struct output_relay *output = NULL, *errors = NULL;
    HANDLE job, port;
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
    /* Before the first assignment, so no process message is missed. Without a
     * port the launch still works, only handed-over failures go unnoticed. */
    port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
    completion.CompletionKey = (void *)JOB_KEY;
    completion.CompletionPort = port;
    if (port && !SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, &completion, sizeof(completion)))
    {
        CloseHandle(port);
        port = NULL;
    }
    launch.job = job;
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    if (!prepare_output_relay(&output, &startup.hStdOutput)
            || !prepare_output_relay(&errors, &startup.hStdError))
    {
        status = GetLastError();
        fprintf(stderr, "Windows-Ausgabekanal konnte nicht angelegt werden (Fehler %lu).\n", status);
        goto cleanup;
    }
    if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, CREATE_SUSPENDED, NULL, NULL, &startup, &child))
        fprintf(stderr, "Programmstart fehlgeschlagen (Windows-Fehler %lu).\n", GetLastError());
    else if (!AssignProcessToJobObject(job, child.hProcess))
    {
        fputs("Programm konnte der Windows-Prozessgruppe nicht zugeordnet werden.\n", stderr);
        TerminateProcess(child.hProcess, 1);
    }
    else
    {
        close_relay_writer(output);
        close_relay_writer(errors);
        launch.starter = child.dwProcessId;
        ResumeThread(child.hThread);
        if (!wait_for_job(&launch, port, child.hProcess))
        {
            status = GetLastError();
            fprintf(stderr, "Windows-Prozessgruppe konnte nicht beendet werden (Fehler %lu).\n", status);
            goto cleanup;
        }
        GetExitCodeProcess(child.hProcess, &status);
        if (succeeded(status) && launch.failed_pid)
        {
            printf("\nStartprozess meldete Erfolg, der uebergebene Prozess %lu endete aber mit Fehler %lu.\n",
                   launch.failed_pid, launch.failed_status);
            status = launch.failed_status;
        }
    }
cleanup:
    while (launch.count)
    {
        HANDLE process = launch.members[--launch.count].process;
        if (process) CloseHandle(process);
    }
    if (launch.members) HeapFree(GetProcessHeap(), 0, launch.members);
    if (child.hThread) CloseHandle(child.hThread);
    if (child.hProcess) CloseHandle(child.hProcess);
    CloseHandle(job);
    if (port) CloseHandle(port);
    DWORD output_error = finish_output_relay(output);
    DWORD stderr_error = finish_output_relay(errors);
    if (output_error || stderr_error)
    {
        fprintf(stderr, "Windows-Ausgabe konnte nicht vollstaendig weitergeleitet werden (Fehler %lu/%lu).\n",
                output_error, stderr_error);
        if (succeeded(status)) status = ERROR_WRITE_FAULT;
    }
    HeapFree(GetProcessHeap(), 0, line);
    /* Preserve Windows' 32-bit result; the host process exit status only keeps
     * the low byte (for example, MSI success-with-reboot 3010 becomes 194). */
    printf("\nVIRTUAL_EXIT_CODE=%lu\n", status);
    return status;
}
