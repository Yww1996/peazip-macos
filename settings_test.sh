#!/bin/bash
# Prove the Settings window's preferences actually change what the archiver does.
# Sets prefs, fires a service, and inspects BOTH the 7z arguments (from the app log)
# and the resulting archive contents.
set -uo pipefail
cd "$(dirname "$0")"

echo "############ 1) 安装 ############"
bash install.sh 2>&1 | grep -E "二进制一致|引擎自检|签名校验|主窗口|❌" | sed 's/^/  /'

echo
echo "############ 2) 造带垃圾文件的测试素材 ############"
rm -rf /tmp/preftest && mkdir -p /tmp/preftest/素材
printf '正文\n' > /tmp/preftest/素材/正文.txt
# the exact noise a real macOS folder carries
printf '\0\0\0\0' > /tmp/preftest/素材/.DS_Store
mkdir -p /tmp/preftest/素材/__MACOSX && printf 'junk' > /tmp/preftest/素材/__MACOSX/x
printf 'junk' > /tmp/preftest/素材/._正文.txt
ls -la /tmp/preftest/素材/ | sed 's/^/  /'

app_restart() {
  pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
  sleep 2
  open /Applications/PeaZip.app
  for _ in $(seq 1 24); do sleep 0.5; [ -n "$(pgrep -f 'Contents/MacOS/PeaZip27')" ] && break; done
  sleep 2
}

echo
echo "############ 3) 设置：级别 9 + 排除 macOS 垃圾 ############"
defaults write com.yww.pea27 pref.compressionLevel -int 9
defaults write com.yww.pea27 pref.excludeMacMeta -bool true
defaults write com.yww.pea27 pref.defaultFormat -string zip
app_restart
rm -f /tmp/preftest/*.zip
swift tools/service_call.swift /tmp/preftest/素材 "用 PeaZip 压缩为 ZIP" 2>/dev/null | grep NSPerformService
sleep 8
echo "  日志（应看到 mx=9 exclude=true）:"
log show --last 60s --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null | grep "7z add" | tail -1 | sed 's/.*] /    /'
echo "  压缩包内是否还有 .DS_Store / __MACOSX / ._ ："
/Applications/PeaZip.app/Contents/Resources/bin/7z/7z l /tmp/preftest/素材.zip 2>/dev/null \
  | grep -cE "\.DS_Store|__MACOSX|\._" | sed 's/^/    命中数: /'
echo "  内容清单:"
/Applications/PeaZip.app/Contents/Resources/bin/7z/7z l /tmp/preftest/素材.zip 2>/dev/null | sed -n '/-------------------/,$p' | tail -6 | sed 's/^/    /'

echo
echo "############ 4) 改设置：级别 1 + 不排除 ############"
defaults write com.yww.pea27 pref.compressionLevel -int 1
defaults write com.yww.pea27 pref.excludeMacMeta -bool false
app_restart
rm -f /tmp/preftest/*.zip
swift tools/service_call.swift /tmp/preftest/素材 "用 PeaZip 压缩为 ZIP" 2>/dev/null | grep NSPerformService
sleep 8
echo "  日志（应看到 mx=1 exclude=false）:"
log show --last 60s --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null | grep "7z add" | tail -1 | sed 's/.*] /    /'
echo "  压缩包内垃圾文件命中数（应 > 0）:"
/Applications/PeaZip.app/Contents/Resources/bin/7z/7z l /tmp/preftest/素材.zip 2>/dev/null \
  | grep -cE "\.DS_Store|__MACOSX|\._" | sed 's/^/    命中数: /'

echo
echo "############ 5) 恢复默认 ############"
defaults write com.yww.pea27 pref.compressionLevel -int 5
defaults write com.yww.pea27 pref.excludeMacMeta -bool true
echo "  已还原（级别 5，排除开启）"
