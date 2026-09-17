import SwiftUI
import AppKit

/// Declines AppKit's saved-state / window-restoration machinery in both directions.
///
/// A *bundled* app takes the restoration path at launch (a bare executable does not), and
/// SwiftUI then expects restoration to produce the launch window rather than creating one.
/// There is no evidence this ever actually failed here: the "the bundle has no window"
/// alarm that prompted this delegate came from a verification script filtering on the
/// executable name, while a bundle's window owner is CFBundleName — "PeaZip 27", with a
/// space — so a perfectly healthy app read as windowless for several rounds.
///
/// Kept anyway as cheap insurance: an archiver has no document state worth restoring, and
/// declining outright removes a launch path that cannot help us.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppModel.init`. SwiftUI owns the real model instance (`@StateObject`), and
    /// the delegate is created by AppKit before that instance exists, so the delegate
    /// keeps a weak reference instead of building a second model of its own.
    static weak var model: AppModel?

    /// URLs that arrived before the model existed. Launching the app by double-clicking an
    /// archive delivers `application(_:open:)` during launch, when `model` is still nil —
    /// without buffering, that first open is silently dropped.
    static var pendingOpen: [URL] = []

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Refusing restoration in applicationShouldRestoreApplicationState is not always
        // consulted early enough — AppKit's reopen path still runs and can produce NO
        // window at all. Deleting the state before it is read is deterministic.
        Self.clearSavedState()
    }

    private static func clearSavedState() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/\(id).savedState")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? FileManager.default.removeItem(at: dir)
        appLog.notice("cleared stale saved window state")
    }

    /// Files arriving from Finder (double-click, "Open With", drag onto the Dock icon).
    /// Called on the main thread, hence assumeIsolated.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            guard let model = Self.model else {
                Self.pendingOpen.append(contentsOf: urls)   // launch-time open
                return
            }
            model.openFromFinder(urls)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Watch for anything closing our windows: with "quit when the last window closes"
        // in place, an unexpected close silently kills the app seconds after launch.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            let t = w.title.isEmpty ? "(无题)" : w.title
            appLog.notice("窗口即将关闭: \(t, privacy: .public) \(Int(w.frame.width))x\(Int(w.frame.height), privacy: .public)")
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            appLog.notice("窗口成为 key: \(w.title.isEmpty ? "(无题)" : w.title, privacy: .public)")
        }
        // AppKit kills an idle app outright ("Attempting sudden termination" →
        // NSTerminateNow), which made the window disappear seconds after launch: the
        // process was gone by ~10s. A file browser has no unsaved document to save, so
        // AppKit considers it terminable at any idle moment.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("保持主窗口可见")
        // Finder right-click → 服务 submenu. The selector names must match the
        // NSMessage values declared in Info.plist's NSServices array.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)
        Self.ensureWindowAppears()
    }

    /// Nothing guarantees the launch window is actually presented. macOS remembers "this
    /// app quit with no windows open" and that record SUPPRESSES the window at next launch
    /// — `.defaultLaunchBehavior(.presented)` does not override it, and the record does not
    /// live in the savedState directory we can delete. The app then runs with a live
    /// process, a working engine and no window at all.
    ///
    /// So: verify, and if nothing showed up, drive our own 打开主窗口 menu item — the exact
    /// same path ⌘N uses.
    private static func ensureWindowAppears() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let all = NSApp.windows
            let inventory = all.map {
                let t = $0.title.isEmpty ? "(无题)" : $0.title
                return "\(t) 可见=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))"
            }.joined(separator: " | ")
            appLog.notice("窗口盘点 \(all.count, privacy: .public) 个: \(inventory, privacy: .public)")

            // A window OBJECT can exist without ever having been ordered on screen — that
            // is the state this app kept landing in. Ordering it front is enough, and far
            // cheaper than creating another one.
            if let w = all.first(where: { $0.contentViewController != nil && $0.frame.height > 200 }) {
                // A restored frame can point at a Space or display that no longer exists,
                // which leaves the window alive but nowhere: isVisible is true, the window
                // server has never heard of it. Put it on a screen that exists, allow it to
                // follow us into the active Space, and order it front regardless of
                // activation.
                if let screen = NSScreen.main ?? NSScreen.screens.first {
                    let v = screen.visibleFrame
                    var f = w.frame
                    f.size.width = min(max(f.width, 1100), v.width)
                    f.size.height = min(max(f.height, 600), v.height)
                    f.origin.x = v.midX - f.width / 2
                    f.origin.y = v.midY - f.height / 2
                    w.setFrame(f, display: true)
                }
                w.collectionBehavior.insert(.moveToActiveSpace)
                w.orderFrontRegardless()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let onScreen = w.screen != nil ? "是" : "否"
                appLog.notice("已复位并提到前台 · 在屏=\(onScreen, privacy: .public) · occlusion=\(w.occlusionState.contains(.visible), privacy: .public)")
                return
            }
            appLog.notice("没有可用窗口 —— 触发「打开主窗口」")
            _ = openMainWindowViaMenu()
        }
    }

    private static func openMainWindowViaMenu() -> Bool {
        guard let main = NSApp.mainMenu else { return false }
        for top in main.items {
            guard let sub = top.submenu else { continue }
            for item in sub.items where item.title.contains("打开主窗口") {
                guard let action = item.action else { continue }
                let ok = NSApp.sendAction(action, to: item.target, from: item)
                appLog.notice("openMainWindowViaMenu → \(ok, privacy: .public)")
                return ok
            }
        }
        appLog.notice("openMainWindowViaMenu: 找不到菜单项")
        return false
    }

    /// Closing the last window quits, like every other macOS archiver. The alternative is
    /// a live process with no window and no obvious way back to one — which is exactly
    /// what happened while File ▸ New Window was replaced with an empty command group.
    /// A Service invocation simply relaunches the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Finder services (Info.plist → NSServices)

    private func serviceURLs(_ pboard: NSPasteboard) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    private func dispatch(_ pboard: NSPasteboard, name: String,
                          _ action: @escaping @MainActor (AppModel, [URL]) -> Void) {
        let urls = serviceURLs(pboard)
        appLog.notice("service \(name, privacy: .public): \(urls.count, privacy: .public) 项")
        MainActor.assumeIsolated {
            NSApp.activate(ignoringOtherApps: true)
            guard let model = Self.model, !urls.isEmpty else { return }
            action(model, urls)
        }
    }

    @objc func peaCompressZIP(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        dispatch(pboard, name: "compressZIP") { $0.compressFromService($1, format: .zip) }
    }

    @objc func peaCompress7Z(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        dispatch(pboard, name: "compress7Z") { $0.compressFromService($1, format: .sevenZ) }
    }

    @objc func peaExtract(_ pboard: NSPasteboard, userData: String,
                          error: AutoreleasingUnsafeMutablePointer<NSString>) {
        dispatch(pboard, name: "extract") { $0.extractFromService($1) }
    }

    @objc func peaTest(_ pboard: NSPasteboard, userData: String,
                       error: AutoreleasingUnsafeMutablePointer<NSString>) {
        dispatch(pboard, name: "test") { $0.testFromService($1) }
    }
}

@main
struct PeaZip27App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    init() {
        // GUI apps don't write to stdout, so a headless self-check is the only way to
        // prove the engine and the directory scan actually work inside the real bundle.
        if CommandLine.arguments.contains("--selftest") { Self.selftest() }
        // Engine update path, verifiable without clicking anything in Settings.
        if CommandLine.arguments.contains("--engine-check") { EngineUpdater.headless(forceInstall: false) }
        if CommandLine.arguments.contains("--engine-update") { EngineUpdater.headless(forceInstall: true) }
        // Archive browsing, verifiable without clicking: --list <archive>
        // Extraction destination, verifiable without clicking: --extract-test <archive>
        if let i = CommandLine.arguments.firstIndex(of: "--extract-test"),
           i + 1 < CommandLine.arguments.count {
            Self.extractTest(CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--list"),
           i + 1 < CommandLine.arguments.count {
            Self.listArchive(CommandLine.arguments[i + 1])
        }
        // In-place editing, verifiable without clicking: --edit-test <archive>
        if let i = CommandLine.arguments.firstIndex(of: "--edit-test"),
           i + 1 < CommandLine.arguments.count {
            Self.editTest(CommandLine.arguments[i + 1])
        }
    }

    /// Headless check of in-place editing: add → verify → delete → verify, and the refusal
    /// path for formats 7-Zip cannot write (RAR being the one users actually hit).
    static func editTest(_ path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        print("PeaZip 压缩包编辑自检")
        print("  归档      : \(url.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("  ❌ 文件不存在"); exit(1)
        }
        print("  可修改    : \(ArchiveEngine.canModify(url) ? "✅ 是" : "❌ 否")")
        if let r = ArchiveEngine.modifyRefusal(url) { print("  拒改说明  : \(r)") }

        let before = ArchiveEngine.entries(in: url)
        print("  编辑前    : \(before.count) 条")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pea27-edit-\(UUID().uuidString).txt")
        try? "edit test payload".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let add = ArchiveEngine.addInto(url, items: [tmp], onLine: nil)
        if add.ok {
            let after = ArchiveEngine.entries(in: url)
            print("  添加      : ✅  条目 \(before.count) → \(after.count)  \(after.count == before.count + 1 ? "✅" : "❌")")
            let del = ArchiveEngine.deleteEntries(url, paths: [tmp.lastPathComponent], onLine: nil)
            let restored = ArchiveEngine.entries(in: url)
            print("  删除      : \(del.ok ? "✅" : "❌")  条目 \(after.count) → \(restored.count)  \(restored.count == before.count ? "✅ 已还原" : "❌")")
        } else {
            print("  添加      : ❌ status=\(add.status)（预期行为，若上方显示不可修改）")
            print("               \(add.output.split(separator: "\n").suffix(3).joined(separator: " / "))")
        }
        exit(0)
    }

    /// Headless mirror of the browsing path: parse the archive, show the root listing,
    /// then descend one folder. Same `children(of:archive:under:)` the UI uses.
    static func listArchive(_ path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        print("PeaZip 压缩包浏览自检")
        print("  归档      : \(url.lastPathComponent)")
        let exists = FileManager.default.fileExists(atPath: url.path)
        print("  存在      : \(exists ? "✅" : "❌")")
        // A path inside another app's container reports as missing even when it is right
        // there: the system denies the stat itself. Say so, instead of "file not found".
        guard exists else {
            print("  ❌ 无法访问：文件不存在，或所在位置没有访问权限")
            print("     若它位于微信 / QQ 等应用的文件夹，需要给 PeaZip 完全磁盘访问权限：")
            print("     系统设置 → 隐私与安全性 → 完全磁盘访问权限")
            exit(3)
        }
        let entries = ArchiveEngine.entries(in: url)
        print("  解析条目  : \(entries.count)")
        guard !entries.isEmpty else { print("❌ 没有解析出任何条目"); exit(1) }

        func dump(_ items: [FileItem], _ label: String) {
            let dirs = items.filter(\.isDirectory).count
            print("  \(label): \(items.count) 项（\(dirs) 个文件夹）")
            for it in items.prefix(10) {
                let mark = it.isDirectory ? "📁" : "📄"
                let date = it.modified == .distantPast ? "" : it.dateText
                print("    \(mark) \(it.name)   \(it.sizeText)   \(date)")
            }
            if items.count > 10 { print("    …另 \(items.count - 10) 项") }
        }

        let root = AppModel.children(of: entries, archive: url, under: "")

        // Protected location (another app's container): 7-Zip reports nothing rather than an
        // error, so an empty listing for a file with bytes in it means the system blocked us.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if entries.isEmpty && bytes > 4096 {
            print("  ⚠️ 读不到内容：文件有 \(bytes) 字节，但引擎返回 0 条 —— 位置受系统保护")
            print("     需要给 PeaZip 完全磁盘访问权限：系统设置 → 隐私与安全性 → 完全磁盘访问权限")
            exit(3)
        }

        var level = ""
        var depth = 0
        while depth < 4 {
            let items = depth == 0 ? root : AppModel.children(of: entries, archive: url, under: level)
            dump(items, depth == 0 ? "根目录" : "第 \(depth) 层「\(level)」")
            guard let d = items.first(where: { $0.isDirectory }), let inner = d.entryPath else {
                print("  （本层没有子文件夹，下钻结束）")
                break
            }
            level = inner
            depth += 1
        }
        // A synthetic URL must never look like a real archive to the actions.
        let bogus = root.contains { $0.fromArchive && $0.isArchive }
        print("  内部条目误判为压缩包: \(bogus ? "❌ 有" : "✅ 无")")
        exit(0)
    }

    /// Does the protected-folder fallback actually kick in? Runs the same decision the UI
    /// makes and extracts for real, so "解压不了" is reproducible without clicking.
    static func extractTest(_ path: String) -> Never {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        print("PeaZip 解压目标自检")
        print("  压缩包    : \(url.lastPathComponent)")
        print("  所在目录  : \(url.deletingLastPathComponent().path)")
        let (root, note) = AppModel.writableRoot(for: url)
        if let note {
            print("  可写判断  : 原位置不可写 → 改道 \(root.path)")
            print("  说明      : \(note)")
        } else {
            print("  可写判断  : 原位置可写，就地解压")
        }
        let dest = root.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + "-解压自检")
        try? FileManager.default.removeItem(at: dest)
        let r = ArchiveEngine.extract(url, to: dest, onLine: nil)
        let n = (try? FileManager.default.contentsOfDirectory(atPath: dest.path).count) ?? 0
        print("  解压结果  : \(r.ok ? "✅ 成功" : "❌ 失败") status=\(r.status)")
        print("  落在      : \(dest.path)（\(n) 项）")
        try? FileManager.default.removeItem(at: dest)
        exit(r.ok ? 0 : 1)
    }

    static func selftest() -> Never {
        print("PeaZip27 自检")
        print("  7z 引擎      : \(ArchiveEngine.sevenZip?.path ?? "❌ 未找到")")
        print("  引擎版本      : \(ArchiveEngine.version ?? "—")")
        print("  是否可用      : \(ArchiveEngine.isAvailable ? "✅" : "❌")")
        let home = FileManager.default.homeDirectoryForCurrentUser
        print("  主目录        : \(home.path)")
        let items = AppModel.scan(home, includeHidden: false, ascending: true)
        print("  目录条目数    : \(items.count)")
        for it in items.prefix(4) {
            print("    · \(it.name)  [\(it.kind)]  \(it.sizeText)")
        }
        print(items.isEmpty ? "❌ 目录扫描返回空" : "✅ 目录扫描正常")

        // Round-trip the actual archiver: make files, pack, test, unpack, compare.
        guard ArchiveEngine.isAvailable else {
            print("❌ 无 7z，跳过归档自检")
            exit(1)
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pea27-selftest-\(UUID().uuidString)")
        let src = tmp.appendingPathComponent("src")
        let out = tmp.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        var expected: [String: String] = [:]
        for i in 1...3 {
            let name = "文件\(i).txt"
            let body = "PeaZip27 round-trip payload \(i)\n" + String(repeating: "x", count: 100 * i)
            try? body.write(to: src.appendingPathComponent(name), atomically: true, encoding: .utf8)
            expected[name] = body
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        var failures: [String] = []
        for fmt in [ArchiveEngine.Format.sevenZ, .zip] {
            let arc = tmp.appendingPathComponent("test.\(fmt.ext)")
            let a = ArchiveEngine.add(sources: [src], to: arc, format: fmt, onLine: nil)
            print("  打包 \(fmt.title.padding(toLength: 8, withPad: " ", startingAt: 0)): \(a.ok ? "✅" : "❌ 退出码 \(a.status)")")
            if !a.ok { failures.append("pack \(fmt.title)"); continue }

            let t = ArchiveEngine.test(arc, onLine: nil)
            print("  测试 \(fmt.title.padding(toLength: 8, withPad: " ", startingAt: 0)): \(t.ok ? "✅" : "❌")")
            if !t.ok { failures.append("test \(fmt.title)") }

            let l = ArchiveEngine.list(arc)
            let listed = expected.keys.filter { l.output.contains($0) }.count
            print("  列表 \(fmt.title.padding(toLength: 8, withPad: " ", startingAt: 0)): \(listed)/\(expected.count) 个文件可见 \(listed == expected.count ? "✅" : "❌")")
            if listed != expected.count { failures.append("list \(fmt.title)") }

            let ex = ArchiveEngine.extract(arc, to: out, onLine: nil)
            if !ex.ok { print("  解压 \(fmt.title): ❌"); failures.append("extract \(fmt.title)"); continue }
            var matched = 0
            for (name, body) in expected {
                let candidates = [out.appendingPathComponent(name),
                                  out.appendingPathComponent("src").appendingPathComponent(name)]
                for c in candidates where (try? String(contentsOf: c, encoding: .utf8)) == body {
                    matched += 1
                    break
                }
            }
            print("  解压 \(fmt.title.padding(toLength: 8, withPad: " ", startingAt: 0)): \(matched)/\(expected.count) 个文件字节一致 \(matched == expected.count ? "✅" : "❌")")
            if matched != expected.count { failures.append("content \(fmt.title)") }
            try? FileManager.default.removeItem(at: out)
        }
        print(failures.isEmpty ? "✅ 归档引擎全程通过" : "❌ 失败项: \(failures.joined(separator: ", "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1120, height: 700)
        // Do not depend on AppKit's saved-window-state path to produce the launch window.
        // When that path restores nothing (stale state, or a changed WindowGroup id) the
        // app presents no window at all — and combined with
        // `applicationShouldTerminateAfterLastWindowClosed` that becomes an instant quit.
        .defaultLaunchBehavior(.presented)
        .commands {
            // macOS stores the Full Disk Access list in a SIP-protected database: an app
            // cannot add itself to it, it can only take the user straight to the pane.
            CommandGroup(replacing: .help) {
                Button("授予完全磁盘访问权限…") { AppModel.openFullDiskAccessSettings() }
            }
            // Replacing the default New-item group wipes out the standard "New Window"
            // entry, so provide our own — otherwise closing the window leaves no way to
            // bring it back from the menu.
            CommandGroup(replacing: .newItem) {
                Button("打开主窗口") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("归档") {
                // ⌘O works in both modes, so entering a folder never depends on the
                // double-click surviving SwiftUI's cell interaction handling.
                Button("打开") { model.openSelection() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("显示上次操作日志") { model.showLastLog() }
                Divider()
                // The menu has to follow the mode: while browsing inside an archive, the
                // filesystem commands would operate on synthetic paths that do not exist.
                if model.isBrowsingArchive {
                    Button("添加文件…") { model.addFilesToOpenArchive() }
                        .disabled(!model.canModifyOpenArchive)
                    Button("从压缩包删除…") { model.deleteSelectedFromOpenArchive() }
                        .disabled(model.selection.isEmpty || !model.canModifyOpenArchive)
                    Divider()
                    Button("解压选中项…") { model.extractFromOpenArchive(selectedOnly: true) }
                        .disabled(model.selection.isEmpty)
                        .keyboardShortcut("e", modifiers: [.command])
                    Button("全部解压…") { model.extractFromOpenArchive(selectedOnly: false) }
                    Divider()
                    Button("关闭压缩包") { model.exitArchive() }
                        .keyboardShortcut("w", modifiers: [.command])
                } else {
                    Button("添加到压缩包…") { model.beginAdd() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("解压到…") { model.beginExtract() }
                        .keyboardShortcut("e", modifiers: [.command])
                    Button("测试完整性") { model.beginTest() }
                        .keyboardShortcut("t", modifiers: [.command])
                    Divider()
                    Button("安全删除…") { model.beginSecureDelete() }
                        .keyboardShortcut(.delete, modifiers: [.command, .shift])
                }
            }
        }

        // Gives the app a real 偏好设置 window and the standard ⌘, menu item. Without a
        // Settings scene the app menu has no preferences entry at all, which is exactly
        // what made the old PeaZip's settings UI look "gone" rather than replaced.
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
