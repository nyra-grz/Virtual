/* Real GUI processes exercise stdio independently of a particular application. */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static BOOL write_all(HANDLE handle, const BYTE *data, DWORD size)
{
    while (size)
    {
        DWORD written;
        if (!WriteFile(handle, data, size, &written, NULL) || !written) return FALSE;
        data += written;
        size -= written;
    }
    return TRUE;
}

static int contracts(DWORD expected)
{
    DWORD ids[] = { STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    for (unsigned int i = 0; i < 2; ++i)
    {
        HANDLE handle = GetStdHandle(ids[i]), duplicate;
        DWORD mode = PIPE_READMODE_BYTE | PIPE_WAIT;
        if (GetFileType(handle) != expected) return 10 + i;
        if (!DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), &duplicate,
                0, FALSE, DUPLICATE_SAME_ACCESS)) return 12 + i;
        if (expected == FILE_TYPE_PIPE)
        {
            BOOL ok = GetNamedPipeHandleStateW(duplicate, &mode, NULL, NULL, NULL, NULL, 0)
                    && !mode && SetNamedPipeHandleState(duplicate, &mode, NULL, NULL);
            mode = PIPE_READMODE_MESSAGE;
            ok = ok && !SetNamedPipeHandleState(duplicate, &mode, NULL, NULL)
                    && GetLastError() == ERROR_INVALID_PARAMETER;
            CloseHandle(duplicate);
            if (!ok) return 14 + i;
        }
        else CloseHandle(duplicate);
    }
    return write_all(GetStdHandle(STD_OUTPUT_HANDLE), (const BYTE *)"STDIO_CONTRACTS_OK\n", 19) ? 0 : 16;
}

static int payload(void)
{
    BYTE data[16384];
    for (unsigned int block = 0; block < 64; ++block)
    {
        for (unsigned int i = 0; i < sizeof(data); ++i) data[i] = (BYTE)(i + block * 13);
        if (!write_all(GetStdHandle(STD_OUTPUT_HANDLE), data, sizeof(data))) return 20;
        for (unsigned int i = 0; i < sizeof(data); ++i) data[i] ^= 0x5a;
        if (!write_all(GetStdHandle(STD_ERROR_HANDLE), data, sizeof(data))) return 21;
    }
    return 0;
}

int wmain(int argc, WCHAR **argv)
{
    if (argc != 2) return 2;
    if (!wcscmp(argv[1], L"pipe")) return contracts(FILE_TYPE_PIPE);
    if (!wcscmp(argv[1], L"file")) return contracts(FILE_TYPE_DISK);
    if (!wcscmp(argv[1], L"payload")) return payload();
    if (!wcscmp(argv[1], L"late")) { Sleep(250); return payload(); }
    if (!wcscmp(argv[1], L"orphan"))
    {
        WCHAR self[MAX_PATH], line[MAX_PATH + 32];
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION child = {0};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 22;
        swprintf(line, MAX_PATH + 32, L"\"%ls\" late", self);
        if (!CreateProcessW(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child)) return 23;
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
        return 0;
    }
    if (!wcscmp(argv[1], L"input"))
    {
        BYTE data[1024]; DWORD count;
        if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), data, sizeof(data), &count, NULL)) return 24;
        return write_all(GetStdHandle(STD_OUTPUT_HANDLE), data, count) ? 0 : 25;
    }
    return 3;
}
