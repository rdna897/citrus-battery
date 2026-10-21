#!/bin/bash
# Builds Citrus Battery.app into ./dist. Works with Xcode or just the Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/Citrus Battery.app"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "error: rsvg-convert is required to render the app icon; install it with: brew install librsvg" >&2
    exit 1
fi

swift build -c "$CONFIG" --product CitrusBattery
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CitrusBattery"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CitrusBattery"

# Bundle non-system libraries (libimobiledevice and its dependencies from Homebrew)
# into Contents/Frameworks and point every reference at the bundled copy, so the
# app runs on Macs without Homebrew.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
is_external() { [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]; }
bundle_dependencies() {
    local file="$1"
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        is_external "$dep" || continue
        local name
        name="$(basename "$dep")"
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            cp "$(realpath "$dep")" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            install_name_tool -id "@executable_path/../Frameworks/$name" "$FRAMEWORKS/$name" 2>/dev/null
            bundle_dependencies "$FRAMEWORKS/$name"
        fi
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$name" "$file" 2>/dev/null
    done
}
bundle_dependencies "$APP/Contents/MacOS/CitrusBattery"
for lib in "$FRAMEWORKS"/*.dylib; do
    [ -e "$lib" ] && codesign --force --sign - "$lib" >/dev/null
done

# Render the app icon with transparent corners at each required resolution.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
render() { rsvg-convert -w "$1" -h "$1" assets/icon.svg -o "$2"; }
for size in 16 32 128 256 512; do
    render "$size" "$ICONSET/icon_${size}x${size}.png"
    render $((size * 2)) "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Citrus Battery</string>
    <key>CFBundleDisplayName</key><string>Citrus Battery</string>
    <key>CFBundleIdentifier</key><string>org.citrusbattery.CitrusBattery</string>
    <key>CFBundleExecutable</key><string>CitrusBattery</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Citrus Battery finds iPhones and iPads on your network to read their battery when they're connected over Wi-Fi.</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>org.citrusbattery.CitrusBattery</string>
        <key>CFBundleURLSchemes</key><array><string>citrusbattery</string></array>
    </dict></array>
    <key>NSBonjourServices</key>
    <array><string>_apple-mobdev2._tcp</string></array>
    <key>NSHumanReadableCopyright</key><string>Free software under the GNU GPL v3.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats the bundle as a single unit locally.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
