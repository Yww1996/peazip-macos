#!/bin/bash
# Package the release binary into a .app bundle and verify it really launches.
#
# Two traps this script exists to avoid, both of which cost real debugging time:
#   1. Packaging a STALE binary produced a completely wrong "the bundle is broken"
#      conclusion — so it always builds first and md5-checks the copy.
#   2. A bundle's window owner is its CFBundleName ("PeaZip 27", with a space), NOT the
#      executable name. Filtering a window list on "PeaZip27" reports a healthy app as
#      windowless. Verification here polls on a substring both spellings share.
# Window checks go through the window server (tools/winlist.swift): `screencapture` and
# System Events both need permissions this environment does not have.
set -uo pipefail
cd "$(dirname "$0")"

APP="build/PeaZip27.app"
EXE="PeaZip27"

echo "=== 0) 构建（必须是新二进制，否则后面所有验证都是假的）==="
swift build -c release 2>&1 | tail -3 || { echo "❌ 构建失败"; exit 1; }

echo
echo "=== 1) 组装 bundle ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/$EXE "$APP/Contents/MacOS/$EXE"
A=$(md5 -q .build/release/$EXE); B=$(md5 -q "$APP/Contents/MacOS/$EXE")
if [ "$A" = "$B" ]; then echo "  二进制一致 ✅ ($A)"; else echo "  ❌ 二进制不一致（bundle 里是旧的）"; exit 1; fi

if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "  图标: AppIcon.icns ✅ ($(du -h assets/AppIcon.icns | cut -f1))"
else
  echo "  ⚠️  缺 assets/AppIcon.icns —— Dock 里会是空白方块"
fi

# Bundle the archiver engine itself. Without it the app is a shell that breaks the moment
# the original PeaZip is removed — which is exactly what replacing it does.
#
# The engine is vendored at assets/engine so a build never depends on some other app
# happening to be installed. Note the trap: an external PeaZip keeps its engine in
# Contents/MacOS/bin while ours goes in Contents/Resources/bin, so a naive ENGINE_SRC
# pointing at "our own bundle" finds nothing — which is how a build silently produced an
# engine-less app. Fail loudly instead of shipping a shell.
ENGINE_SRC="${ENGINE_SRC:-}"
if [ -z "$ENGINE_SRC" ]; then
  for cand in "assets/engine" \
              "/Applications/PeaZip.app/Contents/MacOS/bin" \
              "/Applications/peazip.app/Contents/MacOS/bin"; do
    if [ -x "$cand/7z/7z" ]; then ENGINE_SRC="$cand"; break; fi
  done
fi
if [ -n "$ENGINE_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/bin"
  ditto "$ENGINE_SRC" "$APP/Contents/Resources/bin"
  BINS=$(find "$APP/Contents/Resources/bin" -type f -perm -u+x | wc -l | tr -d ' ')
  echo "  引擎: 来自 $ENGINE_SRC → 内置 $BINS 个可执行文件 ($(du -sh "$APP/Contents/Resources/bin" | cut -f1)) ✅"
else
  echo "  ❌ 找不到 7z 引擎源（assets/engine 不存在，系统里也没有 PeaZip/Homebrew 7z）"
  echo "     拒绝产出没有归档能力的空壳 app。"
  exit 1
fi

# The app is useless without a working engine, so verify it really executes.
if "$APP/Contents/Resources/bin/7z/7z" i >/dev/null 2>&1; then
  echo "  引擎自检: $("$APP/Contents/Resources/bin/7z/7z" 2>&1 | grep -m1 '^7-Zip')"
else
  echo "  ❌ 内置引擎无法执行"; exit 1
fi

# Record which PeaZip release the engine came from. The in-app updater can only tell
# "an update exists" from this: PeaZip's tag (11.2.0) and the 7-Zip version inside it
# (26.02) are unrelated numbers, so the 7z version alone cannot be compared to a tag.
if [ -f assets/engine/PEAZIP_RELEASE ]; then
  cp assets/engine/PEAZIP_RELEASE "$APP/Contents/Resources/bin/.peazip-release"
  echo "  引擎来源: PeaZip $(tr -d '\n' < assets/engine/PEAZIP_RELEASE)"
else
  echo "  ⚠️  缺 assets/engine/PEAZIP_RELEASE —— 应用内「检查更新」会显示未记录"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PeaZip27</string>
    <key>CFBundleIdentifier</key><string>com.yww.pea27</string>
    <key>CFBundleName</key><string>PeaZip</string>
    <key>CFBundleDisplayName</key><string>PeaZip</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.7</string>
    <key>CFBundleVersion</key><string>7</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- Without CFBundleDevelopmentRegion, AppKit falls back to region "en" and renders
         the STANDARD menus (About/Hide/Quit/Services/Edit/View/Window/Help) in English
         even on a Chinese system; the app's own strings were always Chinese, only the
         system-provided menus were not. The languages themselves come from the .lproj
         folders on disk — declaring CFBundleLocalizations as well makes every language
         appear twice in Bundle.localizations, so it is deliberately omitted. -->
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>NSServices</key>
    <array>
        <!-- Finder right-click → 服务. NSMessage is the selector name; NSPortName MUST
             equal CFBundleName or the message never reaches us. NSSendTypes /
             NSFilenamesPboardType is the proven combination (Keka ships exactly this);
             NSRequiredContext keeps the items out of text-only contexts. -->
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 PeaZip 压缩为 ZIP</string></dict>
            <key>NSMessage</key><string>peaCompressZIP</string>
            <key>NSPortName</key><string>PeaZip</string>
            <key>NSRequiredContext</key>
            <dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 PeaZip 压缩为 7Z</string></dict>
            <key>NSMessage</key><string>peaCompress7Z</string>
            <key>NSPortName</key><string>PeaZip</string>
            <key>NSRequiredContext</key>
            <dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 PeaZip 解压到新文件夹</string></dict>
            <key>NSMessage</key><string>peaExtract</string>
            <key>NSPortName</key><string>PeaZip</string>
            <key>NSRequiredContext</key>
            <dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 PeaZip 测试压缩包完整性</string></dict>
            <key>NSMessage</key><string>peaTest</string>
            <key>NSPortName</key><string>PeaZip</string>
            <key>NSRequiredContext</key>
            <dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>压缩包</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>public.bzip2-archive</string>
                <string>public.xz-archive</string>
                <string>com.facebook.zstd-archive</string>
                <string>public.iso-image</string>
                <string>com.sun.java-archive</string>
                <string>public.archive</string>
            </array>
        </dict>
    </array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSDisableAutomaticTermination</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>需要访问桌面文件夹以浏览和归档其中的文件。</string>
    <key>NSDocumentsFolderUsageDescription</key><string>需要访问文档文件夹以浏览和归档其中的文件。</string>
    <key>NSDownloadsFolderUsageDescription</key><string>需要访问下载文件夹以浏览和归档其中的文件。</string>
    <key>NSRemovableVolumesUsageDescription</key><string>需要访问外置磁盘以浏览和归档其中的文件。</string>
</dict>
</plist>
PLIST

# Localized resource folders. CFBundleLocalizations advertises the languages, but the
# bundle also needs the matching .lproj on disk, or the runtime may not resolve them when
# choosing which language AppKit renders the standard menus in.
for L in zh-Hans zh-Hant en; do
  mkdir -p "$APP/Contents/Resources/$L.lproj"
done
printf '/* 应用自身文案直接写在代码中（中文），此文件为多语言预留。 */\n' \
  > "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings" \
   "$APP/Contents/Resources/zh-Hant.lproj/Localizable.strings"
printf '/* App strings are written directly in code. */\n' \
  > "$APP/Contents/Resources/en.lproj/Localizable.strings"
echo "  本地化目录: zh-Hans / zh-Hant / en"
plutil -lint "$APP/Contents/Info.plist" >/dev/null && echo "  Info.plist 格式校验 ✅"

echo
echo "=== 2) 清 bundle 根目录杂物（否则签名会被拒）==="
find "$APP" -maxdepth 1 \( -type l -o -name '.DS_Store' \) -delete
find "$APP" -name '.DS_Store' -delete
echo "  已清"

echo
echo "=== 3) 签名 ==="
codesign --force --deep --sign - "$APP" || { echo "❌ 签名失败"; exit 1; }
if codesign -v "$APP" 2>/dev/null; then echo "  ✅ 签名校验通过"; else echo "❌ 签名校验未通过"; exit 1; fi

echo
echo "=== 4) 启动 ==="
osascript -e 'tell application "PeaZip 27" to quit' >/dev/null 2>&1 || true
pkill -f "Contents/MacOS/$EXE" 2>/dev/null || true
sleep 2
open "$APP"
PID=""
for _ in $(seq 1 24); do
  sleep 0.5
  PID=$(pgrep -f "Contents/MacOS/$EXE" | head -1)
  [ -n "$PID" ] && break
done
echo "  PID: ${PID:-未启动}"
[ -z "$PID" ] && { echo "❌ 进程没起来"; exit 1; }

echo
echo "=== 5) 验证窗口真的存在（轮询；取最大窗口，菜单辅助窗口不算）==="
FOUND=""
for _ in $(seq 1 24); do
  sleep 0.5
  # --all also lists SwiftUI's off-screen menu/toolbar helper windows (e.g. 1920x30),
  # so pick the largest by area rather than the first line — otherwise this reports a
  # nonsense size for a perfectly good window.
  FOUND=$(swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -i "owner=PeaZip" \
          | grep -oE '[0-9]+x[0-9]+' | awk -Fx '{print $1*$2, $0}' | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$FOUND" ] && break
done
if [ -n "$FOUND" ]; then
  echo "  ✅ 主窗口 ${FOUND}（可见窗口数: $(swift tools/winlist.swift PeaZip 2>/dev/null | grep -c 'owner=')）"
else
  echo "  ❌ 未找到窗口"
  swift tools/winlist.swift --all 2>/dev/null | head -5
  exit 1
fi

echo
echo "=== 6) 稳定性 ==="
sleep 4
ps -o pid,%cpu,%mem,stat,etime -p "$PID" 2>/dev/null || { echo "  ❌ 进程已退出"; exit 1; }
swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -qi "owner=PeaZip" \
  && echo "  ✅ 窗口仍在" || echo "  ❌ 窗口消失"

echo
echo "=== 7) 崩溃检查 ==="
log show --last 1m --predicate "process == \"$EXE\"" --style compact 2>/dev/null \
  | grep -iE "crash|fatal|signal" | head -3 || echo "  无崩溃记录"
