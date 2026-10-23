# License and origin notice

**Virtual** is based on **Wine** (https://www.winehq.org) and is a fork of it.

Wine is licensed under the **GNU Lesser General Public License, version 2.1 or
later (LGPL-2.1+)**. The full license text is in the Wine source at
`thirdparty/wine/COPYING.LIB` (after running `build-wine.sh`) and in the official
Wine repository.

Conditions this fork complies with:

1. **Copyright and license notices are kept.** The original notices in the Wine
   source are not removed.
2. **Changes are published.** Own changes to the Wine code are kept as individual
   patches with a description in `patches/`.
3. **No misleading origin.** The name "Wine" is not used to label the origin of
   this distribution; the outward-facing commands are called `virtual`,
   `virtualserver`, `virtualboot`, `virtualcfg` and `virtualpath`.

Bundled or downloaded third-party components and their licenses:

- **MoltenVK** — Apache-2.0 (Khronos/Brenwill)
- **DXVK** — zlib/libpng; macOS port: Gcenx/DXVK-macOS
- **VKD3D-Proton** — LGPL-2.1
- **MinGW-w64** — various permissive licenses
- **FreeType** — FreeType License (FTL) or GPL-2.0
- **GnuTLS** (with nettle, gmp, libtasn1, p11-kit …) — LGPL-2.1+ or LGPL-3.0+
- **SDL2** — zlib

`build-wine.sh` copies FreeType, GnuTLS, SDL2 and MoltenVK as x86_64 libraries
from an existing Wine Staging.app to `runtime/wine-build/lib`.

None of these are committed to this repository; `build-wine.sh` /
`setup-graphics.sh` download them to `thirdparty/` or take them from Homebrew.

This repository's own code – the launcher app (`app/`), the scripts, `winrt/` and
`patches/` – is also licensed under the **LGPL-2.1 or later**, see `LICENSE`.
Everything is free; anyone who distributes a modified version must publish the
changes.
