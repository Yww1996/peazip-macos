#!/bin/bash
# Keep versioned framework symlinks, but avoid chains via Versions/Current.
# 7-Zip rejects some symlinks traversing another link, leaving empty placeholders.
# A direct link into the identical version directory needs no unsafe extraction flag.
set -euo pipefail
FRAMEWORK="$1"
VERSION_DIR=$(readlink "$FRAMEWORK/Versions/Current")
case "$VERSION_DIR" in
  ''|*[!A-Za-z0-9._-]*|.|..) echo 'Invalid framework version directory' >&2; exit 1 ;;
esac
[ -d "$FRAMEWORK/Versions/$VERSION_DIR" ]
for LINK in "$FRAMEWORK"/*; do
  if [ -L "$LINK" ]; then
    TARGET=$(readlink "$LINK")
    case "$TARGET" in
      Versions/Current/*)
        ln -sfn "Versions/$VERSION_DIR/${TARGET#Versions/Current/}" "$LINK"
        ;;
    esac
  fi
done
