#!/usr/bin/env bash
# 抓 GitHub README 用的三张截图：浅色 / 深色 / 解压进行中。
#
# 前置条件（一次性）：给运行它的终端（或 Hermes）开「屏幕录制」权限
#   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选终端 / Hermes → 重启该程序
# 没权限时 screencapture 会报 "could not create image from display"。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="assets/readme/shots"
DEMO="/tmp/演示包.zip"
mkdir -p "$OUT"

if ! screencapture -x /tmp/_permcheck.png 2>/dev/null; then
  echo "❌ 没有屏幕录制权限，先按脚本开头的说明授权" >&2
  exit 1
fi
rm -f /tmp/_permcheck.png

# 演示包：真实文件、中文名、有子目录，列表看起来才像真的
if [ ! -f "$DEMO" ]; then
  python3 - <<'PY'
import zipfile
with zipfile.ZipFile('/tmp/演示包.zip', 'w') as z:
    z.writestr('项目资料/立项报告.pdf', 'x' * 180000)
    z.writestr('项目资料/海管腐蚀数据.xlsx', 'y' * 92000)
    z.writestr('项目资料/现场照片/挂片-01.jpg', 'z' * 260000)
    z.writestr('项目资料/现场照片/挂片-02.jpg', 'z' * 310000)
    z.writestr('说明.txt', 'hello' * 40)
PY
fi

win_id() {
  python3 - <<'PY'
import Quartz
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly,
                                          Quartz.kCGNullWindowID):
    if "PeaZip" in (w.get("kCGWindowOwnerName") or "") and w.get("kCGWindowLayer") == 0:
        print(w["kCGWindowNumber"]); break
PY
}

shoot() {   # $1 = 输出文件名
  local id; id="$(win_id)"
  [ -n "$id" ] || { echo "找不到 PeaZip 窗口" >&2; return 1; }
  screencapture -x -o -l "$id" "$OUT/$1"
  echo "  ✓ $OUT/$1"
}

quit_app() { osascript -e 'tell application "PeaZip" to quit' 2>/dev/null || true; sleep 2; }

echo "① 浅色"
quit_app
open -na /Applications/PeaZip.app --args -AppleInterfaceStyle Light "$DEMO" 2>/dev/null || open -na /Applications/PeaZip.app
sleep 4
shoot "light.png"

echo "② 深色"
quit_app
open -na /Applications/PeaZip.app --args -AppleInterfaceStyle Dark "$DEMO" 2>/dev/null || open -na /Applications/PeaZip.app
sleep 4
shoot "dark.png"

echo "③ 解压进行中（用访达服务触发一个大包，趁进度弹窗出现时抓）"
swift tools/service_call.swift /tmp/演示包.zip "用 PeaZip 测试压缩包完整性" >/dev/null 2>&1 || true
sleep 1
shoot "extracting.png" || true

quit_app
echo
echo "完成。检查三张图是否合理："
ls -la "$OUT" | sed 's/^/  /'
echo
echo "然后把它们加进 README.md（路径已固定）："
echo "  ![浅色](assets/readme/shots/light.png)"
echo "  ![深色](assets/readme/shots/dark.png)"
echo "  ![解压进行中](assets/readme/shots/extracting.png)"
