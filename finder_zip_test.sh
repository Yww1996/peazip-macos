#!/bin/bash
# Reproduce the exact reported flow: double-click an archive in Finder and confirm the
# app actually ENTERS it (previously it only navigated to the folder and selected it),
# including the cold-launch case where application(_:open:) arrives before the model.
set -uo pipefail
cd "$(dirname "$0")"

# An archive to test with can be passed as $1. With no argument the script builds a
# throwaway one, so it carries no reference to any real document.
ZIP="${1:-}"
if [ -z "$ZIP" ] || [ ! -f "$ZIP" ]; then
  WORK=$(mktemp -d)
  printf 'sample\n' > "$WORK/示例.txt"
  (cd "$WORK" && zip -q demo.zip 示例.txt)
  ZIP="$WORK/demo.zip"
fi
echo "目标压缩包:"
if [ -f "$ZIP" ]; then echo "  ✅ 存在 ($(basename "$ZIP"))"; else echo "  ❌ 不存在"; exit 1; fi

echo
echo "############ 1) 构建 + 安装 ############"
bash install.sh 2>&1 | grep -vE "appintents|linkd|Re-initialization|xpc:connection|SignalReady|SIGNAL" \
  | grep -E "主窗口|❌"

APP=/Applications/PeaZip.app
BIN="$APP/Contents/MacOS/PeaZip27"

if [ -f "$ZIP" ]; then
  echo
  echo "############ 2) 用真实压缩包做无头浏览自检 ############"
  "$BIN" --list "$ZIP" 2>/dev/null | sed 's/^/  /'
fi

echo
echo "############ 3) 冷启动场景：app 没在跑时从访达打开压缩包 ############"
osascript -e 'tell application "PeaZip" to quit' >/dev/null 2>&1 || true
pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
sleep 2
pgrep -f "Contents/MacOS/PeaZip27" >/dev/null && echo "  ⚠️ 仍有实例" || echo "  已全部退出 ✅"

START=$(date '+%Y-%m-%d %H:%M:%S')
open -a "$APP" "$ZIP"
sleep 8
echo "  应用日志（应看到 open from Finder → enter archive → archive list）:"
log show --start "$START" --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
  | grep -E "open from Finder|enter archive|archive list|flushing|now at" \
  | sed 's/.*] /    /'

echo
if log show --start "$START" --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
     | grep -q "enter archive"; then
  echo "  ✅ 冷启动后确实进入了压缩包"
else
  echo "  ❌ 冷启动后没有进入压缩包"
fi

echo
echo "############ 4) 热启动场景（app 已在运行）############"
START2=$(date '+%Y-%m-%d %H:%M:%S')
open -a "$APP" "$ZIP"
sleep 5
log show --start "$START2" --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
  | grep -E "open from Finder|enter archive|archive list" | sed 's/.*] /    /'
if log show --start "$START2" --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
     | grep -q "enter archive"; then
  echo "  ✅ 热启动也进入了压缩包"
else
  echo "  ❌ 热启动没进入压缩包"
fi
