// Audit and repair default-handler bindings for archive types.
//
// The original PeaZip.app was removed, but macOS still had content types bound to its
// bundle id — a dangling default, so double-clicking such a file finds no application.
// Anything pointing at a bundle that no longer exists gets re-pointed at the installed
// app; anything bound to a live app is left alone.
import AppKit
import CoreServices

let ourID = "com.yww.pea27"
let types = ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
             "public.tar-archive", "org.gnu.gnu-zip-archive", "org.gnu.gnu-zip-tar-archive",
             "public.bzip2-archive", "public.xz-archive", "com.facebook.zstd-archive",
             "public.iso-image", "com.sun.java-archive", "public.archive"]

func bundleExists(_ id: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
}

var fixed = 0, healthy = 0, unset = 0
for t in types {
    let cur = LSCopyDefaultRoleHandlerForContentType(t as CFString, .all)?
        .takeRetainedValue() as String?
    guard let cur, !cur.isEmpty else {
        print("  \(t.padding(toLength: 34, withPad: " ", startingAt: 0)) 未设置（走系统默认）")
        unset += 1
        continue
    }
    if cur == ourID {
        print("  \(t.padding(toLength: 34, withPad: " ", startingAt: 0)) → \(cur)（已是本 app）")
        healthy += 1
    } else if !bundleExists(cur) {
        let st = LSSetDefaultRoleHandlerForContentType(t as CFString, .all, ourID as CFString)
        print("  \(t.padding(toLength: 34, withPad: " ", startingAt: 0)) → \(cur) 已失效，改为本 app \(st == noErr ? "✅" : "❌")")
        fixed += 1
    } else {
        print("  \(t.padding(toLength: 34, withPad: " ", startingAt: 0)) → \(cur)（其它可用应用，保留）")
        healthy += 1
    }
}
print("  小计：修复 \(fixed)，保留 \(healthy)，未设置 \(unset)")
