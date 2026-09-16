// Lists on-screen windows via the window server — works without Screen Recording
// or Accessibility permission (unlike screencapture / System Events).
// usage: swift tools/winlist.swift [ownerSubstring] [--all]
//
// NOTE: a bundled app's window owner is its CFBundleName, NOT the executable name.
// "PeaZip27" as an executable surfaces as owner "PeaZip 27" once it's in a bundle,
// so a filter that matches the binary name silently reports "no window" for a
// perfectly healthy app. Filter on a distinctive word, or leave it off entirely.
import CoreGraphics
import Foundation

let knownBundleNames = ["PeaZip 27": "PeaZip27", "PeaZip27": "PeaZip 27"]
let rawFilter = CommandLine.arguments.count > 1 && CommandLine.arguments[1] != "--all"
    ? CommandLine.arguments[1] : nil
// accept either spelling so a bundle/bare-binary mismatch can't hide a window
var filters: [String] = []
if let f = rawFilter {
    filters = [f]
    if let alt = knownBundleNames[f] { filters.append(alt) }
}
// --all includes off-screen windows (a window that never got ordered front is
// invisible to .optionOnScreenOnly and looks like "the app has no window").
let opts: CGWindowListOption = CommandLine.arguments.contains("--all")
    ? [.optionAll, .excludeDesktopElements]
    : [.optionOnScreenOnly, .excludeDesktopElements]

guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("CGWindowListCopyWindowInfo 返回空")
    exit(1)
}

var shown = 0
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    let name = (w[kCGWindowName as String] as? String) ?? ""
    guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
    let width = (b["Width"] as? Double) ?? 0
    let height = (b["Height"] as? Double) ?? 0
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    if !filters.isEmpty,
       !filters.contains(where: { owner.localizedCaseInsensitiveContains($0) }) { continue }
    shown += 1
    print(String(format: "  owner=%@ layer=%d  %.0fx%.0f  title=%@", owner, layer, width, height, name))
}
if shown == 0 {
    print(filters.isEmpty ? "  （屏幕上没有任何窗口）"
                          : "  （没有匹配 '\(filters.joined(separator: "/"))' 的窗口）")
}
