#!/bin/bash
# Install the branded document icon for archive files.
#
# The bundle declared 12 archive content types with no CFBundleTypeIconFile, so Finder
# owned .zip but every archive still showed the system's unbranded "sheet with a zipper"
# icon. This adds the icon AND the plist key that points at it, then re-registers the
# bundle so LaunchServices picks the change up.
set -uo pipefail
cd "$(dirname "$0")"

SRC="$HOME/Developer/PeaZip-design/design/png5doc/PeaZipArch"
APP=/Applications/PeaZip.app
WORK=/tmp/pz_docicon_build
KEY=ArchIcon

[ -d "$SRC" ] || { echo "找不到渲染结果: $SRC"; exit 1; }

echo "############ 1. 打包 ${KEY}.icns ############"
rm -rf "$WORK"; mkdir -p "$WORK/$KEY.iconset"
copy() { cp "$SRC/$2.png" "$WORK/$KEY.iconset/$1" || { echo "  缺 $2 px"; exit 1; }; }
copy icon_16x16.png 16;      copy icon_16x16@2x.png 32
copy icon_32x32.png 32;      copy icon_32x32@2x.png 64
copy icon_128x128.png 128;   copy icon_128x128@2x.png 256
copy icon_256x256.png 256;   copy icon_256x256@2x.png 512
copy icon_512x512.png 512;   copy icon_512x512@2x.png 1024
iconutil -c icns "$WORK/$KEY.iconset" -o "$WORK/$KEY.icns" || exit 1
echo "  ✅ $(du -h "$WORK/$KEY.icns" | cut -f1)"

echo
echo "############ 2. 回解验证 ############"
iconutil -c iconset "$WORK/$KEY.icns" -o "$WORK/verify.iconset" || { echo "  ❌ 回解失败"; exit 1; }
python3 - "$WORK/verify.iconset" <<'PY'
import os, sys
from PIL import Image
d = sys.argv[1]
bad = 0
for f in sorted(os.listdir(d), key=lambda s: (Image.open(os.path.join(d, s)).width, s)):
    im = Image.open(os.path.join(d, f)).convert("RGBA")
    px = list(im.getdata())
    opaque = sum(1 for p in px if p[3] > 200)
    ink = sum(1 for p in px if p[3] > 200 and (min(p[:3]) < 200 or p[2] > 150))
    ok = opaque > 0 and ink > 0
    print("  %-22s %4dpx  不透明 %5.1f%%  有内容 %5d  %s"
          % (f, im.width, 100.0 * opaque / len(px), ink, "✅" if ok else "❌ 空白"))
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
PY
[ $? -ne 0 ] && { echo "验证未通过，不安装"; exit 1; }

echo
echo "############ 3. 安装 + 注册 ############"
cp "$WORK/$KEY.icns" "$APP/Contents/Resources/$KEY.icns"
PL=$APP/Contents/Info.plist
# Point the archive document type at it. Without this key Finder uses the system's
# generic archive sheet, which is the whole bug.
/usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:0:CFBundleTypeIconFile $KEY" "$PL" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeIconFile string $KEY" "$PL"
echo "  CFBundleTypeIconFile = $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:CFBundleTypeIconFile' "$PL")"
touch "$APP"
# Re-register so LaunchServices forgets the stale (icon-less) record.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
echo "  ✅ 已安装并重新注册"
