#!/bin/bash
# Builds Citrus Battery.app into ./dist. Works with Xcode or just the Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="dist/Citrus Battery.app"

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

# App icon from assets/icon.svg (Quick Look rasterises SVG without extra tools).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
qlmanage -t -s 1024 -o "$WORK" assets/icon.svg >/dev/null 2>&1
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon.svg.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon.svg.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
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
    <key>NSHumanReadableCopyright</key><string>Free software under the GNU GPL v3.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats the bundle as a single unit locally.
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
