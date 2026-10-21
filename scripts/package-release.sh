#!/bin/bash
# Build and archive the current committed revision for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "error: commit all changes before packaging so the source archive matches the app" >&2
    exit 1
fi
CONFIG=release ./scripts/build-app.sh

APP="dist/Citrus Battery.app"
ARCH="$(uname -m)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
NAME="CitrusBattery-${VERSION}-${ARCH}-macOS${MIN_MACOS}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Catch accidental links to libraries that only exist on the build machine.
for binary in "$APP/Contents/MacOS/CitrusBattery" "$APP/Contents/Frameworks"/*.dylib; do
    if otool -L "$binary" | tail -n +2 | awk '{ print $1 }' | grep -E '^(/opt/homebrew/|/usr/local/)' >/dev/null; then
        echo "error: $binary still links to Homebrew outside the app bundle" >&2
        exit 1
    fi
    lipo "$binary" -verify_arch "$ARCH"
done
codesign --verify --deep --strict "$APP"
if ! codesign -dvv "$APP" 2>&1 | grep '^Signature=adhoc$' >/dev/null; then
    echo "error: expected an ad hoc signature" >&2
    exit 1
fi

mkdir "$WORK/$NAME"
ditto "$APP" "$WORK/$NAME/Citrus Battery.app"
cp docs/INSTALL.md "$WORK/$NAME/INSTALL.md"
cp LICENSE "$WORK/$NAME/LICENSE"
ditto -c -k --sequesterRsrc --keepParent "$WORK/$NAME" "dist/$NAME.zip"

# Validate the archive after extraction and launch it from a different path.
mkdir "$WORK/unpacked"
ditto -x -k "dist/$NAME.zip" "$WORK/unpacked"
EXTRACTED_APP="$WORK/unpacked/$NAME/Citrus Battery.app"
codesign --verify --deep --strict "$EXTRACTED_APP"
"$EXTRACTED_APP/Contents/MacOS/CitrusBattery" --dump > "$WORK/launch.txt"
test -s "$WORK/launch.txt"
python3 scripts/test-app-launch.py "$EXTRACTED_APP"

# Include our exact revision and the matching source archives for bundled
# libraries, together with their Homebrew build recipes and license notices.
mkdir -p "$WORK/$NAME-sources/CitrusBattery"
git archive HEAD | tar -x -C "$WORK/$NAME-sources/CitrusBattery"
python3 scripts/collect-release-sources.py "$APP/Contents/Resources/Licenses" "$WORK/$NAME-sources/dependencies"
ditto -c -k --keepParent "$WORK/$NAME-sources" "dist/$NAME-sources.zip"
for archive in "$NAME.zip" "$NAME-sources.zip"; do
    (cd dist && shasum -a 256 "$archive" > "$archive.sha256")
done
echo "Release archives: dist/$NAME.zip and dist/$NAME-sources.zip"
