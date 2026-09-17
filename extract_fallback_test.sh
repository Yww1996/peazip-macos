#!/bin/bash
# "解压不了" reproduction: an archive sitting in a folder the system refuses to write to
# (WeChat/QQ keep received files inside their own container, and Finder only authorises
# reading the file you opened). The app must fall back to a writable folder instead of
# failing with a bare status=2.
set -uo pipefail
cd "$(dirname "$0")"

V=.build/release/PeaZip27
WORK=/tmp/pz_extract_test
rm -rf "$WORK"; mkdir -p "$WORK/源" "$WORK/只读目录"

# a small archive to play with
printf 'hello\n' > "$WORK/源/a.txt"
printf 'world\n' > "$WORK/源/b.txt"
(cd "$WORK/源" && zip -q -r "$WORK/测试包.zip" .)

echo "############ 情形一：普通目录（应当就地解压）############"
mkdir -p "$WORK/普通目录"
cp "$WORK/测试包.zip" "$WORK/普通目录/"
$V --extract-test "$WORK/普通目录/测试包.zip" 2>/dev/null | sed 's/^/  /'

echo
echo "############ 情形二：不可写目录（微信那种，应当改道 ~/Downloads）############"
cp "$WORK/测试包.zip" "$WORK/只读目录/"
chmod 500 "$WORK/只读目录"
$V --extract-test "$WORK/只读目录/测试包.zip" 2>/dev/null | sed 's/^/  /'
chmod 700 "$WORK/只读目录"

echo
echo "############ 7z 自己在这种目录下会怎样（对照）############"
chmod 500 "$WORK/只读目录"
ENG=$(dirname "$(readlink -f /Applications/PeaZip.app/Contents/MacOS/PeaZip27)")/../Resources/bin/7z/7z
if [ -x "$ENG" ]; then
  "$ENG" x -y -o"$WORK/只读目录/out" "$WORK/只读目录/测试包.zip" 2>&1 | tail -3 | sed 's/^/  /'
  echo "  → 退出码 ${PIPESTATUS[0]}"
else
  echo "  引擎未找到: $ENG"
fi
chmod 700 "$WORK/只读目录"
