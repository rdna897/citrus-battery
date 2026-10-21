#!/bin/bash
# Sign the application's ZIP and appcast. Never publish an unsigned update feed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Citrus Battery.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
NAME="CitrusBattery-${VERSION}-${ARCH}-macOS${MIN_MACOS}"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "dist/$NAME.zip" "$WORK/"

key_options=(--account citrus-battery)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    # Use stdin, not command arguments or logs, to pass the CI signing secret.
    key_options=(--ed-key-file -)
fi
"$TOOLS/generate_appcast" "${key_options[@]}" \
    --download-url-prefix "https://github.com/rdna897/citrus-battery/releases/download/v$VERSION/" \
    --link "https://github.com/rdna897/citrus-battery/releases/tag/v$VERSION" \
    --maximum-deltas 0 -o "$WORK/appcast-$ARCH.xml" "$WORK" <<< "${SPARKLE_PRIVATE_KEY:-}"

# generate_appcast can only warn about a mismatched key; reject missing archive
# signatures explicitly before copying any feed to the publish directory.
python3 - "$WORK/appcast-$ARCH.xml" "$NAME.zip" "$VERSION" <<'PY'
import base64
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
feed, archive, version = sys.argv[1:]
root = ET.parse(feed).getroot()
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = root.findall('./channel/item')
assert len(items) == 1, 'Expected exactly one update in architecture feed'
item = items[0]
assert item.findtext('sparkle:version', namespaces=ns) == version
enclosure = item.find('enclosure')
assert enclosure is not None
assert enclosure.get('url') == f'https://github.com/rdna897/citrus-battery/releases/download/v{version}/{archive}'
signature = enclosure.get('{%s}edSignature' % ns['sparkle'], '')
assert len(base64.b64decode(signature, validate=True)) == 64, 'Missing update signature (check signing key)'
assert int(enclosure.get('length', '0')) == (Path(feed).parent / archive).stat().st_size
assert item.findtext('sparkle:minimumSystemVersion', namespaces=ns), 'Missing minimum macOS version'
PY
"$TOOLS/sign_update" "${key_options[@]}" --verify "$WORK/appcast-$ARCH.xml" <<< "${SPARKLE_PRIVATE_KEY:-}"
cp "$WORK/appcast-$ARCH.xml" "dist/appcast-$ARCH.xml"
echo "Signed update feed: dist/appcast-$ARCH.xml"
