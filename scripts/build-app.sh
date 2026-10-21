#!/bin/bash
# Builds Citrus Battery.app into ./dist. Works with Xcode or just the Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="$(cat VERSION)"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]]; then
    echo "error: VERSION must contain a version such as 1.0 or 1.0.1" >&2
    exit 1
fi
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
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$FRAMEWORKS" "$LICENSES"
cp LICENSE "$LICENSES/CitrusBattery-GPL-3.0.txt"
is_external() { [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]; }
bundle_dependencies() {
    local file="$1"
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        is_external "$dep" || continue
        local name
        name="$(basename "$dep")"
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            local original prefix notices
            original="$(realpath "$dep")"
            prefix="$(dirname "$(dirname "$original")")"
            notices="$LICENSES/$(basename "$(dirname "$prefix")")-$(basename "$prefix")"
            mkdir -p "$notices"
            for notice in "$prefix"/COPYING* "$prefix"/LICENSE* "$prefix"/NOTICE* "$prefix"/AUTHORS* "$prefix"/sbom.spdx.json "$prefix"/INSTALL_RECEIPT.json; do
                [ ! -f "$notice" ] || cp "$notice" "$notices/"
            done
            if [ -d "$prefix/.brew" ]; then
                cp -R "$prefix/.brew" "$notices/formula"
            fi
            cp "$original" "$FRAMEWORKS/$name"
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

# Homebrew libraries may require a newer OS than the Swift deployment target.
# Declare the highest requirement from the executable and every bundled library.
MIN_MACOS="$(otool -l "$APP/Contents/MacOS/CitrusBattery" "$FRAMEWORKS"/*.dylib | awk '
    $1 == "cmd" { command = $2 }
    $1 == "minos" { print $2 }
    command == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }
' | sort -V | tail -n 1)"
[ -n "$MIN_MACOS" ] || { echo "error: cannot determine minimum macOS version" >&2; exit 1; }

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
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
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

# Ad hoc signing seals the bundle without an Apple account. It does not identify
# the developer to Gatekeeper or provide Apple notarization.
codesign --force --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built $APP (macOS $MIN_MACOS or later, ad hoc signed)"
