#!/bin/bash
# Verify the Finder hand-off: build, package, then ask LaunchServices to open an archive
# with our app and confirm from the app's own log that it navigated and selected it.
set -uo pipefail
cd "$(dirname "$0")"

echo "############ 1) 重建 ############"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  bash package.sh 2>&1 | grep -E "二进制一致|图标|引擎|签名校验|主窗口|❌" | sed 's/^/  /'
fi

# Test the INSTALLED app by default — that is the one the user actually double-clicks.
if [ -d "/Applications/PeaZip.app" ] && [ "${TEST_DEV_BUILD:-0}" != "1" ]; then
  APP="/Applications/PeaZip.app"
  echo "  测试对象: 已安装的 $APP"
else
  APP="$PWD/build/PeaZip-dev.app"
  echo "  测试对象: 开发构建 $APP"
fi

echo
echo "############ 2) 造一个测试压缩包 ############"
rm -rf /tmp/peatest && mkdir -p /tmp/peatest/资料
printf '第一份内容\n' > /tmp/peatest/资料/a.txt
printf '第二份内容\n' > /tmp/peatest/资料/b.txt
"$APP/Contents/Resources/bin/7z/7z" a -tzip /tmp/peatest/示例归档.zip /tmp/peatest/资料 >/dev/null 2>&1
ls -la /tmp/peatest/*.zip | sed 's/^/  /'

echo
echo "############ 3) 关掉旧实例 ############"
osascript -e 'tell application "PeaZip" to quit' >/dev/null 2>&1 || true
pkill -f "Contents/MacOS/PeaZip" 2>/dev/null || true
sleep 2

echo
echo "############ 4) 用本 app 打开这个压缩包（模拟 Finder 双击）############"
open -a "$APP" /tmp/peatest/示例归档.zip && echo "  open 已发出"
sleep 5

echo
echo "############ 5) 从应用自身日志确认它收到了 ############"
LOG=$(log show --last 90s --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null)
if echo "$LOG" | grep -q "open from Finder"; then
  echo "$LOG" | grep -E "open from Finder|now at" | sed 's/.*] //' | sed 's/^/  ✅ /'
else
  echo "  ❌ 应用没有收到 open 事件"
  echo "$LOG" | tail -5 | sed 's/^/    /'
fi

echo
echo "############ 6) 系统是否已把本 app 登记为压缩包处理程序 ############"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -dump 2>/dev/null | grep -A2 -B2 "com.yww.pea27" | grep -E "com.yww.pea27|zip-archive|LSHandlerRank|bindings" | head -8 | sed 's/^/  /'

echo
echo "############ 7) 进程仍健康 ############"
ps -o pid,%cpu,stat -p $(pgrep -f "Contents/MacOS/PeaZip" | head -1) 2>/dev/null | sed 's/^/  /'
