import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sidebarSel: URL?
    @State private var query = ""

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
        .searchable(text: $query, placement: .toolbar, prompt: "搜索")
        .onChange(of: sidebarSel) { _, new in if let u = new { model.go(to: u) } }
        .onChange(of: model.currentURL) { _, new in
            if sidebarSel?.path != new.path && !model.favorites.contains(where: { $0.url.path == new.path }) {
                sidebarSel = nil
            }
        }
        .sheet(item: $model.opSheet) { sheet in
            if sheet.title.hasPrefix("添加到压缩包") && !model.busy && model.logLines.isEmpty {
                AddArchiveSheet()
            } else {
                OperationLogSheet(sheet: sheet)
            }
        }
    }

    // MARK: - Toolbar (SF Symbols = vector, crisp at any scale)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack).help("后退")
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward).help("前进")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp).help("向上")
        }
        if model.isBrowsingArchive {
            // Archive browsing: file-management actions make no sense here (the paths are
            // inside the archive), so the toolbar becomes extract-oriented.
            ToolbarItemGroup {
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

    private var fileList: some View {
        Table(filtered, selection: $model.selection) {
            TableColumn("名称") { item in
                HStack(spacing: 7) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.tint)
                        .frame(width: 16)
                    Text(item.name).lineLimit(1)
                }
            }
            TableColumn("类型") { Text($0.kind).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
            TableColumn("大小") { Text($0.sizeText).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 60, ideal: 84)
            TableColumn("修改日期") { Text($0.dateText).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 110, ideal: 136)
        }
        .environment(\.defaultMinListRowHeight, 26)
        .contextMenu(forSelectionType: URL.self) { urls in
            if model.isBrowsingArchive {
                if !urls.isEmpty {
                    Button("解压选中项…") { model.extractFromOpenArchive(selectedOnly: true) }
                    Divider()
                }
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
                ForEach(Array(model.backStack.suffix(6).enumerated()), id: \.offset) { _, u in
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
            Text(model.statusText).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
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
