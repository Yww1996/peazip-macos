#!/bin/bash
# Is the invisible window caused by running --selftest (a second process with the SAME
# bundle id) while the GUI instance is up? Compare window visibility before/after.
set -uo pipefail
cd "$(dirname "$0")"

vis() { swift tools/winlist.swift PeaZip 2>/dev/null | grep -c 'owner='; }

echo "=== 1) 全部退出，只开 GUI ==="
osascript -e 'tell application "PeaZip" to quit' >/dev/null 2>&1 || true
pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
sleep 3
open /Applications/PeaZip.app
for _ in $(seq 1 20); do sleep 0.5; [ "$(vis)" -gt 0 ] && break; done
sleep 2
echo "   可见窗口数: $(vis)   ← 应为 1"

echo
echo "=== 2) 再跑一次 --selftest（同 bundle id 的第二个实例）==="
/Applications/PeaZip.app/Contents/MacOS/PeaZip27 --selftest >/dev/null 2>&1
sleep 3
echo "   可见窗口数: $(vis)   ← 若变 0，则 selftest 是把窗口挤掉的原因"

echo
echo "=== 3) 再跑一次 --list 看看 ==="
/Applications/PeaZip.app/Contents/MacOS/PeaZip27 --list /etc/hosts >/dev/null 2>&1
sleep 3
echo "   可见窗口数: $(vis)"

echo
echo "=== 4) 重新激活 app，看窗口能不能回来 ==="
open /Applications/PeaZip.app
for _ in $(seq 1 20); do sleep 0.5; [ "$(vis)" -gt 0 ] && break; done
sleep 2
echo "   可见窗口数: $(vis)"
echo
echo "=== 5) 所有 PeaZip 窗口的坐标与在屏状态 ==="
swift /tmp/wbounds.swift 2>/dev/null | grep -E "1120|1000|900" | head -3
