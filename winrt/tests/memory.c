/* Bounded Windows memory contracts: reservations, protection, execution, heaps
 * and shared-file / copy-on-write isolation. No application-name workarounds. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static unsigned int checks, failures;
static SYSTEM_INFO system_info;
static void check(int ok, const char *name)
{
    ++checks;
    if (!ok) { ++failures; printf("FAIL: %s (error %lu)\n", name, GetLastError()); }
}

static void test_pages(void)
{
    SIZE_T page = system_info.dwPageSize, i;
    BYTE *base, *commit;
    MEMORY_BASIC_INFORMATION info;
    DWORD old;
    int zero = 1;
    base = VirtualAlloc(NULL, 2 * system_info.dwAllocationGranularity, MEM_RESERVE, PAGE_READWRITE);
    check(base != NULL, "reserve address space");
    if (!base) return;
    check((ULONG_PTR)base % system_info.dwAllocationGranularity == 0, "reservation allocation alignment");
    check(VirtualQuery(base, &info, sizeof(info)) == sizeof(info) && info.State == MEM_RESERVE,
          "reserved pages are not committed");
    commit = VirtualAlloc(base + page - 1, 2, MEM_COMMIT, PAGE_READWRITE);
    check(commit == base, "cross-page commit rounds address down");
    if (!commit) { VirtualFree(base, 0, MEM_RELEASE); return; }
    for (i = 0; i < 2 * page; ++i) if (base[i]) zero = 0;
    check(zero, "newly committed pages are zero");
    memset(base, 0xa5, 2 * page);
    check(VirtualAlloc(base, page, MEM_COMMIT, PAGE_READWRITE) == base && base[0] == 0xa5,
          "recommit preserves existing committed bytes");
    check(VirtualProtect(base + page, page, PAGE_READONLY, &old) && old == PAGE_READWRITE,
          "protect one page and return its previous protection");
    check(VirtualQuery(base, &info, sizeof(info)) && info.Protect == PAGE_READWRITE && info.RegionSize == page,
          "neighboring writable page retains its protection");
    check(VirtualQuery(base + page, &info, sizeof(info)) && info.Protect == PAGE_READONLY,
          "query agrees with read-only page protection");
    check(VirtualFree(base, page, MEM_DECOMMIT), "decommit leaves reservation intact");
    check(VirtualQuery(base, &info, sizeof(info)) && info.State == MEM_RESERVE, "query decommitted page");
    check(VirtualAlloc(base, page, MEM_COMMIT, PAGE_READWRITE) == base, "commit after decommit");
    zero = 1;
    for (i = 0; i < page; ++i) if (base[i]) zero = 0;
    check(zero, "recommitted storage is zero again");
    check(!VirtualFree(base, page, MEM_RELEASE), "release requires a zero size");
    check(VirtualFree(base, 0, MEM_RELEASE), "release complete reservation");
}

static void test_executable_memory(void)
{
    static const BYTE code[] = {0xb8, 42, 0, 0, 0, 0xc3}; /* mov eax,42; ret */
    BYTE *memory = VirtualAlloc(NULL, system_info.dwPageSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    DWORD old;
    check(memory != NULL, "allocate bounded JIT buffer");
    if (!memory) return;
    memcpy(memory, code, sizeof(code));
    if (VirtualProtect(memory, system_info.dwPageSize, PAGE_EXECUTE_READ, &old))
    {
        check(old == PAGE_READWRITE, "JIT transition returns writable protection");
        check(FlushInstructionCache(GetCurrentProcess(), memory, sizeof(code)), "flush generated instructions");
        check(((int (__cdecl *)(void))(void *)memory)() == 42, "execute generated x86 instructions");
    }
    else check(0, "change writable JIT buffer to executable/read-only");
    VirtualFree(memory, 0, MEM_RELEASE);
}

static void test_heap(void)
{
    static const SIZE_T sizes[] = {0, 1, 7, 16, 31, 4096, 65536};
    HANDLE heap = HeapCreate(0, 0, 0);
    SIZE_T n, i;
    check(heap != NULL, "create private heap");
    if (!heap) return;
    for (n = 0; n < sizeof(sizes) / sizeof(sizes[0]); ++n)
    {
        SIZE_T size = sizes[n];
        BYTE *p = HeapAlloc(heap, HEAP_ZERO_MEMORY, size), *grown;
        int zero = 1, preserved = 1;
        check(p != NULL, "allocate heap block including zero-size block");
        if (!p) continue;
        check((ULONG_PTR)p % (2 * sizeof(void *)) == 0, "Windows heap pointer alignment");
        check(HeapSize(heap, 0, p) >= size, "heap reports sufficient allocation size");
        for (i = 0; i < size; ++i) if (p[i]) zero = 0;
        check(zero, "HEAP_ZERO_MEMORY initializes requested bytes");
        memset(p, 0x5a, size);
        grown = HeapReAlloc(heap, HEAP_ZERO_MEMORY, p, size + 97);
        check(grown != NULL, "grow heap block");
        if (grown)
        {
            p = grown; zero = 1;
            for (i = 0; i < size; ++i) if (p[i] != 0x5a) preserved = 0;
            for (; i < size + 97; ++i) if (p[i]) zero = 0;
            check(preserved, "reallocation preserves previous payload");
            check(zero, "reallocation zeros the added payload");
        }
        check(HeapValidate(heap, 0, p), "allocation remains valid");
        check(HeapFree(heap, 0, p), "free valid heap block");
    }
    check(HeapDestroy(heap), "destroy private heap");
}

static void test_file_copy(DWORD section_protection)
{
    WCHAR directory[MAX_PATH], filename[MAX_PATH];
    HANDLE file, section;
    BYTE *first, *peer, data[4096];
    DWORD written, read, old;
    MEMORY_BASIC_INFORMATION info;
    BOOL changed;
    GetTempPathW(MAX_PATH, directory);
    GetTempFileNameW(directory, L"vmm", 0, filename);
    file = CreateFileW(filename, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    check(file != INVALID_HANDLE_VALUE, "create private mapping fixture");
    if (file == INVALID_HANDLE_VALUE) return;
    memset(data, 0x11, sizeof(data));
    check(WriteFile(file, data, sizeof(data), &written, NULL) && written == sizeof(data), "initialize file bytes");
    section = CreateFileMappingW(file, NULL, section_protection, 0, sizeof(data), NULL);
    check(section != NULL, "create file section");
    if (!section) { CloseHandle(file); return; }
    first = MapViewOfFile(section, FILE_MAP_READ, 0, 0, 0);
    peer = MapViewOfFile(section, FILE_MAP_READ, 0, 0, 0);
    check(first && peer, "map two read-only views");
    if (!first || !peer) goto done;
    check(first[0] == 0x11 && peer[0] == 0x11, "both views observe initial file contents");
    data[0] = 0x33;
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    WriteFile(file, data, 1, &written, NULL);
    FlushFileBuffers(file);
    check(first[0] == 0x33 && peer[0] == 0x33, "file updates remain visible before private writes");
    changed = VirtualProtect(first, sizeof(data), PAGE_WRITECOPY, &old);
    check(changed, "read-only view can become copy-on-write");
    if (!changed)
    {
        check(VirtualQuery(first, &info, sizeof(info)) && info.Protect == PAGE_READONLY,
              "failed protection change preserves reported protection");
        goto done;
    }
    check(old == PAGE_READONLY, "copy-on-write transition reports previous protection");
    check(VirtualQuery(first, &info, sizeof(info)) && info.Protect == PAGE_WRITECOPY,
          "query reports requested copy-on-write protection");
    first[0] = 0x77;
    check(first[0] == 0x77 && peer[0] == 0x33, "private write does not change another view");
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    ReadFile(file, data, 1, &read, NULL);
    check(read == 1 && data[0] == 0x33, "private write does not change backing file");
    data[0] = 0x44;
    SetFilePointer(file, 0, NULL, FILE_BEGIN);
    WriteFile(file, data, 1, &written, NULL);
    FlushFileBuffers(file);
    check(peer[0] == 0x44 && first[0] == 0x77, "private page stays isolated from later file changes");
    check(VirtualProtect(first, sizeof(data), PAGE_WRITECOPY | PAGE_GUARD, &old),
          "private file view can be guarded");
    SetLastError(0);
    changed = VirtualLock(first, sizeof(data));
    check(!changed && GetLastError() == 0x80000001, "guarded private file view consumes guard on lock");
    if (changed) VirtualUnlock(first, sizeof(data));
    if (VirtualQuery(first, &info, sizeof(info)) && info.Protect == PAGE_WRITECOPY)
        check(first[0] == 0x77 && peer[0] == 0x44, "unguarding private file view preserves access and isolation");
    else check(0, "private view retains usable permissions after guard removal");
done:
    if (first) UnmapViewOfFile(first);
    if (peer) UnmapViewOfFile(peer);
    CloseHandle(section);
    CloseHandle(file);
}

static void test_available_address_space(void)
{
    MEMORYSTATUSEX before = {0}, reserved = {0}, released = {0};
    SIZE_T size = 64 * 1024 * 1024;
    void *region;
    BOOL ok;
    before.dwLength = reserved.dwLength = released.dwLength = sizeof(before);
    ok = GlobalMemoryStatusEx(&before);
    check(ok, "query initial memory status");
    if (!ok) return;
    region = VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_READWRITE);
    check(region != NULL, "reserve address space without committing physical pages");
    if (!region) return;
    ok = GlobalMemoryStatusEx(&reserved);
    check(ok, "query memory status immediately after reservation");
    if (ok)
    {
        check(reserved.ullTotalVirtual == before.ullTotalVirtual, "reservation preserves total address space");
        check(reserved.ullAvailVirtual <= before.ullAvailVirtual &&
              before.ullAvailVirtual - reserved.ullAvailVirtual >= size,
              "available virtual space accounts for uncommitted reservations");
        check(reserved.ullAvailVirtual <= reserved.ullTotalVirtual, "available address space is bounded by total");
    }
    check(VirtualFree(region, 0, MEM_RELEASE), "release address-space reservation");
    ok = GlobalMemoryStatusEx(&released);
    check(ok, "query memory status immediately after release");
    if (ok && reserved.ullAvailVirtual)
        check(released.ullAvailVirtual >= reserved.ullAvailVirtual &&
              released.ullAvailVirtual - reserved.ullAvailVirtual >= size - system_info.dwAllocationGranularity,
              "released address space becomes available without waiting for physical-memory cache");
}

static void test_guard_lock(void)
{
    SIZE_T page = system_info.dwPageSize;
    BYTE *region = VirtualAlloc(NULL, page, MEM_RESERVE | MEM_COMMIT | MEM_WRITE_WATCH,
                               PAGE_READWRITE | PAGE_GUARD);
    MEMORY_BASIC_INFORMATION info;
    void *writes[4];
    ULONG_PTR count = 4;
    ULONG granularity = 0;
    BOOL locked;
    check(region != NULL, "allocate guarded write-watch page");
    if (!region) return;
    SetLastError(0);
    locked = VirtualLock(region, page);
    check(!locked, "first lock reports guard violation instead of silently succeeding");
    check(GetLastError() == 0x80000001, "guard lock returns Windows guard-violation status");
    if (locked) VirtualUnlock(region, page);
    check(VirtualQuery(region, &info, sizeof(info)) && info.Protect == PAGE_READWRITE,
          "locking consumes the one-shot guard");
    check(GetWriteWatch(0, region, page, writes, &count, &granularity) == 0 && count == 0,
          "guard handling does not dirty write-watch storage");
    locked = VirtualLock(region, page);
    check(locked, "retry locks the now-unguarded page");
    count = 4;
    check(GetWriteWatch(0, region, page, writes, &count, &granularity) == 0 && count == 1 && writes[0] == region,
          "successful lock reports writable-page probe to write watch");
    if (locked) check(VirtualUnlock(region, page), "unlock the page after successful retry");
    VirtualFree(region, 0, MEM_RELEASE);
}

static void test_unavailable_lock(void)
{
    SIZE_T page = system_info.dwPageSize;
    BYTE *region = VirtualAlloc(NULL, page, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
    MEMORY_BASIC_INFORMATION info;
    BOOL locked;
    if (!region) { check(0, "create inaccessible lock fixture"); return; }
    locked = VirtualLock(region, page);
    check(!locked, "inaccessible pages cannot be locked");
    if (locked) VirtualUnlock(region, page);
    check(VirtualQuery(region, &info, sizeof(info)) && info.Protect == PAGE_NOACCESS,
          "failed lock leaves inaccessible page protection unchanged");
    VirtualFree(region, 0, MEM_DECOMMIT);
    locked = VirtualLock(region, page);
    check(!locked, "uncommitted pages cannot be locked");
    if (locked) VirtualUnlock(region, page);
    check(VirtualQuery(region, &info, sizeof(info)) && info.State == MEM_RESERVE,
          "failed lock does not commit reserved storage");
    VirtualFree(region, 0, MEM_RELEASE);
}

int main(void)
{
    GetSystemInfo(&system_info);
    check(system_info.dwPageSize == 4096, "x86 Windows exposes 4 KiB pages");
    check(system_info.dwAllocationGranularity == 65536, "Windows exposes 64 KiB reservation granularity");
    test_pages();
    test_executable_memory();
    test_heap();
    test_file_copy(PAGE_READONLY);
    test_file_copy(PAGE_READWRITE);
    test_available_address_space();
    test_guard_lock();
    test_unavailable_lock();
    printf("MEMORY_CONTRACT: %u/%u passed (%u-bit)\n", checks - failures, checks, (unsigned)(8 * sizeof(void *)));
    return failures ? 1 : 0;
}
