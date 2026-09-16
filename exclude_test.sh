#!/bin/bash
# Verify the exclusion settings actually control what lands in the archive, under
# several combinations, including the new hidden-file rule and custom patterns.
set -uo pipefail
cd "$(dirname "$0")"
Z=/Applications/PeaZip.app/Contents/Resources/bin/7z/7z
APP=/Applications/PeaZip.app

setup() {
  rm -rf /tmp/excl2 && mkdir -p /tmp/excl2/项目/{.git,src,node_modules,build}
  printf 'readme\n' > /tmp/excl2/项目/readme.md
  printf 'env\n'    > /tmp/excl2/项目/.env
  printf 'cfg\n'    > /tmp/excl2/项目/.git/config
  printf 'ds\n'     > /tmp/excl2/项目/.DS_Store
  printf 'main\n'   > /tmp/excl2/项目/src/main.txt
  printf 'nm\n'     > /tmp/excl2/项目/node_modules/x.txt
  printf 'th\n'     > /tmp/excl2/项目/Thumbs.db
  printf 'obj\n'    > /tmp/excl2/项目/build/out.o
  printf 'log\n'    > /tmp/excl2/项目/debug.log
}

restart() {
  pkill -f "Contents/MacOS/PeaZip27" 2>/dev/null || true
  sleep 2
  open "$APP"
  for _ in $(seq 1 24); do sleep 0.5; [ -n "$(pgrep -f 'Contents/MacOS/PeaZip27')" ] && break; done
  sleep 2
}

run_case() {                       # run_case <说明>
  rm -f /tmp/excl2/*.zip
  swift tools/service_call.swift /tmp/excl2/项目 "用 PeaZip 压缩为 ZIP" >/dev/null 2>&1
  sleep 7
  echo "  【$1】打包内容:"
  $Z l /tmp/excl2/项目.zip 2>/dev/null | grep -E "^[0-9]{4}-" | awk '{print "    " $NF}'
}

echo "############ 启动 app ############"
restart
echo "  进程: $(pgrep -f 'Contents/MacOS/PeaZip27' | head -1)"

setup
echo
echo "############ 场景 1：macOS 垃圾开 / 隐藏文件开 / Windows 开 / 自定义 node_modules、*.log、build ############"
defaults write com.yww.pea27 pref.excludeMacJunk -bool true
defaults write com.yww.pea27 pref.excludeHidden -bool true
defaults write com.yww.pea27 pref.excludeWindowsJunk -bool true
defaults write com.yww.pea27 pref.excludeCustom -string 'node_modules
*.log
build'
restart
run_case "全部开启"

echo
echo "############ 场景 2：只关掉「隐藏文件」############"
defaults write com.yww.pea27 pref.excludeHidden -bool false
restart
run_case "隐藏文件不排除"

echo
echo "############ 场景 3：全部关闭 ############"
defaults write com.yww.pea27 pref.excludeMacJunk -bool false
defaults write com.yww.pea27 pref.excludeWindowsJunk -bool false
defaults write com.yww.pea27 pref.excludeCustom -string ''
restart
run_case "不排除任何文件"

echo
echo "############ 恢复默认 ############"
defaults write com.yww.pea27 pref.excludeMacJunk -bool true
defaults write com.yww.pea27 pref.excludeHidden -bool true
defaults write com.yww.pea27 pref.excludeWindowsJunk -bool false
defaults write com.yww.pea27 pref.excludeCustom -string ''
restart
echo "  已恢复（macOS 垃圾开 / 隐藏文件开 / Windows 关 / 无自定义）"
echo "  当前规则数: $(defaults read com.yww.pea27 2>/dev/null | grep -c pref.exclude || true)"
rm -rf /tmp/excl2
