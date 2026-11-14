#!/bin/bash
# Build, archive and sign a GitHub release. Does not push or publish anything.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${SKIP_BUILD:-0}" != 1 ]; then HEADLESS_PACKAGE=1 bash package.sh; fi
APP="$PWD/build/PeaZip.app"
PB=/usr/libexec/PlistBuddy
VERSION=$("$PB" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$("$PB" -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$("$PB" -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.yww.pea27 ]
codesign --verify --deep --strict "$APP"

DIST="${SPARKLE_DISTRIBUTION:-.build/artifacts/sparkle/Sparkle}"
SIGN="$DIST/bin/sign_update"
KEY_ARGS=(--account peazip-macos)
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
fi
OUT="$PWD/build/release"
mkdir -p "$OUT"
ZIP="$OUT/PeaZip-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
bash tools/verify-release-extraction.sh "$APP" "$ZIP"
SIGNATURE=$("$SIGN" "${KEY_ARGS[@]}" -p "$ZIP")
LENGTH=$(stat -f %z "$ZIP")
swift tools/verify-update.swift "$ZIP" "$SIGNATURE" "$APP/Contents/Info.plist" "$LENGTH"

python3 - "$OUT/appcast.xml" "$VERSION" "$BUILD" "$SIGNATURE" "$LENGTH" <<'PY'
from pathlib import Path
from datetime import datetime, timezone
from email.utils import format_datetime
from html import escape
import sys
import xml.etree.ElementTree as ET

output, version, build, signature, length = sys.argv[1:]
sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', sparkle)
root = ET.Element('rss', version='2.0')
channel = ET.SubElement(root, 'channel')
ET.SubElement(channel, 'title').text = 'PeaZip macOS'
ET.SubElement(channel, 'link').text = 'https://github.com/Yww1996/peazip-macos'
ET.SubElement(channel, 'language').text = 'zh-cn'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'PeaZip {version}'
ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
ET.SubElement(item, f'{{{sparkle}}}version').text = build
ET.SubElement(item, f'{{{sparkle}}}shortVersionString').text = version
ET.SubElement(item, f'{{{sparkle}}}minimumSystemVersion').text = '15.0'
# 41–43 may have been extracted with blocked helper symlinks. Their updater must
# open the manual download link instead of running that potentially broken helper.
# Keep this cutoff in future feeds: builds 44+ retain normal in-app installation.
informational = ET.SubElement(item, f'{{{sparkle}}}informationalUpdate')
ET.SubElement(informational, f'{{{sparkle}}}belowVersion').text = '44'
ET.SubElement(item, 'link').text = f'https://github.com/Yww1996/peazip-macos/releases/tag/v{version}'
notes = Path('assets/updates/release-notes.md').read_text()
ET.SubElement(item, 'description').text = '<pre>' + escape(notes) + '</pre>'
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/Yww1996/peazip-macos/releases/download/v{version}/PeaZip-{version}.zip',
    f'{{{sparkle}}}edSignature': signature, 'length': length, 'type': 'application/octet-stream'
})
ET.indent(root)
ET.ElementTree(root).write(output, encoding='utf-8', xml_declaration=True)
PY

# The client requires signed feeds as well as signed archives.
"$SIGN" "${KEY_ARGS[@]}" "$OUT/appcast.xml"
"$SIGN" "${KEY_ARGS[@]}" --verify "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "PeaZip-$VERSION.zip" > SHA256SUMS)
echo "Ready: $ZIP and $OUT/appcast.xml"
echo "Upload BOTH files to the same GitHub release; publish it as the latest stable release."
