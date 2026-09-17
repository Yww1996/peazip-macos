// Dump the icon Finder actually draws for a file. This is the ground truth for
// "what will the user see for a .zip" — NSWorkspace.icon(forFile:) is exactly the API
// Finder uses, so it reflects the app's CFBundleTypeIconFile / UTI declarations.
//
//   swift tools/fileicon.swift <path> <out.png> [px]
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 3 else { fputs("用法: fileicon <文件> <输出.png> [像素]\n", stderr); exit(2) }
let px = a.count > 3 ? (Int(a[3]) ?? 512) : 512
let url = URL(fileURLWithPath: (a[1] as NSString).expandingTildeInPath)

guard FileManager.default.fileExists(atPath: url.path) else {
    fputs("文件不存在: \(url.path)\n", stderr); exit(2)
}

let icon = NSWorkspace.shared.icon(forFile: url.path)
icon.size = NSSize(width: px, height: px)

guard let tiff = icon.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("无法转换图标\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: a[2]))

// Report the name of the icon's source so the caller can tell "my art" from "generic doc".
let name = icon.name() ?? "(无名)"
print("路径      : \(url.path)")
print("图标名    : \(name)")
print("尺寸      : \(icon.size.width)x\(icon.size.height) → \(a[2])")
print("generic?  : \(name.lowercased().contains("generic") ? "是（通用文档图标 ❌）" : "否 ✅")")
