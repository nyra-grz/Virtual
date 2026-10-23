#!/bin/bash
# Baut die native Launcher-App "Virtual.app".
# Benötigt nur die Command Line Tools (swift). Kein Xcode-Projekt nötig.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$ROOT/app"
NAME="Virtual"
BUNDLE="$ROOT/build/$NAME.app"
CONTENTS="$BUNDLE/Contents"
# Version aus VERSION (WINMAC_VERSION überschreibt, z. B. zum Testen des Auto-Updaters).
VERSION="${WINMAC_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Kompiliere (release)…"
( cd "$APPDIR" && swift build -c release )
BIN="$APPDIR/.build/release/WinMacVirtual"
[ -x "$BIN" ] || { echo "Build fehlgeschlagen: $BIN fehlt"; exit 1; }

echo "==> Baue App-Bundle…"
rm -rf "$BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Virtual"

# Icon, falls vorhanden
if [ -f "$ROOT/app/Resources/AppIcon.icns" ]; then
    cp "$ROOT/app/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    ICON_KEY=""
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.oezdek.winmacvirtual</string>
    <key>CFBundleExecutable</key><string>Virtual</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Daniel Özdek · kostenlos, LGPL-2.1 oder später</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    $ICON_KEY
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Windows-Programm</string>
            <key>CFBundleTypeRole</key><string>Shell</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>exe</string><string>msi</string></array>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
                <string>com.microsoft.msi-installer</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc-Signatur, damit macOS die App ohne Gatekeeper-Murren lokal startet.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || echo "   (Signatur übersprungen)"

echo "==> Fertig: $BUNDLE  (Version $VERSION, Build $BUILD_NUMBER)"
echo "   Starten mit:  open \"$BUNDLE\""
