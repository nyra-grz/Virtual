# Compatibility components

Versioned download URLs and SHA checksums are in `components.lock.json`.

- Wine / CrossOver FOSS 26.3.0 (Wine 11.0 base), LGPL-2.1-or-later:
  https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz
  Virtual's changes are the patch series in `patches/crossover/` (order in `series`).
  Wine's normal username and profile expansion are retained so existing Virtual
  rooms continue to use their original AppData and installed application data.
- Wine keyboard fix by Rémi Bernon, LGPL-2.1-or-later:
  https://github.com/wine-mirror/wine/commit/3b1ab64042d214b3516fabdbca052a412da57f70
- Winetricks, LGPL-2.1-or-later:
  https://github.com/Winetricks/winetricks
  The pinned upstream script and cabextract are bundled; users need no Homebrew.
  Redistributable installers are downloaded from recipe sources and checked by
  Winetricks. Microsoft .NET 6–10 uses Microsoft's release metadata and SHA-512.
- DXMT 0.80, LGPL-2.1-or-later:
  https://github.com/3Shain/dxmt/releases/tag/v0.80
  Optional Metal renderer. DXVK remains the compatibility default. The upstream
  driver dispatch ABI is adapted for plain Wine; CrossOver supplies its own ABI.
- GStreamer 1.26.x and its selected plugins:
  https://gstreamer.freedesktop.org/
  Core and transitive runtime libraries are bundled as x86_64. Python and
  unrelated plugins are omitted. Source: the official macOS distribution.
- libinotify-kqueue 20240724, MIT:
  https://github.com/libinotify-kqueue/libinotify-kqueue
  Provides real directory change notifications through macOS kqueue.
- ICU 78.3 (International Components for Unicode), Unicode-3.0:
  https://github.com/unicode-org/icu/releases/tag/release-78.3
  Built by `scripts/build-icu.sh` with MinGW as Windows' system `icu.dll` (C API,
  unversioned names, data embedded) plus `icuuc.dll`/`icuin.dll` forwarders, the
  layout Windows 10 has had since 1903. The export list comes from MinGW-w64's
  import library. ICU's LICENSE (including the dictionary data licenses) ships
  next to the DLLs in `runtime/wine-build/lib/icu/`.

Windows redistributable packages and user prefixes are not included in the app
archive. Python and its packages retain their upstream license files.
