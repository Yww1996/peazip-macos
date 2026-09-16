#!/bin/bash
# Prove the app is genuinely standalone: rebuild with the engine bundled, then move the
# ORIGINAL PeaZip out of /Applications and re-run the round-trip self-check. If it still
# passes, the original can safely be replaced. The original is always put back.
set -uo pipefail
cd "$(dirname "$0")"

ORIG="/Applications/PeaZip.app"
STASH="/tmp/PeaZip-original-stashed.app"
APP="build/PeaZip27.app"
EXE="$APP/Contents/MacOS/PeaZip27"

echo "############ 1) 重建（引擎会被打进 bundle）############"
bash package.sh 2>&1 | grep -vE "appintents|linkd|Re-initialization|xpc:connection|SignalReady|SIGNAL|^\[[0-9]+/" | sed 's/^/  /'
echo
echo "############ 2) 内置引擎自检（此时原版还在）############"
"$EXE" --selftest 2>/dev/null | grep -E "7z 引擎|归档引擎|❌" | sed 's/^/  /'

echo
echo "############ 3) 把原版 PeaZip 挪走 ############"
if [ ! -d "$ORIG" ]; then
  echo "  ⚠️  $ORIG 不存在，跳过（本就独立）"
else
  rm -rf "$STASH"
  if mv "$ORIG" "$STASH" 2>/dev/null; then
    echo "  ✅ 已挪到 $STASH"
    MOVED=1
  else
    echo "  ❌ 挪不动（需要管理员权限）—— 无法完成独立性验证"
    MOVED=0
  fi

  if [ "${MOVED:-0}" = "1" ]; then
    echo
    echo "############ 4) 原版不在时自检（这是关键一步）############"
    OUT=$("$EXE" --selftest 2>/dev/null)
    echo "$OUT" | grep -E "7z 引擎|目录扫描|打包|测试|列表|解压|归档引擎|❌" | sed 's/^/  /'
    echo
    if echo "$OUT" | grep -q "归档引擎全程通过"; then
      echo "  ✅✅ 原版已移除，本 app 依然全程可用 —— 真正独立"
    else
      echo "  ❌ 原版移除后失效：引擎没有真正内置"
    fi

    echo
    echo "############ 5) 恢复原版 ############"
    mv "$STASH" "$ORIG" && echo "  ✅ 已恢复 $ORIG"
  fi
fi
