import SwiftUI
import AppKit
import CoreServices

/// UserDefaults keys + their defaults.
///
/// `register()` must run before anything reads a preference: `@AppStorage` falls back to
/// 0 / false / "" when a key has never been written, so an unregistered level would come
/// back as 0 (store-only) and an unregistered format as an empty string.
enum PrefKey {
    static let defaultFormat   = "pref.defaultFormat"
    static let compressionLevel = "pref.compressionLevel"
    static let excludeMacJunk  = "pref.excludeMacJunk"
    static let excludeHidden   = "pref.excludeHidden"
    static let excludeWindowsJunk = "pref.excludeWindowsJunk"
    static let excludeCustom   = "pref.excludeCustom"
    static let openAfterExtract = "pref.openAfterExtract"
    static let securePasses    = "pref.secureDeletePasses"
    static let showHidden      = "pref.showHiddenOnLaunch"

    static func register() {
        UserDefaults.standard.register(defaults: [
            defaultFormat: ArchiveEngine.Format.zip.rawValue,
            compressionLevel: 5,
            excludeMacJunk: true,
            excludeHidden: true,
            excludeWindowsJunk: false,
            excludeCustom: "",
            openAfterExtract: false,
            securePasses: 3,
            showHidden: false,
        ])
    }
}

/// Settings store: one place that reads the current values, so operations never have to
/// know about UserDefaults.
enum Prefs {
    static var defaultFormat: ArchiveEngine.Format {
        ArchiveEngine.Format(rawValue: UserDefaults.standard.string(forKey: PrefKey.defaultFormat) ?? "zip") ?? .zip
    }
    static var compressionLevel: Int { UserDefaults.standard.integer(forKey: PrefKey.compressionLevel) }
    static var excludeMacJunk: Bool { UserDefaults.standard.bool(forKey: PrefKey.excludeMacJunk) }
    static var excludeHidden: Bool { UserDefaults.standard.bool(forKey: PrefKey.excludeHidden) }
    static var excludeWindowsJunk: Bool { UserDefaults.standard.bool(forKey: PrefKey.excludeWindowsJunk) }
    static var excludeCustom: String { UserDefaults.standard.string(forKey: PrefKey.excludeCustom) ?? "" }
    static var openAfterExtract: Bool { UserDefaults.standard.bool(forKey: PrefKey.openAfterExtract) }
    static var securePasses: Int { max(1, UserDefaults.standard.integer(forKey: PrefKey.securePasses)) }
    static var showHidden: Bool { UserDefaults.standard.bool(forKey: PrefKey.showHidden) }

    /// The full `-xr!` pattern list handed to 7z. Order is irrelevant; duplicates are.
    static var exclusionPatterns: [String] {
        var out: [String] = []
        if excludeMacJunk { out += ArchiveEngine.macJunkPatterns }
        if excludeHidden { out.append(".*") }          // every dot-file, at any depth
        if excludeWindowsJunk { out += ArchiveEngine.windowsJunkPatterns }
        out += excludeCustom
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return out
    }

    /// Human-readable summary for the settings UI.
    static var exclusionSummary: String {
        let n = exclusionPatterns.count
        return n == 0 ? "当前不排除任何文件" : "当前共 \(n) 条排除规则"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(PrefKey.defaultFormat) private var defaultFormat = ArchiveEngine.Format.zip.rawValue
    @AppStorage(PrefKey.compressionLevel) private var level = 5
    @AppStorage(PrefKey.excludeMacJunk) private var excludeMacJunk = true
    @AppStorage(PrefKey.excludeHidden) private var excludeHidden = true
    @AppStorage(PrefKey.excludeWindowsJunk) private var excludeWindowsJunk = false
    @AppStorage(PrefKey.excludeCustom) private var excludeCustom = ""
    @AppStorage(PrefKey.securePasses) private var passes = 3
    @AppStorage(PrefKey.openAfterExtract) private var openAfterExtract = false
    @AppStorage(PrefKey.showHidden) private var showHidden = false

    @StateObject private var updater = EngineUpdater()
    @State private var note = ""

    var body: some View {
        TabView {
            compressTab.tabItem { Label("压缩", systemImage: "doc.zipper") }
            excludeTab.tabItem { Label("排除", systemImage: "line.3.horizontal.decrease.circle") }
            extractTab.tabItem { Label("解压", systemImage: "arrow.down.doc") }
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            integrationTab.tabItem { Label("系统集成", systemImage: "square.on.square") }
            engineTab.tabItem { Label("引擎", systemImage: "cpu") }
        }
        .frame(width: 560, height: 440)
    }

    // MARK: - Tabs

    private var compressTab: some View {
        Form {
            Picker("默认格式", selection: $defaultFormat) {
                ForEach(ArchiveEngine.Format.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("压缩级别")
                    Spacer()
                    Text(levelLabel).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(level) },
                                      set: { level = Int($0.rounded()) }),
                       in: 0...9, step: 1)
            }

            LabeledContent("排除规则") {
                Text(Prefs.exclusionSummary).foregroundStyle(.secondary)
            }
            Text("在「排除」标签页里配置。")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("安全删除覆写遍数") {
                Stepper("\(passes) 遍", value: $passes, in: 1...7)
            }
            Text("逐遍写入随机数据后再删除。机械盘 3 遍足够；固态盘受磨损均衡影响，多遍收益有限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 排除

    private var excludeTab: some View {
        Form {
            Section("预设") {
                Toggle("排除 macOS 系统文件", isOn: $excludeMacJunk)
                Text("""
                     .DS_Store、__MACOSX、._* 资源分叉、.AppleDouble、.Spotlight-V100、\
                     .Trashes、.fseventsd、.DocumentRevisions-V100、.TemporaryItems、\
                     Icon␍、.apdisk 等
                     """)
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("排除隐藏文件（以 . 开头）", isOn: $excludeHidden)
                Text("""
                     一条 .* 规则，排除任意层级下所有以点开头的文件与文件夹（如 .git、.env、\
                     .idea）。注意：它也会一并排除 .env、.gitignore、.npmrc 这类可能确实要交付的文件。
                     """)
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("排除 Windows 冗余文件", isOn: $excludeWindowsJunk)
                Text("Thumbs.db、ehthumbs.db、desktop.ini、$RECYCLE.BIN、System Volume Information、*.lnk")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("自定义规则（每行一条）") {
                TextEditor(text: $excludeCustom)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 76)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3)))
                Text("""
                     支持 7z 通配符：* 任意字符、? 单字符。示例：node_modules、*.log、\
                     build、*.tmp。规则按相对路径递归匹配。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(Prefs.exclusionSummary)
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var extractTab: some View {
        Form {
            Toggle("解压完成后在访达中显示", isOn: $openAfterExtract)
            Text("解压结束后自动在新窗口打开目标文件夹。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Toggle("显示隐藏文件", isOn: $showHidden)
            Text("以 . 开头的文件与文件夹。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var integrationTab: some View {
        Form {
            LabeledContent("右键「服务」菜单") {
                Button("打开系统服务设置") { openServiceSettings() }
            }
            Text("勾选「用 PeaZip …」四项后，在访达里选中文件右键 → 服务 即可直接压缩/解压。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            LabeledContent("默认打开程序") {
                Button("设为压缩包的默认打开程序") { claimDefaultHandlers() }
            }
            Text("把 zip / 7z / rar / tar 等交给本 app。随时可以在访达「显示简介 → 打开方式」里改回去。")
                .font(.caption).foregroundStyle(.secondary)

            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var engineTab: some View {
        Form {
            LabeledContent("7z 引擎") {
                Text(ArchiveEngine.version ?? "—").font(.caption)
            }
            LabeledContent("路径") {
                Text(ArchiveEngine.sevenZip?.path ?? "未找到")
                    .font(.caption).textSelection(.enabled)
            }
            LabeledContent("来源") {
                Text(updater.bundledFromRelease.map { "PeaZip \($0) 发布版" } ?? "未记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("支持的格式") {
                Text("打包：ZIP / 7z / TAR / GZIP / XZ / Zstandard；解包：7z 能识别的全部格式")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("引擎更新") {
                HStack(spacing: 8) {
                    Button("检查更新") { updater.refresh() }
                        .disabled(updater.state.isWorking)
                    Button("更新引擎") { updater.installLatest() }
                        .disabled(updater.state.isWorking || !updater.updateAvailable)
                    if updater.state.isWorking { ProgressView().controlSize(.small) }
                }
                if !updater.state.text.isEmpty {
                    Text(updater.state.text).font(.caption).foregroundStyle(stateColor)
                }
                Text("""
                     引擎取自 PeaZip 官方发布版里的 7-Zip（“z”版，含 brotli / zstd / zpaq 等\
                     编解码器），因此更新源是 PeaZip 而不是 7-zip.org —— 换成上游通用版会改变\
                     能解压的格式。更新只替换本 app 内置的那一份并重新签名，不影响系统里其它\
                     压缩软件。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var stateColor: Color {
        switch updater.state {
        case .failed: return .red
        case .done: return .green
        default: return .secondary
        }
    }

    // MARK: - Helpers

    private var levelLabel: String {
        switch level {
        case 0: return "0 · 仅存储（最快）"
        case 1...3: return "\(level) · 快速"
        case 4...6: return "\(level) · 均衡"
        case 7...8: return "\(level) · 高压缩"
        default: return "9 · 极限（最慢）"
        }
    }

    private func openServiceSettings() {
        // The services list lives inside the Keyboard shortcuts window, not the main
        // Keyboard pane — opening the pane alone lands the user one click short.
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
        note = "已打开系统设置 —— 左侧列表里选「服务」"
    }

    private func claimDefaultHandlers() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let types = ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
                     "public.tar-archive", "org.gnu.gnu-zip-archive", "public.bzip2-archive",
                     "public.xz-archive", "com.facebook.zstd-archive"]
        var ok = 0
        for t in types {
            let st = LSSetDefaultRoleHandlerForContentType(t as CFString, .all, id as CFString)
            if st == noErr { ok += 1 }
        }
        appLog.notice("claimDefaultHandlers: \(ok, privacy: .public)/\(types.count, privacy: .public)")
        note = ok == types.count ? "已设为默认打开程序（\(ok) 种格式）" : "部分成功（\(ok)/\(types.count)）"
    }
}
