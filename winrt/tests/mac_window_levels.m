/* Run the driver's actual policy against AppKit's native level constants.
 * No user windows, activation, input injection or desktop inspection. */
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include "virtual_window_levels.h"

static unsigned checks, failed;
static void check(BOOL ok, const char *what)
{
    ++checks;
    if (!ok) { ++failed; printf("FAIL: %s\n", what); }
}

int main(void)
{
    const struct { const char *value; BOOL enabled; } values[] = {
        {NULL, NO}, {"", NO}, {"0", NO}, {"false", NO}, {"off", NO}, {"no", NO},
        {"1", YES}, {"TRUE", YES}, {"yes", YES}, {"On", YES}, {"random", NO}
    };
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i)
        check(virtual_overlay_value(values[i].value) == values[i].enabled,
                "explicit kiosk opt-in and false values");

    for (unsigned active = 0; active < 2; ++active)
    for (unsigned floating = 0; floating < 2; ++floating)
    {
        check(virtual_window_level(active, floating, NO, NO, NO) == NSNormalWindowLevel,
                "ordinary/topmost windows share the normal Mac plane in either activation state");
        check(virtual_window_level(NO, floating, YES, NO, NO) == NSNormalWindowLevel,
                "inactive captured windows do not stay raised");
        check(virtual_window_level(active, floating, YES, YES, YES) == NSNormalWindowLevel,
                "explicitly shrunk kiosk returns to normal plane");
    }
    check(virtual_window_level(YES, NO, YES, NO, NO) == CGShieldingWindowLevel() + 1,
            "actual display capture retains its input-capable plane");
    check(virtual_window_level(YES, YES, YES, NO, NO) == CGShieldingWindowLevel() + 2,
            "captured dialog stays above its captured owner");
    check(virtual_window_level(YES, NO, NO, YES, NO) == NSStatusWindowLevel + 1,
            "opted-in kiosk remains available");
    check(virtual_window_level(YES, YES, NO, YES, NO) == NSStatusWindowLevel + 2,
            "opted-in kiosk dialog level");
    check(virtual_window_level(NO, NO, NO, YES, NO) == NSFloatingWindowLevel,
            "explicit background kiosk overlay");
    check(virtual_window_level(NO, YES, NO, YES, NO) == NSFloatingWindowLevel + 1,
            "explicit background kiosk dialog");

    const NSInteger planes[] = {NSNormalWindowLevel, NSFloatingWindowLevel,
        NSStatusWindowLevel + 1, CGShieldingWindowLevel() + 1};
    for (unsigned i = 0; i < sizeof(planes) / sizeof(planes[0]); ++i)
    {
        check(virtual_floating_level(NSNormalWindowLevel, YES, NO, planes[i]) == NSNormalWindowLevel,
                "topmost alone never imposes a Dock or floating plane");
    }
    check(virtual_floating_level(NSFloatingWindowLevel, YES, NO, NSNormalWindowLevel)
                    == NSFloatingWindowLevel, "explicit overlay preserves its required plane");
    check(virtual_floating_level(NSStatusWindowLevel + 1, YES, NO, NSStatusWindowLevel + 1)
                    == NSStatusWindowLevel + 2, "overlay-owned dialog stays above owner");
    check(virtual_floating_level(NSNormalWindowLevel, YES, YES, NSStatusWindowLevel + 1)
                    == NSNormalWindowLevel, "shrink is not undone by topmost flooring");
    printf("MAC_WINDOW_LEVELS: %u/%u passed; normal=%ld\n", checks-failed, checks,
            (long)NSNormalWindowLevel);
    return failed != 0;
}
