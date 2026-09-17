// Trigger a Finder service on a set of files, exactly as the Finder context menu does.
// Used to exercise the app's real operation path (and its logging) headlessly.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("用法: svc <服务名> <文件…>\n", stderr); exit(2) }
let serviceName = args[1]
let files = Array(args.dropFirst(2))

let pb = NSPasteboard(name: .init("PeaZipSvcTest"))
pb.clearContents()
pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })

let ok = NSPerformService(serviceName, pb)
print("NSPerformService(\"\(serviceName)\") → \(ok ? "已投递" : "失败")")
exit(ok ? 0 : 1)
