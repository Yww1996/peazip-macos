#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Give archive files a PeaZip-branded Finder icon.

Why CFBundleTypeIconFile was not enough: it only applies to types the app *declares*.
public.zip-archive, public.tar-archive … are declared by macOS itself, so Finder kept
drawing the system's unbranded "sheet with a zipper" icon even though the app owned the
file. The documented override for a type you do not own is an IMPORTED type declaration
carrying UTTypeIconFile.

Usage:  plist_arch_icon.py <Info.plist> [IconName]
"""
import plistlib
import shutil
import sys

ICON = "ArchIcon"

# identifier, description, filename extensions, what it conforms to
TYPES = [
    ("public.zip-archive", "ZIP 压缩包", ["zip"], ["public.archive", "public.data"]),
    ("org.7-zip.7-zip-archive", "7-Zip 压缩包", ["7z"], ["public.archive", "public.data"]),
    ("com.rarlab.rar-archive", "RAR 压缩包", ["rar"], ["public.archive", "public.data"]),
    ("public.tar-archive", "TAR 归档", ["tar"], ["public.archive", "public.data"]),
    ("org.gnu.gnu-zip-archive", "Gzip 压缩文件", ["gz"], ["public.archive", "public.data"]),
    ("org.gnu.gnu-zip-tar-archive", "tar.gz 归档", ["tgz"], ["public.tar-archive", "public.archive"]),
    ("public.bzip2-archive", "Bzip2 压缩文件", ["bz2"], ["public.archive", "public.data"]),
    ("public.xz-archive", "XZ 压缩文件", ["xz"], ["public.archive", "public.data"]),
    ("com.facebook.zstd-archive", "Zstandard 压缩文件", ["zst"], ["public.archive", "public.data"]),
]


def main():
    path = sys.argv[1]
    icon = sys.argv[2] if len(sys.argv) > 2 else ICON

    with open(path, "rb") as f:
        header = f.read(8)
        f.seek(0)
        fmt = plistlib.FMT_BINARY if header.startswith(b"bplist") else plistlib.FMT_XML
        pl = plistlib.load(f)

    shutil.copyfile(path, path + ".bak-archicon")

    # 1. the type the app owns (its own document types)
    for dt in pl.get("CFBundleDocumentTypes", []):
        dt["CFBundleTypeIconFile"] = icon

    # 2. system-owned archive types: imported declarations carrying the icon
    imported = pl.setdefault("UTImportedTypeDeclarations", [])
    by_id = {d.get("UTTypeIdentifier"): d for d in imported}
    for ident, desc, exts, conforms in TYPES:
        decl = by_id.get(ident, {})
        decl["UTTypeIdentifier"] = ident
        decl["UTTypeDescription"] = desc
        decl["UTTypeIconFile"] = icon
        decl["UTTypeConformsTo"] = conforms
        decl["UTTypeTagSpecification"] = {"public.filename-extension": exts}
        if ident not in by_id:
            imported.append(decl)

    with open(path, "wb") as f:
        plistlib.dump(pl, f, fmt=fmt)

    print("  已写入 %d 个已导入类型声明，图标 = %s" % (len(TYPES), icon))
    print("  备份: %s.bak-archicon" % path)


if __name__ == "__main__":
    main()
