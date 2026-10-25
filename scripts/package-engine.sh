#!/bin/bash
# Ship the tested engine, not pointers into the developer's home directory.
# No user prefixes, identities, credentials, caches or graphify output enter the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Destination Engine directory required}"
[ "$(basename "$DEST")" = Engine ] || { echo "Destination must be named Engine." >&2; exit 1; }
RUNTIME="${WINMAC_RUNTIME:-$ROOT/runtime}"
[ -x "$RUNTIME/wine-build/bin/wine" ] || { echo "A source-built Wine engine is required for releases." >&2; exit 1; }
[ -f "$RUNTIME/wine-build/share/wine/mono/wine-mono-10.4.1/support/winemono-support.msi" ] || {
    echo "Wine Mono is missing; run scripts/setup-managed-runtime.sh first." >&2; exit 1;
}
[ -s "$ROOT/thirdparty/graphics/dxvk.tar.gz" ] || { echo "DXVK package is missing; run setup-graphics.sh first." >&2; exit 1; }
[ -s "$ROOT/thirdparty/graphics/dxmt.tar.gz" ] && [ -f "$RUNTIME/wine-build/lib/wine/x86_64-unix/winemetal.so" ] || {
    echo "DXMT is missing; run scripts/install-dxmt-runtime.sh runtime/wine-build first." >&2; exit 1;
}
[ -f "$RUNTIME/wine-build/lib/wine/x86_64-unix/winegstreamer.so" ] && [ -d "$RUNTIME/wine-build/lib/gst/gstreamer-1.0" ] || {
    echo "GStreamer is missing; build Wine with GStreamer and run scripts/bundle-gstreamer.sh runtime/wine-build." >&2; exit 1;
}
[ -x "$RUNTIME/sspi/venv/bin/python" ] || { echo "Local authentication runtime is missing; run scripts/setup-local-auth.sh first." >&2; exit 1; }
[ -f "$RUNTIME/wine-build/lib/icu/x86_64-windows/icu.dll" ] && [ -f "$RUNTIME/wine-build/lib/icu/i386-windows/icu.dll" ] || {
    echo "Windows ICU is missing; run scripts/build-icu.sh --install first." >&2; exit 1;
}
mkdir -p "$(dirname "$DEST")"
STAGE="$(mktemp -d "$(dirname "$DEST")/.engine.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/runtime" "$STAGE/scripts" "$STAGE/thirdparty/graphics"
echo "==> Packe Wine, Mono und Grafikunterstützung…"
ditto "$RUNTIME/wine-build" "$STAGE/runtime/wine-build"
"$ROOT/scripts/write-runtime-wrappers.sh" "$STAGE/runtime"
cp "$ROOT/scripts/init-prefix.sh" "$ROOT/scripts/setup-dotnet48.sh" "$ROOT/scripts/setup-dependencies.sh" "$ROOT/scripts/install-dotnet-runtime.py" "$STAGE/scripts/"
"$ROOT/scripts/setup-compatibility-tools.sh"
ditto "$RUNTIME/tools" "$STAGE/runtime/tools"
mkdir -p "$STAGE/support"
cp "$ROOT/support/components.lock.json" "$STAGE/support/"
[ ! -f "$ROOT/support/THIRD_PARTY.md" ] || cp "$ROOT/support/THIRD_PARTY.md" "$STAGE/support/"
[ ! -f "$RUNTIME/engine-source.json" ] || cp "$RUNTIME/engine-source.json" "$STAGE/engine-source.json"
cp "$ROOT/setup-graphics.sh" "$STAGE/"
cp "$ROOT/thirdparty/graphics/dxvk.tar.gz" "$STAGE/thirdparty/graphics/"
cp "$ROOT/thirdparty/graphics/dxmt.tar.gz" "$STAGE/thirdparty/graphics/"

# A venv's interpreter symlink points outside the project. Copy its base Python
# distribution and installed packages instead; no Python/Homebrew/uv on users' Macs.
PY="$RUNTIME/sspi/venv/bin/python"
PYROOT="$("$PY" -c 'import sys; print(sys.base_prefix)')"
PYVERSION="$("$PY" -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')"
SITE="$("$PY" -c 'import site; print(site.getsitepackages()[0])')"
mkdir -p "$STAGE/runtime/sspi/bin"
ditto "$PYROOT" "$STAGE/runtime/sspi/python"
ditto "$SITE" "$STAGE/runtime/sspi/python/lib/$PYVERSION/site-packages"
cp "$ROOT/winrt/sspi/ntlm_auth.py" "$STAGE/runtime/sspi/"
cat > "$STAGE/runtime/sspi/bin/virtual-ntlm-auth" <<'HELPER'
#!/bin/bash
BASE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$BASE/python/bin/python3" -I "$BASE/ntlm_auth.py" "$@"
HELPER
chmod 755 "$STAGE/runtime/sspi/bin/virtual-ntlm-auth"
"$STAGE/runtime/sspi/python/bin/python3" -I -c 'import spnego' || {
    echo "Packaged Python cannot load its authentication support." >&2; exit 1;
}
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
# Content identity also changes when engine patches change without an app version bump.
(cd "$STAGE" && find runtime scripts thirdparty setup-graphics.sh -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256 | awk '{print $1}') > "$STAGE/engine-version"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "==> Engine enthalten: $DEST"
