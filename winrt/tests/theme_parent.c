/* Public DrawThemeParentBackgroundEx behavior: actual pixels and DC state.
 * Uses hidden windows and a memory DC; no app install, user files or UI clicks. */
#include <windows.h>
#include <uxtheme.h>
#include <stdio.h>

typedef HRESULT (WINAPI *draw_parent_fn)(HWND, HDC, DWORD, const RECT *);
static int checks, failures, erase_paints, print_paints, use_brush;
static int erase_calls, print_calls, color_calls;
static HBRUSH red, green, blue;
static RECT marker;
static const COLORREF untouched = RGB(11, 22, 33);

static void check(int ok, const char *name)
{
    ++checks;
    if (!ok) { ++failures; printf("FAIL: %s\n", name); }
}

static LRESULT CALLBACK parent_proc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp)
{
    RECT area;
    switch (message)
    {
    case WM_ERASEBKGND:
        ++erase_calls;
        if (!erase_paints) return 0;
        GetClientRect(hwnd, &area);
        FillRect((HDC)wp, &area, red);
        return 1;
    case WM_PRINTCLIENT:
        ++print_calls;
        if (print_paints) FillRect((HDC)wp, &marker, green);
        return 0; /* A successful WM_PRINTCLIENT handler also returns zero. */
    case WM_CTLCOLORSTATIC:
        ++color_calls;
        return use_brush ? (LRESULT)blue : 0;
    default:
        return DefWindowProcA(hwnd, message, wp, lp);
    }
}

static void reset(HDC dc)
{
    HBRUSH brush = CreateSolidBrush(untouched);
    RECT all = {0, 0, 128, 96};
    SelectClipRgn(dc, NULL);
    SetViewportOrgEx(dc, 0, 0, NULL);
    FillRect(dc, &all, brush);
    DeleteObject(brush);
    SetBoundsRect(dc, NULL, DCB_DISABLE | DCB_RESET);
    erase_calls = print_calls = color_calls = 0;
    erase_paints = print_paints = use_brush = 0;
}

int main(void)
{
    HMODULE theme = LoadLibraryA("uxtheme.dll");
    draw_parent_fn draw = theme ? (draw_parent_fn)(void *)GetProcAddress(theme, "DrawThemeParentBackgroundEx") : NULL;
    WNDCLASSA cls = {0};
    HWND parent, child;
    HDC dc;
    HBITMAP bitmap, old_bitmap;
    RECT clip = {10, 12, 25, 30}, bounds = {1, 2, 3, 4}, after;
    POINT origin, brush_origin;
    HRGN region, restored;
    HRESULT hr;
    check(draw != NULL, "DrawThemeParentBackgroundEx export exists");
    if (!draw) goto done;
    cls.hInstance = GetModuleHandleA(NULL);
    cls.lpfnWndProc = parent_proc;
    cls.lpszClassName = "VirtualThemeParentProbe";
    check(RegisterClassA(&cls) != 0, "register hidden window class");
    parent = CreateWindowA(cls.lpszClassName, "parent", WS_POPUP, 0, 0, 200, 160, NULL, NULL, cls.hInstance, NULL);
    child = CreateWindowA("static", "child", WS_CHILD | WS_BORDER, 21, 27, 60, 70, parent, NULL, cls.hInstance, NULL);
    check(parent && child, "create hidden parent and bordered child");
    dc = CreateCompatibleDC(NULL);
    bitmap = CreateBitmap(128, 96, 1, 32, NULL);
    check(dc && bitmap, "create memory surface");
    if (!parent || !child || !dc || !bitmap) return 2;
    old_bitmap = SelectObject(dc, bitmap);
    red = CreateSolidBrush(RGB(220, 0, 0));
    green = CreateSolidBrush(RGB(0, 220, 0));
    blue = CreateSolidBrush(RGB(0, 0, 220));

    reset(dc);
    hr = draw(child, dc, 0, NULL);
    check(hr == S_FALSE, "unhandled parent returns S_FALSE");
    check(erase_calls == 1 && print_calls == 1, "erase and print messages delivered");
    check(color_calls == 0 && GetPixel(dc, 15, 15) == untouched, "no unsolicited brush fallback");

    reset(dc);
    erase_paints = 1;
    hr = draw(child, dc, DTPB_USEERASEBKGND | DTPB_USECTLCOLORSTATIC, &clip);
    check(hr == S_OK && color_calls == 0, "successful erase bypasses static brush");
    check(GetPixel(dc, 15, 15) == RGB(220, 0, 0), "parent background rendered");
    check(GetPixel(dc, 5, 5) == untouched && GetPixel(dc, 26, 31) == untouched, "drawing stays inside requested clip");

    reset(dc);
    print_paints = 1;
    marker = (RECT){22 + 3, 28 + 4, 22 + 8, 28 + 9};
    hr = draw(child, dc, 0, NULL);
    check(hr == S_OK, "printed pixels count even when window procedure returns zero");
    check(GetPixel(dc, 3, 4) == RGB(0, 220, 0), "parent client coordinates map to child coordinates");
    check(GetPixel(dc, 0, 0) == untouched, "printing does not fill unrelated pixels");

    reset(dc);
    use_brush = 1;
    hr = draw(child, dc, DTPB_USECTLCOLORSTATIC, NULL);
    check(hr == S_OK && color_calls == 1, "static brush requested from parent");
    check(GetPixel(dc, 15, 15) == RGB(0, 0, 220), "returned static brush is used");

    reset(dc);
    hr = draw(child, dc, DTPB_USECTLCOLORSTATIC, NULL);
    check(hr == S_OK && GetPixel(dc, 15, 15) == GetSysColor(COLOR_BTNFACE), "default button-face brush fallback");

    reset(dc);
    erase_paints = 1;
    hr = draw(child, dc, DTPB_WINDOWDC | DTPB_USEERASEBKGND, NULL);
    check(hr == S_OK && GetPixel(dc, 59, 69) == RGB(220, 0, 0), "window DC includes the child's border");

    reset(dc);
    erase_paints = 1;
    region = CreateRectRgn(2, 3, 40, 45);
    restored = CreateRectRgn(0, 0, 0, 0);
    SelectClipRgn(dc, region);
    SetViewportOrgEx(dc, 3, 5, NULL);
    SetBrushOrgEx(dc, 7, 9, NULL);
    SetBoundsRect(dc, &bounds, DCB_ENABLE | DCB_RESET | DCB_ACCUMULATE);
    hr = draw(child, dc, DTPB_USEERASEBKGND, &clip);
    check(hr == S_OK, "draw with existing caller DC state");
    GetViewportOrgEx(dc, &origin);
    GetBrushOrgEx(dc, &brush_origin);
    check(origin.x == 3 && origin.y == 5, "viewport origin restored");
    check(brush_origin.x == 7 && brush_origin.y == 9, "brush origin restored");
    check(GetClipRgn(dc, restored) == 1 && EqualRgn(region, restored), "caller clip restored");
    check(GetBoundsRect(dc, &after, 0) == DCB_SET && EqualRect(&bounds, &after), "caller drawing bounds restored");
    DeleteObject(region);
    DeleteObject(restored);

    check(draw(NULL, dc, 0, NULL) == S_FALSE, "invalid window handled without crash");
    check(draw(child, NULL, 0, NULL) == S_FALSE, "invalid DC handled without crash");
    SelectObject(dc, old_bitmap);
    DeleteObject(bitmap);
    DeleteDC(dc);
    DestroyWindow(parent);
    DeleteObject(red);
    DeleteObject(green);
    DeleteObject(blue);
    UnregisterClassA(cls.lpszClassName, cls.hInstance);
done:
    if (theme) FreeLibrary(theme);
    printf("THEME_PARENT: %d/%d passed\n", checks - failures, checks);
    return failures ? 1 : 0;
}
