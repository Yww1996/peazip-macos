#!/bin/bash
# The app could launch with no window at all (macOS remembers "quit with 0 windows" and
# that suppresses the launch window). Launch repeatedly and require a window every time.
set -uo pipefail
cd "$(dirname "$0")"

APP=/Applications/PeaZip.app
main_window() {
  swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | awk -F x '$2+0 >= 500' | head -1
}

echo "############ 构建 + 安装 ############"
bash install.sh 2>&1 | grep -vE "appintents|linkd|Re-initialization|xpc:connection|SignalReady|SIGNAL" \
  | grep -E "二进制一致|签名校验|主窗口|❌"

echo
echo "############ 连续 5 次冷启动，每次都要求出现窗口 ############"
OK=0
for i in 1 2 3 4 5; do
  osascript -e 'tell application "PeaZip" to quit' >/dev/null 2>&1 || true
  pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
  sleep 2
  open "$APP"
  W=""
  for _ in $(seq 1 20); do
    sleep 0.5
    W=$(main_window)
    [ -n "$W" ] && break
  done
  if [ -n "$W" ]; then
    echo "  第 $i 次: ✅ 主窗口 $W"
    OK=$((OK+1))
  else
    echo "  第 $i 次: ❌ 没有窗口"
  fi
done
echo "  ---- 成功 $OK/5 ----"

echo
echo "############ 兜底触发是否被用到 ############"
log show --last 5m --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
  | grep -E "没有窗口|openMainWindowViaMenu" | tail -5 | sed 's/.*] /  /' || echo "  （未触发兜底 = 窗口本来就出来了）"
