#!/bin/bash
# Install the new front-end as /Applications/PeaZip.app, taking over the name from the
# original LCL PeaZip. The original is MOVED to the Desktop as a backup, never deleted —
# but the app no longer needs it, because the archiver engine is bundled inside.
set -uo pipefail
cd "$(dirname "$0")"

SRC="$PWD/build/PeaZip27.app"
DEST="/Applications/PeaZip.app"
ORIG="/Applications/PeaZip.app"
BACKUP="$HOME/Desktop/PeaZip-原版备份.app"

echo "############ 1) 构建 ############"
bash package.sh 2>&1 | grep -E "二进制一致|图标|引擎|签名校验|主窗口|❌" | sed 's/^/  /'
[ -d "$SRC" ] || { echo "❌ 没有 $SRC"; exit 1; }

echo
echo "############ 2) 备份原版（不删除、不覆盖已有备份）############"
osascript -e 'tell application "PeaZip" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "PeaZip 27" to quit' >/dev/null 2>&1 || true
# Match on the executable path, NOT on the .app folder name: the installed copy is
# PeaZip.app while the dev build is PeaZip27.app, and a pattern tied to either one
# silently matches nothing after the rename.
pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
pkill -x peazip 2>/dev/null || true
sleep 2

PB=/usr/libexec/PlistBuddy
OUR_ID="com.yww.pea27"

if [ ! -d "$ORIG" ]; then
  echo "  （/Applications 里没有 PeaZip.app，跳过）"
else
  ORIG_ID=$("$PB" -c "Print :CFBundleIdentifier" "$ORIG/Contents/Info.plist" 2>/dev/null || echo "?")
  if [ "$ORIG_ID" = "$OUR_ID" ]; then
    # Re-running this script must NOT treat our own installed copy as "the original".
    # That exact confusion moved the newly installed app into the backup slot and
    # wiped the real backup — so identity is checked, never assumed from the path.
    echo "  /Applications/PeaZip.app 是本 app 的旧安装（${ORIG_ID}），直接替换，不碰备份"
    rm -rf "$ORIG"
  elif [ -e "$BACKUP" ]; then
    echo "  ⚠️  $BACKUP 已存在 —— 不覆盖（那正是上一次把备份弄丢的原因）"
    echo "      原版仍在 /Applications，未做任何移动。请先处理备份位再运行。"
    exit 1
  else
    mv "$ORIG" "$BACKUP" && echo "  ✅ 原版（${ORIG_ID}）已移到 $BACKUP" || { echo "  ❌ 移不动原版"; exit 1; }
  fi
fi

echo
echo "############ 3) 安装新 app ############"
rm -rf "$DEST"
ditto "$SRC" "$DEST" || { echo "❌ 复制失败"; exit 1; }
# Take over the name: Finder/Dock/menu bar should all say "PeaZip", matching the request
# to replace the original. CFBundleExecutable stays PeaZip27 (internal, and the plist
# key still points at the real file name).
PB="/usr/libexec/PlistBuddy"
"$PB" -c "Set :CFBundleName PeaZip" "$DEST/Contents/Info.plist"
"$PB" -c "Set :CFBundleDisplayName PeaZip" "$DEST/Contents/Info.plist"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1
codesign -v "$DEST" 2>/dev/null && echo "  已安装并签名: $DEST" || echo "  ⚠️ 签名校验未过"
echo "  CFBundleName = $("$PB" -c "Print :CFBundleName" "$DEST/Contents/Info.plist")"

echo
echo "############ 4) 让 LaunchServices 重新登记 ############"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -f "$DEST"
"$LSREG" -f "$BACKUP" 2>/dev/null || true
# The local build shares the installed app's bundle identifier, so without this the
# Finder's "Open With" list can offer the copy under ~/Desktop (which may later be moved
# or deleted, leaving a broken entry). Only the installed app should be advertised.
"$LSREG" -u "$SRC" 2>/dev/null || true
echo "  已登记 $DEST；已注销开发副本"

echo
echo "############ 5) 从 /Applications 启动 ############"
open "$DEST"
PID=""
for _ in $(seq 1 24); do sleep 0.5; PID=$(pgrep -f "Contents/MacOS/PeaZip27" | head -1); [ -n "$PID" ] && break; done
echo "  PID: ${PID:-未启动}"
[ -z "$PID" ] && { echo "❌ 启动失败"; exit 1; }

echo
echo "############ 6) 窗口 ############"
for _ in $(seq 1 24); do
  sleep 0.5
  W=$(swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -i "owner=PeaZip" | grep -oE '[0-9]+x[0-9]+' | awk -Fx '{print $1*$2, $0}' | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$W" ] && break
done
if [ -n "$W" ]; then
  echo "  ✅ 主窗口 ${W}（可见窗口数: $(swift tools/winlist.swift PeaZip 2>/dev/null | grep -c 'owner=')）"
else
  echo "  ❌ 无窗口"
fi

echo
echo "############ 7) 引擎是否指向内置副本（关键）############"
sleep 2
log show --last 60s --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
  | grep "launched" | tail -1 | sed 's/.*] /  /'

echo
echo "############ 8) 归档往返自检（原版已不在 /Applications）############"
"$DEST/Contents/MacOS/PeaZip27" --selftest 2>/dev/null | grep -E "7z 引擎|归档引擎|❌" | sed 's/^/  /'

echo
echo "############ 9) 最终状态 ############"
ls -d /Applications/PeaZip.app "$BACKUP" 2>/dev/null | sed 's/^/  /'
