#!/bin/bash
# Two failure modes we actually hit, both invisible to a "did it launch" check:
#   1. no launch window at all (restored into a Space/position that no longer exists)
#   2. the app terminating itself seconds later (AppKit "sudden termination")
# So: require a window shortly after launch AND require it to still be there 20s later.
set -uo pipefail
cd "$(dirname "$0")"

APP=/Applications/PeaZip.app
LAUNCHES=${1:-3}

# Any width, real height: 900x600 and 1100x600 both count, the 33px helper strips do not.
main_window() {
  swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -oE '[0-9]+x[0-9]+' \
    | awk -F x '$2+0 >= 500' | head -1
}

echo "############ 构建 + 安装 ############"
bash install.sh 2>&1 | grep -vE "appintents|linkd|Re-initialization|xpc:connection|SignalReady|SIGNAL" \
  | grep -E "二进制一致|签名校验|主窗口|❌"

echo
echo "############ 冷启动 $LAUNCHES 次：启动即有窗口 + 20 秒后仍存活 ############"
OK=0
for i in $(seq 1 "$LAUNCHES"); do
  # pkill only. `osascript -e 'tell app "PeaZip" to quit'` is NOT safe here: an Apple
  # Event aimed at a stopped app STARTS it and then quits it, so the quit lands on the
  # instance we are about to launch and the test blames the app for a harness bug.
  pkill -f "Contents/MacOS/PeaZip" 2>/dev/null || true
  for _ in $(seq 1 20); do
    sleep 0.5
    pgrep -f 'Contents/MacOS/PeaZip' >/dev/null || break
  done
  sleep 1
  open "$APP"

  W=""
  for _ in $(seq 1 16); do
    sleep 0.5
    W=$(main_window)
    [ -n "$W" ] && break
  done
  if [ -z "$W" ]; then
    echo "  第 $i 次: ❌ 启动后没有窗口"
    continue
  fi

  sleep 20
  W2=$(main_window)
  P=$(pgrep -f 'Contents/MacOS/PeaZip' | head -1)
  if [ -n "$W2" ] && [ -n "$P" ]; then
    echo "  第 $i 次: ✅ 窗口 $W → 20 秒后仍在（PID ${P}）"
    OK=$((OK+1))
  else
    echo "  第 $i 次: ❌ 窗口 $W 出现后消失了（进程=${P:-无}）"
  fi
done
echo "  ---- 全部通过 $OK/$LAUNCHES ----"
