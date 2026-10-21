#!/bin/bash
# Build and archive the current committed revision for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "error: VERSION must be a release version such as 0.1.0" >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo "error: commit all changes before packaging so the source archive matches the app" >&2
    exit 1
fi
export VERSION
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
    lipo -verify_arch "$ARCH" "$binary"
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
