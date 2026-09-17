#!/bin/bash
# Build an .icns from the round-5 renders and install it into the app bundle.
#
# The trap this guards against: the 16 and 32 px slots inside an .icns are RAW bitmaps
# (4 bytes/pixel), not PNG streams, so a naive "open every chunk with PIL" verification
# fails on exactly the sizes that matter most — and an icon that renders as an empty
# square still passes every "the file exists" check.
set -uo pipefail
cd "$(dirname "$0")"

VARIANT=${1:-A_blue}
SRC="$HOME/Developer/PeaZip-design/design/png5/$VARIANT"
APP=/Applications/PeaZip.app
WORK=/tmp/pz_icon_build

[ -d "$SRC" ] || { echo "找不到渲染结果: $SRC"; exit 1; }

echo "############ 1. 打包 iconset ############"
rm -rf "$WORK"; mkdir -p "$WORK/AppIcon.iconset"
copy() { # slot px
  [ -f "$SRC/$2.png" ] || { echo "  缺 $2 px"; exit 1; }
  cp "$SRC/$2.png" "$WORK/AppIcon.iconset/$1"
}
copy icon_16x16.png 16;      copy icon_16x16@2x.png 32
copy icon_32x32.png 32;      copy icon_32x32@2x.png 64
copy icon_128x128.png 128;   copy icon_128x128@2x.png 256
copy icon_256x256.png 256;   copy icon_256x256@2x.png 512
copy icon_512x512.png 512;   copy icon_512x512@2x.png 1024
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns" || exit 1
echo "  ✅ $(du -h "$WORK/AppIcon.icns" | cut -f1)  $WORK/AppIcon.icns"

echo
echo "############ 2. 回解验证（iconutil 能解出来 = 系统认得；逐尺寸查有没有内容）############"
rm -rf "$WORK/verify.iconset"
iconutil -c iconset "$WORK/AppIcon.icns" -o "$WORK/verify.iconset" || { echo "  ❌ icns 回解失败"; exit 1; }
# Note: the 16/32 px slots inside an .icns are NOT PNGs on this macOS version — they are
# packed "ARGB" blocks (verified: ic04 payload starts with b"ARGB" and is 616 bytes, where
# raw 16x16x4 would be 1024). Decoding those by hand is guesswork, so round-trip through
# iconutil instead: whatever the system can unpack is what the Dock will show.
python3 - "$WORK/verify.iconset" <<'PY'
import os, sys
from PIL import Image

d = sys.argv[1]
bad = 0
for f in sorted(os.listdir(d), key=lambda s: (Image.open(os.path.join(d, s)).width, s)):
    im = Image.open(os.path.join(d, f)).convert("RGBA")
    px = list(im.getdata())
    opaque = sum(1 for p in px if p[3] > 200)
    glyph = sum(1 for p in px if p[3] > 200 and min(p[:3]) > 210)
    body = 100.0 * opaque / len(px)
    # A macOS icon body inside the Big Sur margin covers ~52-56% of the canvas.
    ok = 45.0 < body < 65.0 and glyph > 0
    print("  %-22s %4dpx  不透明 %5.1f%%  字母   %5d  %s"
          % (f, im.width, body, glyph, "✅" if ok else "❌ 空白/无字母/比例异常"))
    if not ok:
        bad += 1
print("  ---- %s ----" % ("每个尺寸都实心且有字母" if not bad else "有 %d 个尺寸异常" % bad))
sys.exit(1 if bad else 0)
PY
[ $? -ne 0 ] && { echo "验证未通过，不安装"; exit 1; }

echo
echo "############ 3. 安装进 app ############"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
# A Finder "custom icon" lives in a resource fork and wins over CFBundleIconFile.
rm -f "$APP/Icon"$'\r'
xattr -c "$APP" 2>/dev/null || true
touch "$APP"
killall Dock 2>/dev/null || true
echo "  CFBundleIconFile = $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
echo "  ✅ 已安装 $VARIANT"
