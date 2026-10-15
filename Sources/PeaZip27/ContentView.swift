import SwiftUI
import UniformTypeIdentifiers

/// Surfaced to Finder when a drag-out extraction fails, so the drop is rejected instead
/// of silently producing nothing.
struct DragFailure: LocalizedError {
    var errorDescription: String? { "从压缩包中提取失败" }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarSel: URL?
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\FileItem.name)]
    @AppStorage("showImagePreview") private var showImagePreview = true

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(spacing: 0) {
                PathBar()
                Divider()
                fileList
                Divider()
                StatusBar()
            }
            .background(Color(nsColor: .controlBackgroundColor))
            // Window title = current folder. Gives the window an identity in Mission
            // Control / the window menu, and makes "did a Finder double-click actually
            // navigate?" checkable from outside the process.
            .navigationTitle(model.currentURL.lastPathComponent.isEmpty
                             ? "/" : model.currentURL.lastPathComponent)
            .navigationSubtitle(model.statusText)
        }
        .toolbar { toolbarContent }
        .inspector(isPresented: $showImagePreview) {
            ImagePreviewPane(item: previewItem, archive: model.openArchive,
                             selectionCount: model.selection.count)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
        .onChange(of: sidebarSel) { _, new in if let u = new { model.go(to: u) } }
        .onChange(of: model.currentURL) { _, new in
            if sidebarSel?.path != new.path && !model.favorites.contains(where: { $0.url.path == new.path }) {
                sidebarSel = nil
            }
            // A leftover search term made every freshly opened folder look empty, which
            // reads as "the app is broken" rather than "your filter is still on".
            query = ""
            model.selection.removeAll()
        }
        .onChange(of: model.openArchive) { _, _ in query = "" }
        // These live in the toolbar now, so they have to take effect immediately rather
        // than only at next launch.
        .onChange(of: model.showHidden) { _, _ in model.reload() }
        .onChange(of: model.ascending) { _, _ in model.reload() }
        .sheet(item: $model.opSheet) { sheet in
            if sheet.title.hasPrefix("添加到压缩包") && !model.busy && model.logLines.isEmpty {
                AddArchiveSheet()
            } else {
                OperationLogSheet(sheet: sheet)
            }
        }
        .background(ProgressPopup(active: model.busy && model.opSheet == nil))
    }

    // MARK: - Toolbar (SF Symbols = vector, crisp at any scale)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showImagePreview.toggle()
            } label: {
                Label("图片预览", systemImage: "sidebar.right")
                    .symbolVariant(showImagePreview ? .fill : .none)
            }
            .help(showImagePreview ? "收起图片预览" : "显示图片预览")
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).help("后退")
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).help("前进")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp).help("向上")
            // View options used to live only in Settings and needed a relaunch to take
            // effect, which made them look broken.
            Menu {
                Toggle("显示隐藏文件", isOn: $model.showHidden)
                Toggle("反向排列", isOn: $model.ascending)
                Divider()
                Button("刷新列表") { model.isBrowsingArchive ? model.loadArchiveEntries() : model.reload() }
            } label: {
                Image(systemName: "eye")
            }
            .menuIndicator(.hidden)
            .help("显示选项")
        }
        if model.isBrowsingArchive {
            // Archive browsing: file-management actions make no sense here (the paths are
            // inside the archive), so the toolbar becomes extract/edit-oriented.
            ToolbarItemGroup {
                Button { model.addFilesToOpenArchive() } label: {
                    Label("添加文件", systemImage: "plus.circle")
                }
                .disabled(!model.canModifyOpenArchive)
                .help(model.modifyHint ?? "把文件或文件夹添加进这个压缩包（也可直接拖进来）")

                Button(role: .destructive) { model.deleteSelectedFromOpenArchive() } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(model.selection.isEmpty || !model.canModifyOpenArchive)
                .help(model.modifyHint ?? "从压缩包中删除选中的内容")

                Button { model.extractFromOpenArchive(selectedOnly: true) } label: {
                    Label("解压选中", systemImage: "tray.and.arrow.up")
                }.disabled(model.selection.isEmpty).help("把选中的内容解压出来")

                Button { model.extractFromOpenArchive(selectedOnly: false) } label: {
                    Label("全部解压", systemImage: "square.and.arrow.down.on.square")
                }.help("把整个压缩包解压到旁边的同名文件夹")

                Button { model.exitArchive() } label: {
                    Label("关闭", systemImage: "xmark.circle")
                }.help("关闭压缩包，回到文件夹")
            }
        } else {
            ToolbarItemGroup {
                Button { model.beginAdd() } label: {
                    Label("添加", systemImage: "archivebox")
                }.help("把选中项添加到压缩包")

                Button { model.beginConvert() } label: {
                    Label("转换", systemImage: "arrow.triangle.2.circlepath")
                }.disabled(model.selectedArchives.isEmpty).help("把压缩包转换为其他格式")

                Button { model.beginExtract(toNewFolder: false) } label: {
                    Label("解压", systemImage: "tray.and.arrow.up")
                }.disabled(model.selectedArchives.isEmpty).help("解压到当前文件夹")

                Button { model.beginExtract(toNewFolder: true) } label: {
                    Label("解压到新文件夹", systemImage: "folder.badge.plus")
                }.disabled(model.selectedArchives.isEmpty)

                Button { model.beginTest() } label: {
                    Label("测试", systemImage: "checkmark.seal")
                }.disabled(model.selectedArchives.isEmpty).help("测试压缩包完整性")

                Button(role: .destructive) { model.beginSecureDelete() } label: {
                    Label("安全删除", systemImage: "trash.slash")
                }.disabled(model.selection.isEmpty).help("3 遍覆写后删除")
            }
        }
    }

    // MARK: - File list

    private var filtered: [FileItem] {
        guard !query.isEmpty else { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var previewItem: FileItem? {
        guard model.selection.count == 1, let url = model.selection.first else { return nil }
        return model.items.first { $0.url == url }
    }

    /// Clicking a column header re-orders. An explicit sort overrides the folders-first
    /// default, which is what a header click is understood to mean.
    private var displayed: [FileItem] {
        filtered.sorted(using: sortOrder)
    }

    private var fileList: some View {
        Table(displayed, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(model.selection.contains(item.url) ? Color.white : item.tint)
                        .frame(width: 16)
                    Text(item.name).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .overlay {
                    FileRowDragSurface(item: item, visibleItems: displayed, model: model)
                }
                .help(item.fromArchive ? "拖到桌面或访达即可解压；双击进入或打开" : "拖到访达即可拷贝")
            }
            TableColumn("类型", value: \.kind) { Text($0.kind).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
            TableColumn("大小", value: \.size) { Text($0.sizeText).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 84)
            TableColumn("修改日期", value: \.modified) { Text($0.dateText).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 110, ideal: 136)
        }
        .environment(\.defaultMinListRowHeight, 26)
        // Dropping files onto the window adds them into the open archive (the file
        // manager case is deliberately not handled: silently copying files around a
        // folder on a stray drop is not something a user asked for).
        .dropDestination(for: URL.self) { urls, _ in
            guard model.isBrowsingArchive, !urls.isEmpty else { return false }
            model.addItemsToOpenArchive(urls)
            return true
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if model.isBrowsingArchive {
                if !urls.isEmpty {
                    // A guaranteed way in, independent of double-click semantics.
                    Button("打开 / 进入") {
                        guard let u = urls.first,
                              let item = model.items.first(where: { $0.url == u }) else { return }
                        model.open(item)
                    }
                    Button("解压选中项…") { model.extractFromOpenArchive(selectedOnly: true) }
                    Button("从压缩包删除…", role: .destructive) {
                        model.deleteSelectedFromOpenArchive()
                    }
                    .disabled(!model.canModifyOpenArchive)
                    Divider()
                }
                Button("添加文件…") { model.addFilesToOpenArchive() }
                    .disabled(!model.canModifyOpenArchive)
                Button("全部解压…") { model.extractFromOpenArchive(selectedOnly: false) }
                Divider()
                Button("关闭压缩包") { model.exitArchive() }
            } else if !urls.isEmpty {
                Button("打开") {
                    guard let u = urls.first,
                          let item = model.items.first(where: { $0.url == u }) else { return }
                    model.open(item)
                }
                Divider()
                Button("解压到新文件夹") { model.beginExtract(toNewFolder: true) }
                    .disabled(model.selectedArchives.isEmpty)
                Button("测试完整性") { model.beginTest() }
                    .disabled(model.selectedArchives.isEmpty)
                Divider()
                Button("添加到压缩包…") { model.beginAdd() }
                Button("安全删除…", role: .destructive) { model.beginSecureDelete() }
            }
        } primaryAction: { urls in
            guard let u = urls.first, let item = model.items.first(where: { $0.url == u }) else { return }
            model.open(item)
        }
    }

}


// MARK: - Native Finder drag-out

/// A native event surface keeps name-cell dragging independent of SwiftUI's
/// drag recognizer, which consumes the Table's double-click action.
private struct FileRowDragSurface: NSViewRepresentable {
    let item: FileItem
    let visibleItems: [FileItem]
    let model: AppModel

    func makeNSView(context: Context) -> FileRowDragView { FileRowDragView() }
    func updateNSView(_ view: FileRowDragView, context: Context) {
        view.item = item
        view.visibleItems = visibleItems
        view.model = model
    }
}

private final class FileRowDragView: NSView, NSDraggingSource {
    var item: FileItem?
    var visibleItems: [FileItem] = []
    weak var model: AppModel?
    private var mouseStart: NSPoint?
    private var collapseOnClick = false
    // NSFilePromiseProvider's delegate is weak. Retain delegates for the session;
    // queued write operations also retain theirs until delivery completes.
    private var promises: [ArchiveDragPromise] = []

    override func mouseDown(with event: NSEvent) {
        guard let item, let model else { return }
        window?.makeFirstResponder(enclosingTable ?? self)
        mouseStart = event.locationInWindow
        collapseOnClick = false
        if event.modifierFlags.contains(.command) {
            if model.selection.contains(item.url) { model.selection.remove(item.url) }
            else { model.selection.insert(item.url) }
        } else if event.modifierFlags.contains(.shift),
                  let anchor = visibleItems.firstIndex(where: { model.selection.contains($0.url) }),
                  let end = visibleItems.firstIndex(where: { $0.url == item.url }) {
            model.selection.formUnion(visibleItems[min(anchor, end)...max(anchor, end)].map(\.url))
        } else if !model.selection.contains(item.url) {
            model.selection = [item.url]
        } else {
            collapseOnClick = true // keep a multiple selection until we know it isn't a drag
        }
        if event.clickCount == 2 {
            mouseStart = nil
            collapseOnClick = false
            model.open(item)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if collapseOnClick, let item { model?.selection = [item.url] }
        mouseStart = nil
        collapseOnClick = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseStart, let item, let model,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 else { return }
        mouseStart = nil
        collapseOnClick = false
        let selected = model.selection.contains(item.url)
            ? visibleItems.filter { model.selection.contains($0.url) } : [item]
        var draggingItems: [NSDraggingItem] = []
        promises = []
        for entry in selected {
            let writer: NSPasteboardWriting
            if entry.fromArchive {
                guard let archive = model.openArchive, let inner = entry.entryPath else { continue }
                let promise = ArchiveDragPromise(archive: archive, inner: inner, item: entry, model: model)
                promises.append(promise)
                writer = RetainedFilePromiseProvider(fileType: entry.isDirectory ? UTType.folder.identifier :
                    (UTType(filenameExtension: entry.url.pathExtension)?.identifier ?? UTType.data.identifier),
                    promise: promise)
            } else {
                writer = entry.url as NSURL
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: entry.name)
                ?? NSWorkspace.shared.icon(forFile: entry.url.path)
            draggingItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 26, height: 26), contents: image)
            draggingItems.append(draggingItem)
        }
        guard !draggingItems.isEmpty else { return }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // An archive entry is always copied; dragging never deletes its source.
        context == .outsideApplication ? .copy : []
    }

    private var enclosingTable: NSTableView? {
        var parent = superview
        while let view = parent {
            if let table = view as? NSTableView { return table }
            parent = view.superview
        }
        return nil
    }
}

/// Keep the delegate alive even if the source row disappears during delivery.
private final class RetainedFilePromiseProvider: NSFilePromiseProvider {
    private var promise: ArchiveDragPromise?
    override init() { super.init() }
    convenience init(fileType: String, promise: ArchiveDragPromise) {
        self.init()
        self.promise = promise
        self.fileType = fileType
        self.delegate = promise
    }
    required init?(coder: NSCoder) { fatalError("Not used for archived views") }
}

private final class ArchiveDragPromise: NSObject, NSFilePromiseProviderDelegate {
    let archive: URL
    let inner: String
    let item: FileItem
    weak var model: AppModel?
    // Serialize extraction jobs so progress and 7z processes don't compete.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.yww.pea27.drag-out"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(archive: URL, inner: String, item: FileItem, model: AppModel) {
        self.archive = archive
        self.inner = inner
        self.item = item
        self.model = model
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String { item.name }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo destination: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("peazip-drag-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: scratch)
            DispatchQueue.main.async { [weak model] in model?.reportProgress(-1, nil) }
        }
        // Snapshot the archive and path at mouse-down: navigating to another archive
        // during a drag must never change which file Finder receives.
        guard !inner.hasPrefix("/"), !inner.split(separator: "/").contains(".."),
              ArchiveEngine.isAvailable else {
            completionHandler(DragFailure())
            return
        }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            DispatchQueue.main.async { [weak model] in model?.reportProgress(0, self.item.name) }
            let result = ArchiveEngine.extractEntries(archive, paths: [inner], to: scratch, onLine: nil,
                onProgress: { [weak model] percent, name in
                    DispatchQueue.main.async { model?.reportProgress(percent, name) }
                })
            let source = scratch.appendingPathComponent(inner)
            guard result.ok, fm.fileExists(atPath: source.path) else {
                appLog.error("拖出失败 \(self.inner, privacy: .public): \(result.output.suffix(200), privacy: .public)")
                completionHandler(DragFailure())
                return
            }
            // Finder supplies the final file URL, including any collision resolution.
            // copyItem refuses to overwrite an existing destination.
            try fm.copyItem(at: source, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            Section("个人收藏") {
                ForEach(model.favorites) { row($0) }
            }
            Section("位置") {
                ForEach(model.volumes) { row($0) }
            }
            Section("历史") {
                // Identified by URL, not by array offset: an offset changes whenever the
                // list shifts, so SwiftUI rebuilds the rows and the selection is lost.
                ForEach(Array(model.backStack.suffix(6).reversed()), id: \.self) { u in
                    Label(u.lastPathComponent.isEmpty ? "/" : u.lastPathComponent, systemImage: "clock")
                        .lineLimit(1)
                        .tag(u)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ p: Place) -> some View {
        Label(p.name, systemImage: p.symbol).tag(p.url)
    }
}

// MARK: - Path bar

struct PathBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Read the crumbs ONCE per body evaluation. Reading `model.crumbs` again
        // inside the row closure (e.g. for `.count`) adds a dependency that keeps
        // invalidating this view.
        let items = model.crumbs
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, c in
                    if idx > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        if let inner = c.innerPath {
                            model.goToArchivePath(inner)
                        } else {
                            model.go(to: c.url)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if idx == 0 {
                                Image(systemName: "desktopcomputer").font(.system(size: 11))
                            } else if c.innerPath == "" {
                                Image(systemName: "doc.zipper")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                            } else if c.innerPath != nil {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                            }
                            Text(c.name)
                                .font(.system(size: 12.5,
                                              weight: idx == items.count - 1 ? .semibold : .regular))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(idx == items.count - 1
                                    ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            // Live progress while an operation runs. It lives in the status bar rather than a
            // modal panel: extraction should not block the window.
            if let p = model.progress {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int((p * 100).rounded()))%")
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(.secondary)
                if let d = model.progressDetail, !d.isEmpty {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                }
            }
            Text(model.statusText).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            // Say WHY this archive cannot be edited, rather than showing greyed-out
            // buttons with no explanation (RAR being the common case).
            if let hint = model.modifyHint {
                Label(hint, systemImage: "lock.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !ArchiveEngine.isAvailable {
                Label("未找到 7z 引擎", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            Image(systemName: "leaf.fill").font(.system(size: 11)).foregroundStyle(.green)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Operation log sheet

struct OperationLogSheet: View {
    @EnvironmentObject private var model: AppModel
    let sheet: OpSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if model.busy { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.title).font(.system(size: 13, weight: .semibold))
                    if !sheet.detail.isEmpty {
                        Text(sheet.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { i, l in
                            Text(l)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.logLines.count) { _, n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: 180)
            Divider()
            HStack {
                Spacer()
                Button(model.busy ? "运行中…" : "关闭") { model.opSheet = nil }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
            .padding(12)
        }
        .frame(width: 560, height: 380)
    }
}

// MARK: - Add form

struct AddArchiveSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var destination: URL?
    @State private var format: ArchiveEngine.Format = .zip

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加到压缩包").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("格式").foregroundStyle(.secondary)
                    Picker("", selection: $format) {
                        ForEach(ArchiveEngine.Format.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 200)
                }
                GridRow {
                    Text("文件名").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("archive", text: $model.addArchiveName).frame(width: 158)
                        Text(".\(format.ext)").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("位置").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text((destination ?? model.currentURL).path)
                            .lineLimit(1).truncationMode(.middle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 250, alignment: .leading)
                        Button("更改…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = false; p.canChooseDirectories = true
                            p.directoryURL = model.currentURL
                            if p.runModal() == .OK { destination = p.url }
                        }
                    }
                }
            }
            Text("共 \(model.selectedItems.isEmpty ? 1 : model.selectedItems.count) 个项目")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.opSheet = nil }
                Button("创建") {
                    let f = format
                    model.commitAdd(format: f, name: model.addArchiveName, destination: destination)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 470)
        .onAppear { if model.addArchiveName.isEmpty { model.addArchiveName = "archive" } }
    }
}


// MARK: - Operation progress

/// Shows an operation's progress as a popup instead of only in the corner status bar.
///
/// Held back ~0.7 s on purpose: nearly every extraction finishes in a blink, and a sheet
/// flashing on each quick one is worse than the quiet status line it replaces. A 500 MB
/// folder, on the other hand, deserves to be impossible to miss.
private struct ProgressPopup: View {
    let active: Bool
    @State private var show = false

    var body: some View {
        Color.clear
            .sheet(isPresented: $show) { ProgressSheet() }
            .task(id: active) {
                guard active else { show = false; return }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if !Task.isCancelled { show = true }
            }
    }
}

private struct ProgressSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(model.currentOp.map { "正在\($0)…" } ?? "正在处理…")
                    .font(.system(size: 13, weight: .semibold))
            }
            if let p = model.progress {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 340)
                HStack(spacing: 8) {
                    Text("\(Int((p * 100).rounded()))%").monospacedDigit()
                    if let d = model.progressDetail, !d.isEmpty {
                        Text(d).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 11.5))
                .frame(width: 340, alignment: .leading)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 340)
                Text("正在准备…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Text("完成后自动关闭。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(22)
        .frame(width: 384)
    }
}
