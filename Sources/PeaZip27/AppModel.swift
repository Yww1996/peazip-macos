import Foundation
import SwiftUI
import os

/// App-level logging so launch/open/service events are inspectable from outside the
/// process (`log show --predicate 'subsystem == "com.yww.pea27"'`). A GUI app prints
/// nowhere useful, and "did the Finder hand-off actually happen?" is otherwise
/// unanswerable without screen-recording permission. Module-internal so the AppDelegate
/// can log too.
let appLog = Logger(subsystem: "com.yww.pea27", category: "app")

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    /// Set when this row came from INSIDE an archive: the path within it. Filesystem
    /// rows leave it nil.
    ///
    /// `url` for such a row is synthetic (archive URL + entry path) and does not exist on
    /// disk, which is exactly why `isArchive` must stay false for them — otherwise the
    /// archive actions would hand 7z a path that isn't there.
    var entryPath: String? = nil
    var packedSize: Int64? = nil

    var id: URL { url }

    var fromArchive: Bool { entryPath != nil }

    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz",
        "zst", "zstd", "lzma", "cab", "iso", "jar", "war", "apk", "xz", "pea"
    ]
    var isArchive: Bool {
        fromArchive ? false : Self.archiveExtensions.contains(url.pathExtension.lowercased())
    }

    var kind: String {
        if isDirectory { return "文件夹" }
        let e = url.pathExtension.lowercased()
        if e.isEmpty { return "文件" }
        if isArchive { return "压缩包" }
        switch e {
        case "docx", "doc": return "Word 文稿"
        case "xlsx", "xls": return "Excel 表格"
        case "pptx", "ppt": return "Keynote 演示"
        case "pdf": return "PDF 文稿"
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "heic": return "图像"
        case "mp4", "mov", "mkv": return "影片"
        case "mp3", "wav", "flac", "m4a": return "音频"
        case "txt", "md", "log": return "纯文本"
        case "app": return "应用程序"
        default: return "\(e.uppercased()) 文件"
        }
    }

    var sizeText: String {
        // A filesystem folder has no meaningful size, but an archive folder does: it was
        // aggregated from the entries beneath it, so show it.
        if isDirectory && !(fromArchive && size > 0) { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: modified)
    }

    var symbol: String {
        if isDirectory { return "folder.fill" }
        if isArchive { return "doc.zipper" }
        switch url.pathExtension.lowercased() {
        case "docx", "doc", "pdf", "txt", "md", "rtf": return "doc.text.fill"
        case "xlsx", "xls", "csv": return "tablecells.fill"
        case "pptx", "ppt", "key": return "rectangle.on.rectangle.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "heic": return "photo.fill"
        case "mp4", "mov", "mkv": return "film.fill"
        case "mp3", "wav", "flac", "m4a": return "music.note"
        case "app": return "app.fill"
        default: return "doc.fill"
        }
    }

    var tint: Color {
        if isDirectory { return .accentColor }
        if isArchive { return .orange }
        switch url.pathExtension.lowercased() {
        case "docx", "doc": return .blue
        case "xlsx", "xls", "csv": return .green
        case "pptx", "ppt": return .orange
        case "pdf": return .red
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return .purple
        default: return .secondary
        }
    }
}

struct Place: Identifiable, Hashable {
    let name: String
    let url: URL
    let symbol: String
    var id: String { url.path + name }
}

/// One breadcrumb segment. Identifiable + Equatable with a STABLE id (the path):
/// a fresh, non-identifiable collection read inside a view body makes SwiftUI
/// re-invalidate on every pass.
struct Crumb: Identifiable, Equatable {
    let name: String
    let url: URL
    /// Non-nil for a segment INSIDE an open archive: the folder path within it. Clicking
    /// such a crumb must re-list the archive, not navigate the filesystem.
    var innerPath: String? = nil
    var id: String { url.path + "#" + (innerPath ?? "") }
}

struct OpSheet: Identifiable {
    let id = UUID()
    var title: String
    var detail: String = ""
}

@MainActor
final class AppModel: ObservableObject {
    @Published var currentURL: URL
    @Published var items: [FileItem] = []
    @Published var selection: Set<URL> = []
    @Published var backStack: [URL] = []
    @Published var forwardStack: [URL] = []
    @Published var ascending = true
    @Published var showHidden = false

    @Published var opSheet: OpSheet?
    @Published var logLines: [String] = []
    @Published var busy = false

    // The sheet drives the "add" form
    @Published var addFormat: ArchiveEngine.Format = .zip
    @Published var addArchiveName: String = ""

    init() {
        PrefKey.register()    // before any Prefs.* read, or defaults come back as 0/false
        showHidden = Prefs.showHidden
        addFormat = Prefs.defaultFormat
        // Start somewhere that is NOT TCC-protected. Reading ~/Desktop, ~/Documents
        // or ~/Downloads triggers a macOS privacy prompt, and doing that synchronously
        // from init() blocks the main thread inside scene construction — the window
        // then never appears at all (no crash, no log, just an app with no window).
        currentURL = FileManager.default.homeDirectoryForCurrentUser
        reload()
        loadPlaces()          // off-thread; never blocks the first body evaluation
        // AppKit builds the delegate before SwiftUI builds us, so hand it a reference —
        // that is how files opened from Finder reach this instance.
        AppDelegate.model = self
        appLog.notice("launched · engine=\(ArchiveEngine.sevenZip?.path ?? "缺失", privacy: .public) · lang=\(Bundle.main.preferredLocalizations.joined(separator: ","), privacy: .public)")
        // A launch triggered by double-clicking an archive delivers the URL before this
        // init runs, so the delegate buffers it.
        if !AppDelegate.pendingOpen.isEmpty {
            let pending = AppDelegate.pendingOpen
            AppDelegate.pendingOpen = []
            appLog.notice("flushing \(pending.count, privacy: .public) 个启动时待打开的 URL")
            openFromFinder(pending)
        }
    }

    /// Entry point for files opened from Finder (double-click / "Open With").
    ///
    /// Jumps to the containing folder and selects the file, so the window actually shows
    /// where the file lives. Without this a double-click would launch the app and appear
    /// to do nothing at all.
    func openFromFinder(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let target = first.standardizedFileURL
        let isDir = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        appLog.notice("open from Finder: \(urls.count, privacy: .public) 项 → \(target.path, privacy: .public) isDir=\(isDir, privacy: .public)")
        if isDir {
            go(to: target)
            return
        }
        go(to: target.deletingLastPathComponent())
        selection = Set(urls.map(\.standardizedFileURL))
        appLog.notice("now at \(self.currentURL.path, privacy: .public), selected \(self.selection.count, privacy: .public)")

        // Opening an archive means "show me what is inside it". Merely landing on the
        // containing folder with the file selected made a Finder double-click look like
        // nothing happened.
        if urls.count == 1,
           FileItem.archiveExtensions.contains(target.pathExtension.lowercased()) {
            enterArchive(target)
        }
    }

    // MARK: - Browsing inside an archive
    //
    // Double-clicking an archive used to extract it immediately, which is destructive
    // when you only wanted to see what is in there. Instead the archive is opened and the
    // list shows its entries, like Bandizip / PeaZip's own browser.

    @Published var openArchive: URL?
    @Published var archivePath: String = ""

    var isBrowsingArchive: Bool { openArchive != nil }

    func enterArchive(_ url: URL) {
        appLog.notice("enter archive \(url.lastPathComponent, privacy: .public)")
        openArchive = url
        archivePath = ""
        selection.removeAll()
        loadArchiveEntries()
    }

    func exitArchive() {
        guard let a = openArchive else { return }
        openArchive = nil
        archivePath = ""
        currentURL = a.deletingLastPathComponent()
        reload()
        DispatchQueue.main.async { [weak self] in self?.selection = [a] }
    }

    func goToArchivePath(_ path: String) {
        // Logged: without this there is no way to tell "the double-click never fired" from
        // "it fired but listed the same level again".
        appLog.notice("archive enter path \(path.isEmpty ? "(根目录)" : path, privacy: .public)")
        archivePath = path
        selection.removeAll()
        loadArchiveEntries()
    }

    func loadArchiveEntries() {
        guard let archive = openArchive else { return }
        let inner = archivePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = ArchiveEngine.entries(in: archive)
            let items = AppModel.children(of: entries, archive: archive, under: inner)
            // A protected file (inside another app's container — WeChat, QQ) is not an error
            // as far as 7-Zip is concerned: it just reports nothing. An empty listing for a
            // file that clearly has bytes in it means the system blocked the read, and a
            // blank list would look like a broken app.
            let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let blocked = entries.isEmpty && size > 4096
            // The level is part of the log line: "which folder did it actually list" is the
            // only way to diagnose a descent that appears not to happen.
            appLog.notice("archive level \(inner.isEmpty ? "(根目录)" : inner, privacy: .public) → \(items.count, privacy: .public) 项 / 共 \(entries.count, privacy: .public) 条\(blocked ? " · 疑被系统拦截" : "", privacy: .public)")
            DispatchQueue.main.async {
                // Ignore a result that arrived after the user navigated elsewhere.
                guard let self, self.openArchive == archive, self.archivePath == inner else { return }
                if blocked {
                    self.opSheet = OpSheet(
                        title: "读不到压缩包内容",
                        detail: "\(archive.lastPathComponent) 位于受系统保护的位置（微信 / QQ 等应用的文件夹），PeaZip 没有读取权限。\n\n打开「系统设置 → 隐私与安全性 → 完全磁盘访问权限」，点 + 添加 PeaZip 并打开开关，之后重新打开这个压缩包。")
                    appLog.notice("读取被系统拦截，已提示用户授权完全磁盘访问")
                }
                self.items = items
            }
        }
    }

    /// Immediate children of `parent` inside the archive. `7z l -slt` emits a flat list,
    /// so deeper paths are folded into the folder that directly contains them (with
    /// sizes aggregated, the way a file manager shows a folder).
    nonisolated static func children(of entries: [ArchiveEngine.Entry],
                                     archive: URL, under parent: String) -> [FileItem] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        struct Agg { var size: Int64 = 0; var modified: Date? }
        var dirAgg: [String: Agg] = [:]
        var emptyDirs: Set<String> = []
        var files: [FileItem] = []

        func item(_ name: String, _ inner: String, _ isDir: Bool,
                  _ size: Int64, _ modified: Date?, _ packed: Int64?) -> FileItem {
            FileItem(url: archive.appendingPathComponent(inner), name: name,
                     isDirectory: isDir, size: size, modified: modified ?? .distantPast,
                     entryPath: inner, packedSize: packed)
        }

        for e in entries {
            guard e.path.hasPrefix(prefix) else { continue }
            let rest = String(e.path.dropFirst(prefix.count))
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                let dir = String(rest[..<slash])
                var a = dirAgg[dir] ?? Agg()
                a.size += e.size
                if let m = e.modified, a.modified == nil || m > a.modified! { a.modified = m }
                dirAgg[dir] = a
            } else if e.isDirectory {
                emptyDirs.insert(rest)
            } else {
                let inner = prefix + rest
                files.append(item(rest, inner, false, e.size, e.modified, e.packed))
            }
        }

        var out: [FileItem] = []
        for (dir, agg) in dirAgg {
            out.append(item(dir, prefix + dir, true, agg.size, agg.modified, nil))
        }
        for d in emptyDirs where dirAgg[d] == nil {
            out.append(item(d, prefix + d, true, 0, nil, nil))
        }
        out += files
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Double-click a file inside the archive: extract just it to a scratch folder and
    /// hand it to the default app. Cleaning happens when the archive is closed.
    @Published var previewDir: URL?

    func previewEntry(_ item: FileItem) {
        guard let archive = openArchive, let inner = item.entryPath else { return }
        let tmp = previewDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("peazip27-preview-\(UUID().uuidString)")
        previewDir = tmp
        // quiet: peeking at a file should not throw a modal sheet over the window
        run(title: "打开 \(item.name)", quiet: true) { line in
            let r = ArchiveEngine.extractEntries(archive, paths: [inner], to: tmp, onLine: line)
            if r.ok {
                let f = tmp.appendingPathComponent(inner)
                DispatchQueue.main.async {
                    if FileManager.default.fileExists(atPath: f.path) {
                        NSWorkspace.shared.open(f)
                    }
                }
            }
            return r
        }
    }

    private func cleanPreviewDir() {
        if let d = previewDir { try? FileManager.default.removeItem(at: d) }
        if let d = dragDir { try? FileManager.default.removeItem(at: d) }
        previewDir = nil
        dragDir = nil
    }

    /// Copy (not move) the file dropped from Finder into the open archive's folder first,
    /// so the user sees what is being added. Not used for the drag-out path.
    func importDropped(_ urls: [URL]) {
        addItemsToOpenArchive(urls)
    }

    /// Take the user to the Full Disk Access pane.
    ///
    /// An app cannot grant itself this permission: the list lives in macOS's SIP-protected
    /// TCC database (tccutil only resets entries, never adds them). Opening the pane is the
    /// entire extent of what software is allowed to do here; the switch and the
    /// authentication are the user's.
    static func openFullDiskAccessSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for s in candidates {
            if let u = URL(string: s), NSWorkspace.shared.open(u) {
                appLog.notice("已打开完全磁盘访问设置面板")
                return
            }
        }
        appLog.notice("打开完全磁盘访问设置面板失败")
    }

    /// A folder we are actually allowed to write to.
    ///
    /// macOS refuses writes inside another app's container — WeChat and QQ keep received
    /// files in theirs — and Finder only authorises *reading* the file the user opened, not
    /// writing next to it. Extracting there fails with a bare status=2, which is the
    /// "解压不了" case: the archive opens and lists fine, only the write is denied.
    static func writableRoot(for file: URL) -> (url: URL, note: String?) {
        let parent = file.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) {
            return (parent, nil)
        }
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return (downloads,
                "原位置受系统保护、不可写入（微信 / QQ 等应用文件夹就是这种），已改到 ~/Downloads")
    }

    /// Extract the whole archive, or just the selected entries, next to the archive.
    func extractFromOpenArchive(selectedOnly: Bool) {
        guard let archive = openArchive else { return }
        let paths = selectedOnly ? selection.compactMap { u in
            items.first(where: { $0.url == u })?.entryPath
        } : []
        guard !selectedOnly || !paths.isEmpty else {
            opSheet = OpSheet(title: "解压", detail: "请先选中要解压的内容")
            return
        }
        let (root, note) = Self.writableRoot(for: archive)
        let dest = root
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent +
                                    (selectedOnly ? "-选中项" : ""))
        run(title: "解压 \(selectedOnly ? "\(paths.count) 项" : archive.lastPathComponent)",
            note: note,
            reveal: Prefs.openAfterExtract ? dest : nil) { line in
            ArchiveEngine.extractEntries(archive, paths: paths, to: dest, onLine: line)
        }
    }

    // MARK: - Editing an archive in place

    var canModifyOpenArchive: Bool {
        guard let a = openArchive else { return false }
        return ArchiveEngine.canModify(a)
    }

    /// Why editing is unavailable, for the UI to show instead of a dead button.
    var modifyHint: String? {
        guard let a = openArchive else { return nil }
        return ArchiveEngine.modifyRefusal(a)
    }

    /// Files dropped onto the window (or picked in the panel) are added into the open
    /// archive. Refused formats say why rather than failing silently in the log.
    func addItemsToOpenArchive(_ urls: [URL]) {
        guard let archive = openArchive else { return }
        guard let refusal = ArchiveEngine.modifyRefusal(archive) else {
            let items = Self.existing(urls)
            guard !items.isEmpty else { return }
            run(title: "添加 \(items.count) 项 → \(archive.lastPathComponent)") { line in
                ArchiveEngine.addInto(archive, items: items, onLine: line)
            }
            return
        }
        opSheet = OpSheet(title: "无法添加", detail: refusal)
    }

    func addFilesToOpenArchive() {
        guard let archive = openArchive else { return }
        if let refusal = ArchiveEngine.modifyRefusal(archive) {
            opSheet = OpSheet(title: "无法添加", detail: refusal)
            return
        }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "添加"
        p.message = "选择要添加进 \(archive.lastPathComponent) 的文件或文件夹"
        guard p.runModal() == .OK else { return }
        addItemsToOpenArchive(p.urls)
    }

    func deleteSelectedFromOpenArchive() {
        guard let archive = openArchive else { return }
        if let refusal = ArchiveEngine.modifyRefusal(archive) {
            opSheet = OpSheet(title: "无法删除", detail: refusal)
            return
        }
        let paths = selection.compactMap { u in
            items.first(where: { $0.url == u })?.entryPath
        }
        guard !paths.isEmpty else {
            opSheet = OpSheet(title: "删除", detail: "请先选中要删除的内容")
            return
        }
        // Destructive and irreversible: it rewrites the archive in place.
        let alert = NSAlert()
        alert.messageText = "从压缩包中删除 \(paths.count) 项？"
        alert.informativeText = "将直接修改 \(archive.lastPathComponent) 本身，无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(title: "从压缩包删除 \(paths.count) 项") { line in
            ArchiveEngine.deleteEntries(archive, paths: paths, onLine: line)
        }
    }

    /// Extract a single entry to the scratch folder so it can be dragged out to Finder.
    /// Completion runs on the main thread with the extracted URL, or nil on failure.
    /// Dragging uses a file representation whose load handler can be asynchronous, so the
    /// extraction does not have to finish before the drag begins.
    func extractForDrag(_ item: FileItem, completion: @escaping (URL?) -> Void) {
        guard let archive = openArchive, let inner = item.entryPath else {
            completion(nil)
            return
        }
        let tmp = dragDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("peazip27-drag-\(UUID().uuidString)")
        dragDir = tmp
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ArchiveEngine.extractEntries(archive, paths: [inner], to: tmp, onLine: nil)
            let url = tmp.appendingPathComponent(inner)
            DispatchQueue.main.async {
                completion(r.ok && FileManager.default.fileExists(atPath: url.path) ? url : nil)
            }
        }
    }

    @Published var dragDir: URL?

    // MARK: - Finder services
    //
    // These take explicit URLs: a service can fire on any Finder selection, which is
    // usually NOT what the window happens to be showing, so they must never rely on
    // `selection`/`selectedItems`.

    private static func existing(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Compress the given items into `<name>.<ext>` next to the first one.
    func compressFromService(_ urls: [URL], format: ArchiveEngine.Format) {
        let items = Self.existing(urls)
        guard let first = items.first else { return }
        openFromFinder(items)               // show what is being worked on
        let (dir, note) = Self.writableRoot(for: first)
        let base = items.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : dir.lastPathComponent
        let name = (base.isEmpty ? "archive" : base) + "." + format.ext
        let target = dir.appendingPathComponent(name)
        run(title: "压缩 \(items.count) 个项目 → \(name)", note: note) { line in
            ArchiveEngine.add(sources: items, to: target, format: format,
                              level: Prefs.compressionLevel,
                              exclusions: Prefs.exclusionPatterns,
                              onLine: line)
        }
    }

    /// Extract each archive into a sibling folder named after it — never into the
    /// current directory, so a right-click cannot silently scatter files around.
    func extractFromService(_ urls: [URL]) {
        let archives = Self.existing(urls).filter {
            FileItem.archiveExtensions.contains($0.pathExtension.lowercased())
        }
        guard !archives.isEmpty else {
            opSheet = OpSheet(title: "解压", detail: "选中的项目里没有压缩包")
            return
        }
        openFromFinder(archives)
        let (firstRoot, note) = Self.writableRoot(for: archives[0])
        let firstDest = firstRoot
            .appendingPathComponent(archives[0].deletingPathExtension().lastPathComponent)
        run(title: "解压 \(archives.count) 个压缩包",
            note: note,
            reveal: Prefs.openAfterExtract ? firstDest : nil) { line in
            var last = ArchiveEngine.Result(output: "", status: 0)
            for a in archives {
                let dest = Self.writableRoot(for: a).url
                    .appendingPathComponent(a.deletingPathExtension().lastPathComponent)
                last = ArchiveEngine.extract(a, to: dest, onLine: line)
                if !last.ok { break }
            }
            return last
        }
    }

    func testFromService(_ urls: [URL]) {
        let archives = Self.existing(urls).filter {
            FileItem.archiveExtensions.contains($0.pathExtension.lowercased())
        }
        guard !archives.isEmpty else {
            opSheet = OpSheet(title: "测试", detail: "选中的项目里没有压缩包")
            return
        }
        openFromFinder(archives)
        run(title: "测试完整性（\(archives.count) 个）") { line in
            var last = ArchiveEngine.Result(output: "", status: 0)
            for a in archives {
                line("▸ \(a.lastPathComponent)")
                last = ArchiveEngine.test(a, onLine: line)
                if !last.ok { break }
            }
            return last
        }
    }

    // MARK: - Navigation

    // Places are pre-loaded OFF the main thread and stored. Computing them inside a
    // view body means `FileManager` calls against ~/Desktop, ~/Documents and
    // ~/Downloads — all TCC-protected — which block on the privacy prompt while
    // SwiftUI is still evaluating the body, so the window never appears.
    @Published var favorites: [Place] = []
    @Published var volumes: [Place] = [
        Place(name: "文件系统", url: URL(fileURLWithPath: "/"), symbol: "internaldrive")
    ]

    /// Standard folders that exist, decided by listing ~ (allowed) instead of
    /// stat-ing each protected folder (which is what triggers the prompt).
    nonisolated static func buildPlaces() -> ([Place], [Place]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [])
        let wanted: [(String, String, String)] = [
            ("Desktop", "桌面", "desktopcomputer"),
            ("Documents", "文档", "doc.text"),
            ("Downloads", "下载", "arrow.down.circle"),
            ("Movies", "影片", "film"),
            ("Music", "音乐", "music.note"),
            ("Pictures", "图片", "photo"),
        ]
        var fav: [Place] = [
            Place(name: "主目录", url: home, symbol: "house")
        ]
        for (dir, label, sym) in wanted where present.contains(dir) {
            fav.append(Place(name: label, url: home.appendingPathComponent(dir), symbol: sym))
        }

        var vols: [Place] = [
            Place(name: "文件系统", url: URL(fileURLWithPath: "/"), symbol: "internaldrive")
        ]
        if let v = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                               includingPropertiesForKeys: nil) {
            for u in v.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                vols.append(Place(name: u.lastPathComponent, url: u, symbol: "externaldrive"))
            }
        }
        return (fav, vols)
    }

    func loadPlaces() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (fav, vols) = AppModel.buildPlaces()
            DispatchQueue.main.async {
                self?.favorites = fav
                self?.volumes = vols
            }
        }
    }

    var home: Place {
        Place(name: "主目录", url: FileManager.default.homeDirectoryForCurrentUser, symbol: "house")
    }

    func go(to url: URL, record: Bool = true) {
        let dest = url.standardizedFileURL
        // Any filesystem navigation leaves archive browsing behind.
        let wasBrowsing = isBrowsingArchive
        if wasBrowsing {
            openArchive = nil
            archivePath = ""
            cleanPreviewDir()
        }
        if dest.path == currentURL.path {
            // Leaving an archive without moving: the list must go back to the folder
            // listing, or it would keep showing entries for a closed archive.
            if wasBrowsing { selection.removeAll(); reload() }
            return
        }
        if record { backStack.append(currentURL); forwardStack.removeAll() }
        currentURL = dest
        selection.removeAll()
        reload()
    }

    func goBack() {
        // Inside an archive, "back" means leaving the archive: that is where the user came
        // from. Without this the path changed while the list stayed on the archive, because
        // reload() deliberately bails while browsing.
        if isBrowsingArchive { exitArchive(); return }
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        currentURL = prev
        selection.removeAll()
        reload()
    }

    func goForward() {
        guard !isBrowsingArchive else { return }
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
        selection.removeAll()
        reload()
    }

    func goUp() {
        if isBrowsingArchive {
            // Inside the archive: step up one level, or out of the archive at the root.
            if archivePath.isEmpty {
                exitArchive()
            } else if let slash = archivePath.lastIndex(of: "/") {
                goToArchivePath(String(archivePath[..<slash]))
            } else {
                goToArchivePath("")
            }
            return
        }
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        go(to: parent)
    }

    var canGoBack: Bool { isBrowsingArchive || !backStack.isEmpty }
    var canGoForward: Bool { !isBrowsingArchive && !forwardStack.isEmpty }
    var canGoUp: Bool { isBrowsingArchive || currentURL.path != "/" }

    /// Clickable path components for the breadcrumb bar.
    ///
    /// Built from `pathComponents`, NOT by looping on `deletingLastPathComponent()`:
    /// for a directory URL that call does not actually shorten the path (it keeps a
    /// trailing slash), so `parent.path == u.path` never becomes true and the loop
    /// spins forever — which froze the whole window at 0×0 with the main thread at
    /// 100% CPU. `pathComponents` always terminates.
    var crumbs: [Crumb] {
        let comps = currentURL.standardizedFileURL.pathComponents
        var out: [Crumb] = []
        var url = URL(fileURLWithPath: "/")
        for (i, c) in comps.enumerated() {
            if i == 0 {
                out.append(Crumb(name: "/", url: url))
                continue
            }
            // `c` is never ".." or "." in a standardized URL
            url.appendPathComponent(c)
            out.append(Crumb(name: c, url: url))
        }
        // While browsing, the trail continues through the archive: the archive itself,
        // then each folder inside it.
        if let a = openArchive {
            out.append(Crumb(name: a.lastPathComponent, url: a, innerPath: ""))
            if !archivePath.isEmpty {
                var acc = ""
                for part in archivePath.split(separator: "/") {
                    acc = acc.isEmpty ? String(part) : acc + "/" + part
                    out.append(Crumb(name: String(part), url: a, innerPath: acc))
                }
            }
        }
        return out
    }

    // MARK: - Listing

    /// Never touch the disk on the main thread: a TCC-protected folder (Desktop,
    /// Documents, Downloads) can block for as long as its consent prompt is up,
    /// which stalls the whole UI. Scan off-thread and publish on main.
    func reload() {
        // While an archive is open the list belongs to it; a filesystem rescan would
        // replace archive entries with the containing folder's contents.
        if isBrowsingArchive { return }
        let dir = currentURL
        let hidden = showHidden
        let asc = ascending
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = AppModel.scan(dir, includeHidden: hidden, ascending: asc)
            DispatchQueue.main.async {
                // Both conditions matter: the user may have entered an archive while this
                // scan was in flight, and publishing afterwards would replace the archive
                // listing with the folder's contents (currentURL is unchanged in that
                // case, so the path check alone is not enough).
                guard let self, !self.isBrowsingArchive,
                      self.currentURL.path == dir.path else { return }
                self.items = scanned
            }
        }
    }

    nonisolated static func scan(_ dir: URL, includeHidden: Bool, ascending: Bool) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: keys,
                                                     options: includeHidden ? [] : [.skipsHiddenFiles]) else {
            return []
        }
        var out: [FileItem] = []
        out.reserveCapacity(urls.count)
        for u in urls {
            let rv = try? u.resourceValues(forKeys: Set(keys))
            if !includeHidden, rv?.isHidden == true { continue }
            out.append(FileItem(url: u,
                                name: u.lastPathComponent,
                                isDirectory: rv?.isDirectory ?? false,
                                size: Int64(rv?.fileSize ?? 0),
                                modified: rv?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let r = a.name.localizedStandardCompare(b.name)
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    var statusText: String {
        let dirs = items.filter(\.isDirectory).count
        let files = items.count - dirs
        let total = items.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        let f = ByteCountFormatter(); f.countStyle = .file
        if isBrowsingArchive {
            let packed = items.compactMap(\.packedSize).reduce(Int64(0), +)
            var s = "压缩包内：\(dirs) 个文件夹，\(files) 个文件，解压后 \(f.string(fromByteCount: total))"
            if packed > 0, total > 0 {
                s += "，压缩后 \(f.string(fromByteCount: packed))（\(Int(Double(packed) / Double(total) * 100))%）"
            }
            return s
        }
        return "\(dirs) 个文件夹，\(files) 个文件，共 \(f.string(fromByteCount: total))"
    }

    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var selectedArchives: [FileItem] { selectedItems.filter(\.isArchive) }

    // MARK: - Operations

    /// `quiet` operations (double-click previews) do not raise the log sheet — a sheet
    /// popping up every time you peek at a file is worse than no feedback. A failure
    /// still surfaces itself, so nothing is swallowed.
    private func run(title: String,
                     note: String? = nil,
                     reveal: URL? = nil,
                     quiet: Bool = false,
                     _ work: @escaping (@escaping (String) -> Void) -> ArchiveEngine.Result) {
        logLines = note.map { ["▸ \(title)", "⚠️ \($0)"] } ?? ["▸ \(title)"]
        if !quiet { opSheet = OpSheet(title: title) }
        busy = true
        let append: (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { self?.logLines.append(line) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = work(append)
            DispatchQueue.main.async {
                guard let self else { return }
                appLog.notice("op \(title, privacy: .public) → \(r.ok ? "ok" : "FAILED", privacy: .public) status=\(r.status, privacy: .public)")
                self.logLines.append(r.ok ? "✅ 完成" : "❌ 失败（退出码 \(r.status)）")
                if !r.ok { self.logLines.append(contentsOf: r.output.split(separator: "\n").suffix(12).map(String.init)) }
                if r.ok, let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                self.busy = false
                // A quiet operation only makes itself heard when it goes wrong.
                if quiet && !r.ok { self.opSheet = OpSheet(title: title) }
                // While browsing, the list belongs to the archive: rescanning the
                // filesystem would show the containing folder instead of the new state
                // (this is what makes add/delete appear to do nothing).
                if self.isBrowsingArchive { self.loadArchiveEntries() } else { self.reload() }
            }
        }
    }

    func beginAdd() {
        let sources = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        let base = sources.count == 1
            ? sources[0].deletingPathExtension().lastPathComponent
            : currentURL.lastPathComponent
        addArchiveName = base.isEmpty ? "archive" : base
        logLines = []                     // makes the sheet show the form, not the log
        opSheet = OpSheet(title: "添加到压缩包", detail: "\(sources.count) 个项目")
    }

    /// PeaZip's "Convert": unpack to a scratch dir, repack in the target format,
    /// then drop the scratch. 7z itself has no in-place convert.
    @Published var convertFormat: ArchiveEngine.Format = .sevenZ

    func beginConvert() {
        guard let arc = selectedArchives.first else {
            opSheet = OpSheet(title: "转换", detail: "请先选中一个压缩包")
            return
        }
        let fmt = convertFormat
        let target = currentURL
            .appendingPathComponent(arc.url.deletingPathExtension().lastPathComponent + "." + fmt.ext)
        run(title: "转换 \(arc.name) → \(target.lastPathComponent)") { line in
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("peazip27-convert-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let extracted = ArchiveEngine.extract(arc.url, to: tmp, onLine: line)
            guard extracted.ok else { return extracted }
            return ArchiveEngine.add(sources: [tmp], to: target, format: fmt,
                                     level: Prefs.compressionLevel,
                                     exclusions: Prefs.exclusionPatterns,
                                     onLine: line)
        }
    }

    func commitAdd(format: ArchiveEngine.Format, name: String, destination: URL?) {
        let sources = selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)
        var fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty { fileName = "archive" }
        if !fileName.lowercased().hasSuffix("." + format.ext) { fileName += "." + format.ext }
        let dir = destination ?? currentURL
        let archive = dir.appendingPathComponent(fileName)
        run(title: "添加 \(sources.count) 个项目 → \(archive.lastPathComponent)") { line in
            ArchiveEngine.add(sources: sources, to: archive, format: format,
                              level: Prefs.compressionLevel,
                              exclusions: Prefs.exclusionPatterns,
                              onLine: line)
        }
    }

    func beginExtract(toNewFolder: Bool = false) {
        guard let arc = selectedArchives.first else {
            opSheet = OpSheet(title: "解压", detail: "请先选中一个压缩包")
            return
        }
        let (safeRoot, note) = Self.writableRoot(for: arc.url)
        let safeDest = toNewFolder
            ? safeRoot.appendingPathComponent(arc.url.deletingPathExtension().lastPathComponent)
            : safeRoot
        run(title: "解压 \(arc.name) → \(safeDest.lastPathComponent)",
            note: note,
            reveal: Prefs.openAfterExtract ? safeDest : nil) { line in
            ArchiveEngine.extract(arc.url, to: safeDest, onLine: line)
        }
    }

    func beginTest() {
        guard let arc = selectedArchives.first else {
            opSheet = OpSheet(title: "测试", detail: "请先选中一个压缩包")
            return
        }
        run(title: "测试完整性 \(arc.name)") { line in
            ArchiveEngine.test(arc.url, onLine: line)
        }
    }

    func beginSecureDelete() {
        let targets = selectedItems.map(\.url)
        guard !targets.isEmpty else {
            opSheet = OpSheet(title: "安全删除", detail: "请先选中要删除的项目")
            return
        }
        run(title: "安全删除 \(targets.count) 个项目（\(Prefs.securePasses) 遍覆写）") { line in
            var last = ArchiveEngine.Result(output: "", status: 0)
            for t in targets {
                last = ArchiveEngine.secureDelete(t, passes: Prefs.securePasses, onLine: line)
                if !last.ok { break }
            }
            return last
        }
    }

    /// ⌘O / 菜单「打开」: act on the current selection in whichever mode we are in.
    /// Exists so that entering a folder never depends on double-click semantics.
    func openSelection() {
        guard let u = selection.first,
              let item = items.first(where: { $0.url == u }) else { return }
        open(item)
    }

    /// Double-click behaviour.
    func open(_ item: FileItem) {
        // Inside an archive: folders descend, files are extracted to a scratch folder and
        // opened with the default app (a preview, not a permanent extraction).
        if item.fromArchive {
            if item.isDirectory {
                goToArchivePath(item.entryPath ?? "")
            } else {
                previewEntry(item)
            }
            return
        }
        if item.isDirectory {
            go(to: item.url)
        } else if item.isArchive {
            // Browse it — extracting on double-click destroys the "just look inside" case.
            enterArchive(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }
}
