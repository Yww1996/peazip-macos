#!/bin/bash
# Fire a service on a single file, keep the directory, and report BOTH the app's own
# operation log and the resulting artifacts.
set -uo pipefail
cd "$(dirname "$0")"

echo "=== 安装最新构建 ==="
bash install.sh 2>&1 | grep -E "二进制一致|引擎自检|签名校验|主窗口|❌" | sed 's/^/  /'

echo
echo "=== 造测试目录 ==="
rm -rf /tmp/svc2 && mkdir -p /tmp/svc2
printf 'hello\n' > /tmp/svc2/单文件.txt
printf 'yy\n'    > /tmp/svc2/另一个.txt

echo
echo "=== 触发：用 PeaZip 压缩为 ZIP（选中整个文件夹）==="
swift tools/service_call.swift /tmp/svc2 "用 PeaZip 压缩为 ZIP" 2>/dev/null | grep NSPerformService
sleep 8
echo "  产物:"; ls -la /tmp/svc2/ | tail -4 | sed 's/^/    /'

echo
echo "=== 触发：用 PeaZip 压缩为 7z（选中单个文件）==="
swift tools/service_call.swift /tmp/svc2/单文件.txt "用 PeaZip 压缩为 7z" 2>/dev/null | grep NSPerformService
sleep 8
echo "  产物:"; ls -la /tmp/svc2/ | tail -5 | sed 's/^/    /'

echo
echo "=== 应用日志 ==="
log show --last 90s --predicate 'subsystem == "com.yww.pea27"' --style compact 2>/dev/null \
  | grep -E "service |op " | sed 's/.*] /  /'

echo
echo "=== 校验产物内容 ==="
Z=/Applications/PeaZip.app/Contents/Resources/bin/7z/7z
for f in /tmp/svc2/*.zip /tmp/svc2/*.7z; do
  [ -f "$f" ] || continue
  echo "  --- $(basename "$f") ---"
  $Z l "$f" 2>/dev/null | sed -n '/-------------------/,$p' | tail -5 | sed 's/^/    /'
done
