/* A real asynchronous directory notification, covering the kqueue/inotify bridge. */
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
int main(void)
{
    WCHAR temp[MAX_PATH], folder[MAX_PATH], file[MAX_PATH];
    BYTE buffer[2048]; OVERLAPPED operation = {0};
    HANDLE directory, created; DWORD bytes = 0, wait; BOOL result;
    GetTempPathW(MAX_PATH, temp);
    swprintf(folder, MAX_PATH, L"%lsvirtual-change-%lu", temp, GetCurrentProcessId());
    swprintf(file, MAX_PATH, L"%ls\\probe.txt", folder);
    if (!CreateDirectoryW(folder, NULL)) return 2;
    directory = CreateFileW(folder, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (directory == INVALID_HANDLE_VALUE) return 3;
    operation.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    result = ReadDirectoryChangesW(directory, buffer, sizeof(buffer), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME, NULL, &operation, NULL);
    if (!result) { printf("ReadDirectoryChangesW failed: %lu\n", GetLastError()); return 4; }
    created = CreateFileW(file, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, 0, NULL);
    if (created == INVALID_HANDLE_VALUE) return 5;
    CloseHandle(created);
    wait = WaitForSingleObject(operation.hEvent, 5000);
    result = wait == WAIT_OBJECT_0 && GetOverlappedResult(directory, &operation, &bytes, FALSE) && bytes > 0;
    printf("Directory change: wait=%lu bytes=%lu notified=%d\n", wait, bytes, result);
    CancelIo(directory); CloseHandle(directory); CloseHandle(operation.hEvent);
    DeleteFileW(file); RemoveDirectoryW(folder);
    return result ? 0 : 1;
}
