import AppKit
import Darwin
import Foundation

/// Finder extraction owns its work independently of the browser model: neither
/// an open main window nor the progress/error sheets are needed for success.
@MainActor
final class FinderExtractionService: ObservableObject {
    enum Destination: Equatable { case besideArchive, desktop }
    static let shared = FinderExtractionService()
    @Published private(set) var pendingCount = 0
    private let queue = DispatchQueue(label: "com.yww.pea27.finder-extraction", qos: .userInitiated)

    func extract(_ urls: [URL], destination: Destination) {
        pendingCount += 1
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        #if DEBUG
        let desktopRoot = ProcessInfo.processInfo.environment["PEAZIP_TEST_DESKTOP"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? desktop
        #else
        let desktopRoot = desktop
        #endif
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        queue.async {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                                 reason: "访达后台解压")
            let outcome = Result { try Self.perform(urls, destination: destination,
                                                   desktop: desktopRoot, downloads: downloads) }
            ProcessInfo.processInfo.endActivity(activity)
            DispatchQueue.main.async {
                if case .failure(let error) = outcome {
                    let alert = NSAlert()
                    alert.messageText = "解压未完成"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                self.pendingCount -= 1
                AppDelegate.finishBackgroundServicesIfIdle()
            }
        }
    }

    nonisolated static func folderName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        let base = archive.deletingPathExtension().lastPathComponent
        return base.isEmpty ? "解压文件" : base
    }

    /// mkdir reserves the name atomically, including against existing/dangling
    /// symlinks. Never merge into an existing folder or overwrite its contents.
    nonisolated static func reserveFolder(named name: String, under root: URL) throws -> URL {
        for number in 1...10_000 {
            let candidate = root.appendingPathComponent(number == 1 ? name : "\(name) (\(number))",
                                                        isDirectory: true)
            if mkdir(candidate.path, mode_t(0o755)) == 0 { return candidate }
            let failure = errno
            if failure != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure),
                              userInfo: [NSLocalizedDescriptionKey: "无法在「\(root.lastPathComponent)」创建解压文件夹：\(String(cString: strerror(failure)))"])
            }
        }
        throw NSError(domain: "com.yww.pea27.extract", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "同名文件夹过多，请先整理目标位置。"])
    }

    @discardableResult
    nonisolated static func perform(_ urls: [URL], destination: Destination,
                                   desktop: URL, downloads: URL) throws -> [URL] {
        let manager = FileManager.default
        let archives = urls.filter {
            FileItem.archiveExtensions.contains($0.pathExtension.lowercased()) && manager.fileExists(atPath: $0.path)
        }
        guard !archives.isEmpty else {
            throw NSError(domain: "com.yww.pea27.extract", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "选中的项目里没有可解压的压缩包。"])
        }
        var results: [URL] = []
        for archive in archives {
            let parent = archive.deletingLastPathComponent()
            let root = destination == .desktop ? desktop
                : (manager.isWritableFile(atPath: parent.path) ? parent : downloads)
            let folder = try reserveFolder(named: folderName(for: archive), under: root)
            let result = ArchiveEngine.extract(archive, to: folder, onLine: nil)
            guard result.ok else {
                if (try? manager.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? manager.removeItem(at: folder)
                }
                let detail = result.output.split(separator: "\n").suffix(10).joined(separator: "\n")
                throw NSError(domain: "com.yww.pea27.extract", code: Int(result.status),
                              userInfo: [NSLocalizedDescriptionKey: "\(archive.lastPathComponent) 解压失败。\n\(detail)"])
            }
            results.append(folder)
        }
        return results
    }
}
