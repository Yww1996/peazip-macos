#!/bin/bash
# Does firing a Finder service leave the app windowless? Launch clean, confirm the
# window, fire a service, then re-check.
set -uo pipefail
cd "$(dirname "$0")"

max_window() {
  swift tools/winlist.swift PeaZip --all 2>/dev/null | grep -i 'owner=PeaZip' \
    | grep -oE '[0-9]+x[0-9]+' | awk -Fx '{print $1*$2, $0}' | sort -rn | head -1 | cut -d' ' -f2-
}
visible_count() {
  swift tools/winlist.swift PeaZip 2>/dev/null | grep -c 'owner='
}

echo "=== 1) 干净启动 ==="
pkill -f "Contents/MacOS/PeaZip" 2>/dev/null || true
sleep 2
open /Applications/PeaZip.app
for _ in $(seq 1 24); do sleep 0.5; [ -n "$(pgrep -f 'Contents/MacOS/PeaZip')" ] && break; done
sleep 2
echo "  最大窗口: $(max_window)   可见窗口: $(visible_count)"

echo
echo "=== 2) 触发一个服务 ==="
rm -rf /tmp/wintest && mkdir -p /tmp/wintest && printf 'x\n' > /tmp/wintest/a.txt
swift tools/service_call.swift /tmp/wintest "用 PeaZip 压缩为 ZIP" 2>/dev/null | grep NSPerformService
for t in 2 5 10; do
  sleep "$t"
  echo "  +${t}s → 最大窗口: $(max_window)   可见窗口: $(visible_count)"
done

echo
echo "=== 3) 紧接着再触发一次 ==="
swift tools/service_call.swift /tmp/wintest "用 PeaZip 压缩为 7z" 2>/dev/null | grep NSPerformService
sleep 8
echo "  最大窗口: $(max_window)   可见窗口: $(visible_count)"
pgrep -lf "Contents/MacOS/PeaZip" | sed 's/^/  进程: /'
echo
echo "=== 4) 产物 ==="
ls -la /tmp/wintest/ | sed 's/^/  /'
rm -rf /tmp/wintest
