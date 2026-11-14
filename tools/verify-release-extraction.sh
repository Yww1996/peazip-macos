#!/bin/bash
# Verify what a user actually installs after extracting with the bundled 7-Zip.
set -euo pipefail
APP="$1"
ZIP="$2"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/peazip-extraction.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if ! "$APP/Contents/Resources/bin/7z/7z" x "$ZIP" "-o$WORK" -y > "$WORK/extraction.log" 2>&1; then
  cat "$WORK/extraction.log" >&2
  exit 1
fi
EXTRACTED="$WORK/PeaZip.app"
FRAMEWORK="$EXTRACTED/Contents/Frameworks/Sparkle.framework"
for TOOL in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
  [ -x "$FRAMEWORK/$TOOL" ] && [ -s "$FRAMEWORK/$TOOL" ]
done
codesign --verify --deep --strict "$EXTRACTED"
echo '7-Zip extraction: update helpers and app signature verified'
