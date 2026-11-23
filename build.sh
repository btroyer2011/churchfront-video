#!/bin/zsh
# Builds "Churchfront Video.app" (release) next to this script.
# The executable inside, the bundle ID and the MCP binary keep their CueVideo names on purpose.
# A release build runs on any Mac on macOS 14 or later, Apple silicon or Intel, and is zipped
# as "Churchfront Video.zip" to copy to another Mac. A debug build is for this Mac only.
set -e
cd "$(dirname "$0")"
MODE=${1:-release}
ARCHS=()
if [ "$MODE" = release ]; then
    # Building for both kinds of Mac needs Xcode's build system, not just the command line tools.
    if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    ARCHS=(--arch arm64 --arch x86_64)
fi
swift build -c $MODE $ARCHS
BIN="$(swift build -c $MODE $ARCHS --show-bin-path)/CueVideo"
APP="Churchfront Video.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CueVideo"
cp "$(dirname "$BIN")/cuevideo-mcp" "$APP/Contents/MacOS/cuevideo-mcp"
cp Resources/Figtree-VariableFont_wght.ttf "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Churchfront Video</string>
  <key>CFBundleDisplayName</key><string>Churchfront Video</string>
  <key>CFBundleIdentifier</key><string>com.churchfront.cuevideo</string>
  <key>CFBundleExecutable</key><string>CueVideo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>Churchfront Video controls your ATEM switcher and PTZ cameras and shows NDI video from your network.</string>
  <key>NSBonjourServices</key><array><string>_ndi._tcp</string><string>_blackmagic._tcp</string><string>_http._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
# Tell Finder and the Dock the bundle changed, so they drop the icon they remembered.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "Built $(pwd)/$APP"
if [ "$MODE" = release ]; then
    # ditto keeps the signature intact, which a plain zip can break.
    rm -f "Churchfront Video.zip"
    ditto -c -k --keepParent "$APP" "Churchfront Video.zip"
    echo "Zipped $(pwd)/Churchfront Video.zip"
fi
