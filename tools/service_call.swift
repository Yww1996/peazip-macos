// Invoke a registered macOS Service programmatically, to prove the handler really
// receives it. `NSPerformService` is deprecated but still routes through pbs.
// usage: swift service_call.swift <file> "<menu item name>"
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard CommandLine.arguments.count >= 3 else {
    print("usage: service_call.swift <file> \"<menu item>\"")
    exit(2)
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let item = CommandLine.arguments[2]

let pb = NSPasteboard(name: NSPasteboard.Name("com.yww.pea27.servicetest"))
pb.clearContents()
let wrote = pb.writeObjects([file as NSURL])
print("  粘贴板写入: \(wrote)  条目数: \(pb.pasteboardItems?.count ?? -1)")
print("  文件存在: \(FileManager.default.fileExists(atPath: file.path))")

let ok = NSPerformService(item, pb)
print("  NSPerformService(\"\(item)\") → \(ok)")
RunLoop.current.run(until: Date().addingTimeInterval(2))
