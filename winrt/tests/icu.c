/* Windows-System-ICU (icu.dll seit Windows 10 1903, icuuc/icuin als Weiterleitungen):
 * Zeitzonen wie MSVCs std::chrono, Zeichensätze, Sortierung, Wortgrenzen (Wörterbuch-
 * daten) und die Weiterleitungen. Mit -licu gelinkt: Fehlt icu.dll, startet es gar nicht. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef int UErrorCode;
typedef WCHAR UChar;
#define FAILED_ICU(x) ((x) > 0)
__declspec(dllimport) const char *__cdecl u_errorName(UErrorCode code);

static int checks, failures;
static void check(int ok, const char *what)
{
    checks++;
    if (!ok) { failures++; printf("FEHLER: %s\n", what); }
}

#define LOAD(lib, ret, name, args) ret (__cdecl *name) args = (ret (__cdecl *) args)GetProcAddress(lib, #name); \
    check(name != NULL, #name)

int main(void)
{
    HMODULE icu = LoadLibraryExW(L"icu.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE uc = LoadLibraryExW(L"icuuc.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE in = LoadLibraryExW(L"icuin.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    UErrorCode status = 0;
    char zone8[64] = "";
    const char *tz = "";

    check(icu && uc && in, "icu.dll/icuuc.dll/icuin.dll aus system32 laden");
    if (!icu) { printf("ICU: icu.dll fehlt\n"); return 1; }
    check(strcmp(u_errorName(0), "U_ZERO_ERROR") == 0, "u_errorName über Import");

    LOAD(icu, const char *, ucal_getTZDataVersion, (UErrorCode *));
    LOAD(icu, int, ucal_getDefaultTimeZone, (UChar *, int, UErrorCode *));
    LOAD(icu, void *, ucal_open, (const UChar *, int, const char *, int, UErrorCode *));
    LOAD(icu, void, ucal_setDate, (void *, int, int, int, UErrorCode *));
    LOAD(icu, int, ucal_get, (const void *, int, UErrorCode *));
    LOAD(icu, void, ucal_close, (void *));
    LOAD(icu, void *, ucnv_open, (const char *, UErrorCode *));
    LOAD(icu, int, ucnv_toUChars, (void *, UChar *, int, const char *, int, UErrorCode *));
    LOAD(icu, void, ucnv_close, (void *));
    LOAD(icu, void *, ucol_open, (const char *, UErrorCode *));
    LOAD(icu, int, ucol_strcoll, (const void *, const UChar *, int, const UChar *, int));
    LOAD(icu, void, ucol_close, (void *));
    LOAD(icu, void *, ubrk_open, (int, const char *, const UChar *, int, UErrorCode *));
    LOAD(icu, int, ubrk_first, (void *));
    LOAD(icu, int, ubrk_next, (void *));
    LOAD(icu, void, ubrk_close, (void *));
    if (failures) { printf("ICU: %d/%d\n", checks - failures, checks); return 1; }

    /* Zeitzonen: Datenstand, Mac-Zone als Standard, Sommerzeit Europe/Berlin = +2 h */
    tz = ucal_getTZDataVersion(&status);
    check(!FAILED_ICU(status) && tz && *tz, "Zeitzonen-Datenstand");
    {
        UChar zone[64];
        int len = ucal_getDefaultTimeZone(zone, 64, &status);
        check(!FAILED_ICU(status) && len > 0, "Standard-Zeitzone");
        WideCharToMultiByte(CP_UTF8, 0, zone, len > 0 ? len : 0, zone8, sizeof(zone8) - 1, NULL, NULL);
        void *cal = ucal_open(L"Europe/Berlin", -1, "de", 1 /* UCAL_GREGORIAN */, &status);
        ucal_setDate(cal, 2026, 6 /* UCAL_JULY */, 1, &status);
        int offset = ucal_get(cal, 15 /* ZONE_OFFSET */, &status) + ucal_get(cal, 16 /* DST_OFFSET */, &status);
        check(!FAILED_ICU(status) && offset == 2 * 3600 * 1000, "Europe/Berlin im Juli +2 h");
        if (cal) ucal_close(cal);
    }
    /* Zeichensätze */
    {
        UChar out[4] = {0};
        status = 0;
        void *cp1252 = ucnv_open("windows-1252", &status);
        ucnv_toUChars(cp1252, out, 4, "\x80", 1, &status);
        check(!FAILED_ICU(status) && out[0] == 0x20ac, "windows-1252 0x80 = Euro");
        if (cp1252) ucnv_close(cp1252);
        status = 0;
        void *sjis = ucnv_open("Shift_JIS", &status);
        check(!FAILED_ICU(status) && sjis, "Shift_JIS");
        if (sjis) ucnv_close(sjis);
    }
    /* Sortierung je Sprache: im Deutschen ä vor b, im Schwedischen ä nach z */
    {
        status = 0;
        void *de = ucol_open("de", &status), *sv = ucol_open("sv", &status);
        check(!FAILED_ICU(status) && de && sv, "Sortierregeln de/sv");
        if (de && sv) {
            check(ucol_strcoll(de, L"ä", -1, L"b", -1) < 0, "de: ä < b");
            check(ucol_strcoll(sv, L"ä", -1, L"z", -1) > 0, "sv: ä > z");
        }
        if (de) ucol_close(de);
        if (sv) ucol_close(sv);
    }
    /* Wortgrenzen im Japanischen brauchen die Wörterbuchdaten */
    {
        static const UChar text[] = L"日本語の文章です";
        int count = 0;
        status = 0;
        void *words = ubrk_open(1 /* UBRK_WORD */, "ja", text, -1, &status);
        if (words) {
            for (int pos = ubrk_first(words); pos != -1; pos = ubrk_next(words)) count++;
            ubrk_close(words);
        }
        check(!FAILED_ICU(status) && count > 2, "japanische Wortgrenzen");
    }
    /* icuuc.dll/icuin.dll leiten an icu.dll weiter */
    check(uc && GetProcAddress(uc, "ucnv_open") == (FARPROC)ucnv_open, "icuuc.dll → icu.dll");
    check(in && GetProcAddress(in, "ucol_open") == (FARPROC)ucol_open, "icuin.dll → icu.dll");

    printf("ICU: tz=%s zone=%s %d/%d\n", tz ? tz : "?", zone8, checks - failures, checks);
    return failures != 0;
}
