#!/bin/bash
# Install Zuno transactionally; preserve unrelated upstream PeaZip installations.
set -euo pipefail
cd "$(dirname "$0")"
HEADLESS_PACKAGE=1 bash package.sh
SRC="$PWD/build/Zuno.app"
DEST=/Applications/Zuno.app
LEGACY=/Applications/PeaZip.app
PB=/usr/libexec/PlistBuddy
OUR_ID=com.yww.pea27
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
identity() { "$PB" -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"; }
[ "$(identity "$SRC")" = "$OUR_ID" ]
codesign --verify --deep --strict "$SRC"
if [ -e "$DEST" ] && [ "$(identity "$DEST")" != "$OUR_ID" ]; then
  echo "Zuno.app 已被其他应用占用，保留当前安装。" >&2
  exit 1
fi
# Refuse replacement while an installed copy is running, rather than terminating work.
if pgrep -f '^/Applications/(Zuno|PeaZip)\.app/Contents/MacOS/(Zuno|PeaZip)( |$)' >/dev/null; then
  echo "请先退出已安装的应用，然后重新运行安装脚本。" >&2
  exit 1
fi
STAGE=$(mktemp -d /Applications/.zuno-install.XXXXXX)
BACKUP=""
REPLACED=0
cleanup() {
  result=$?
  if [ "$result" != 0 ] && [ "$REPLACED" = 1 ]; then
    rm -rf "$DEST"
    if [ -n "$BACKUP" ] && [ -d "$BACKUP/Zuno.app" ]; then mv "$BACKUP/Zuno.app" "$DEST"; fi
  fi
  rm -rf "$STAGE"
  exit "$result"
}
trap cleanup EXIT
ditto "$SRC" "$STAGE/Zuno.app"
codesign --verify --deep --strict "$STAGE/Zuno.app"
BACKUP_ROOT="$HOME/Library/Application Support/Zuno/Install Backups"
mkdir -p "$BACKUP_ROOT"
BACKUP=$(mktemp -d "$BACKUP_ROOT/install.XXXXXX")
if [ -e "$DEST" ]; then mv "$DEST" "$BACKUP/Zuno.app"; fi
REPLACED=1
mv "$STAGE/Zuno.app" "$DEST"
codesign --verify --deep --strict "$DEST"
REPLACED=0
if [ -d "$LEGACY" ] && [ "$(identity "$LEGACY")" = "$OUR_ID" ]; then
  "$LSREG" -u "$LEGACY" 2>/dev/null || true
  mv "$LEGACY" "$BACKUP/PeaZip.app"
fi
for copy in "$BACKUP/Zuno.app" "$BACKUP/PeaZip.app" "$SRC" "$PWD/build/Zuno-dev.app"; do
  [ ! -d "$copy" ] || "$LSREG" -u "$copy" 2>/dev/null || true
done
"$LSREG" -f "$DEST"
echo "已安装：$DEST"
echo "旧安装备份：$BACKUP"
open "$DEST"
