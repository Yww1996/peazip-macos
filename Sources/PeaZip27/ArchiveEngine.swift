import Foundation

/// Wraps the archiver back-end. PeaZip already ships a full 7-Zip build inside its
/// bundle, so this front-end drives that rather than reimplementing archive formats
/// (which is the part that would take years).
///
/// That engine is now **copied into our own bundle** at `Contents/Resources/bin`, which
/// is what makes this app standalone: it no longer needs `/Applications/PeaZip.app` to
/// exist, so the original can be replaced or deleted without breaking archiving.
enum ArchiveEngine {

    /// Bundled engine first, then an external PeaZip install, then Homebrew, then PATH.
    /// Resolved once: the status bar asks for this during view body evaluation and
    /// repeated `isExecutableFile` calls there are wasted syscalls on the main thread.
    private static let resolvedSevenZip: URL? = {
        var fixed: [String] = []
        if let res = Bundle.main.resourceURL {
            fixed.append(res.appendingPathComponent("bin/7z/7z").path)
        }
        fixed += [
            // Our own installed layout first: a bare/binary build (or a copy run outside
            // its bundle) still finds the engine the installed app carries. Without this
            // the fallback list only knew the ORIGINAL PeaZip's layout, so the engine
            // looked missing even on a machine where the app was installed.
            "/Applications/PeaZip.app/Contents/Resources/bin/7z/7z",
            // original PeaZip / upstream layouts
            "/Applications/PeaZip.app/Contents/MacOS/bin/7z/7z",
            "/Applications/peazip.app/Contents/MacOS/bin/7z/7z",
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7z",
            "/usr/bin/7z",
        ]
        for p in fixed where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in env.split(separator: ":") {
            let p = "\(dir)/7z"
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }()

    static var sevenZip: URL? { resolvedSevenZip }

    static var isAvailable: Bool { sevenZip != nil }

    /// `7z` version banner, resolved once (the Settings window shows it).
    ///
    /// 7z prints `7-Zip (z) 26.02 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : ...` —
    /// a long English tail that looks out of place in a Chinese UI, so keep just the
    /// product, version and architecture.
    static let version: String? = {
        guard let z = sevenZip else { return nil }
        let first = run(z, ["i"]).output.split(separator: "\n").first.map(String.init) ?? ""
        guard !first.isEmpty else { return nil }
        var s = first.replacingOccurrences(of: "7-Zip (z) ", with: "7-Zip ")
        if let cut = s.range(of: " : ") { s = String(s[..<cut.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }()

    struct Result { var output: String; var status: Int32; var ok: Bool { status == 0 } }

    /// Runs a tool, streaming stdout+stderr line by line so the UI can show progress.
    ///
    /// `onProgress` reports 7-Zip's own percentage. Those updates are separated by a
    /// CARRIAGE RETURN, not a newline, so a newline-only splitter swallows every one of them
    /// and progress appears to never arrive — the percent is parsed from the \r fragments.
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String],
                    onLine: ((String) -> Void)? = nil,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        let p = Process()
        p.executableURL = tool
        p.arguments = arguments
        // make sure child tools are found by our own sub-processes
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        var collected = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            lock.lock(); collected += s; lock.unlock()
            if let (pct, detail) = progressInChunk(s) { onProgress?(pct, detail) }
            for fragment in s.split(omittingEmptySubsequences: true,
                                    whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let text = String(fragment)
                // Progress fragments stay out of the log the sheet shows on failure.
                if parseProgress(text) == nil { onLine?(text) }
            }
        }

        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(output: "无法启动 \(tool.path)：\(error.localizedDescription)", status: -1)
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        // drain anything left in the pipe
        if let rest = try? pipe.fileHandleForReading.readToEnd(),
           let s = String(data: rest, encoding: .utf8) {
            lock.lock(); collected += s; lock.unlock()
        }
        lock.lock(); let out = collected; lock.unlock()
        return Result(output: out, status: p.terminationStatus)
    }

    /// Byte-weighted progress, derived from 7-Zip's per-file lines.
    ///
    /// 7-Zip suppresses its own percentage when stdout is a pipe rather than a terminal — a
    /// 400 MB extraction still reported a bare "0%", so -bsp1 is useless here. With -bb1 it
    /// does name every file as it goes, and the uncompressed sizes are already parsed out of
    /// the archive, so the percentage is computed locally.
    ///
    /// Known limit: an archive holding ONE huge file therefore moves in one step, since
    /// there is no per-file feedback inside it. Everything else scales by real bytes.
    private static func progressTracker(entries: [Entry], selecting: [String]?,
                                        onProgress: ((Int, String?) -> Void)?) -> (String) -> Void {
        let files: [Entry]
        if let sels = selecting {
            files = entries.filter { e in
                !e.isDirectory && sels.contains { e.path == $0 || e.path.hasPrefix($0 + "/") }
            }
        } else {
            files = entries.filter { !$0.isDirectory }
        }
        var sizes: [String: Int64] = [:]
        for e in files { sizes[e.path] = e.size }
        let total = sizes.values.reduce(Int64(0), +)
        var done: Int64 = 0
        var lastPct = -1
        return { line in
            guard total > 0, let name = processedName(line), let sz = sizes[name] else { return }
            done += sz
            let pct = min(99, Int((Double(done) / Double(total) * 100).rounded()))
            guard pct != lastPct else { return }
            lastPct = pct
            onProgress?(pct, name)
        }
    }

    /// "- path/to/name" — the line 7-Zip prints per file under -bb1.
    static func processedName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") || t.hasPrefix("+ ") else { return nil }
        let name = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The percentage out of a raw stdout chunk.
    ///
    /// 7-Zip rewrites its progress with BACKSPACES, not \r or \n: a whole update sequence
    /// arrives inside one chunk looking like "  0%\b\b\b\b 45%\b\b\b\b 91%\b\b\b\b".
    /// Taking the first match pins the bar at 0% for the entire operation — take the last.
    static func progressInChunk(_ chunk: String) -> (Int, String?)? {
        guard chunk.contains("%") else { return nil }
        // erase sequences become separators, so the item name after the last percent is clean
        let cleaned = chunk.replacingOccurrences(of: "\u{08}", with: " ")
        let matches = pctRegex.matches(in: cleaned,
                                       range: NSRange(cleaned.startIndex..., in: cleaned))
        guard let m = matches.last,
              let r = Range(m.range(at: 1), in: cleaned),
              let pct = Int(cleaned[r]), (0...100).contains(pct) else { return nil }
        let after = cleaned[r.upperBound...].dropFirst()          // past the "%"
        let head = after.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = head.split(separator: " ", omittingEmptySubsequences: true)
        let name = parts.last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (pct, (name?.isEmpty ?? true) ? nil : name)
    }

    private static let pctRegex = try! NSRegularExpression(pattern: "([0-9]{1,3})%")

    /// " 45% 12 - some/file.txt" → (45, "some/file.txt").
    /// Only fragments that *begin* with the percentage count, so a compression ratio or a
    /// filename containing "%" is not mistaken for progress.
    static func parseProgress(_ s: String) -> (Int, String?)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let pctIdx = t.firstIndex(of: "%") else { return nil }
        let head = String(t[t.startIndex..<pctIdx])
        guard !head.isEmpty, head.count <= 3,
              let pct = Int(head), (0...100).contains(pct) else { return nil }
        let rest = String(t[t.index(after: pctIdx)...]).trimmingCharacters(in: .whitespaces)
        // "12 - name" / "12 + name" / "12" → keep the name only
        guard !rest.isEmpty else { return (pct, nil) }
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count == 1 { return (pct, nil) }
        return (pct, String(parts[parts.count - 1]))
    }

    // MARK: - Operations

    enum Format: String, CaseIterable, Identifiable {
        case zip, sevenZ = "7z", tar, gz, xz, zstd
        var id: String { rawValue }
        var title: String {
            switch self {
            case .zip: return "ZIP"
            case .sevenZ: return "7Z"
            case .tar: return "TAR"
            case .gz: return "GZIP"
            case .xz: return "XZ"
            case .zstd: return "Zstandard"
            }
        }
        var ext: String { self == .sevenZ ? "7z" : rawValue }
    }

    /// Files macOS scatters around that are pure noise in an archive. Verified against
    /// this 7-Zip build: `-xr!<pattern>` applies recursively and several may be combined.
    static let macJunkPatterns = [
        ".DS_Store", "__MACOSX", "._*", ".AppleDouble", ".LSOverride",
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".DocumentRevisions-V100",
        ".TemporaryItems", ".PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware",
        ".com.apple.timemachine.donotpresent", ".apdisk", ".Trash",
        "Icon\r", ".VolumeIcon.icns",
    ]

    /// Windows/Office leftovers that accumulate in folders shared across platforms.
    static let windowsJunkPatterns = [
        "Thumbs.db", "ehthumbs.db", "desktop.ini", "$RECYCLE.BIN",
        "System Volume Information", "*.lnk",
    ]

    /// `7z a -t<fmt> -mx<level> [-xr!<pattern>…] <archive> <sources…>`
    ///
    /// Exclusions matter in practice: packing a macOS folder otherwise drags in
    /// `.DS_Store`, `__MACOSX` and `._*` resource forks, which are pure noise to anyone
    /// opening the archive on another platform.
    static func add(sources: [URL], to archive: URL, format: Format,
                    level: Int? = nil, exclusions: [String] = [],
                    onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        var args = ["a", "-t\(format.rawValue)", "-bsp1"]
        if let level { args.append("-mx\(max(0, min(9, level)))") }
        for p in exclusions where !p.isEmpty { args.append("-xr!\(p)") }
        args.append(archive.path)
        args.append(contentsOf: sources.map(\.path))
        appLog.notice("7z add t=\(format.rawValue, privacy: .public) mx=\(level.map(String.init) ?? "def", privacy: .public) 排除=\(exclusions.count, privacy: .public) 条 → \(archive.lastPathComponent, privacy: .public)")
        return run(z, args, onLine: onLine, onProgress: onProgress)
    }

    /// `7z x <archive> -o<dir> -y`
    static func extract(_ archive: URL, to dir: URL,
                        onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // -bb1, not -bsp1: the engine's own percentage never survives a pipe.
        let track = progressTracker(entries: entries(in: archive), selecting: nil, onProgress: onProgress)
        return run(z, ["x", archive.path, "-o\(dir.path)", "-y", "-bb1"],
                   onLine: { l in onLine?(l); track(l) }, onProgress: nil)
    }

    /// `7z t <archive>`
    static func test(_ archive: URL, onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        return run(z, ["t", archive.path, "-bsp1"], onLine: onLine, onProgress: onProgress)
    }

    /// `7z l` — used to show what is inside without extracting.
    static func list(_ archive: URL) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        return run(z, ["l", archive.path])
    }

    // MARK: - Browsing inside an archive

    struct Entry {
        let path: String        // full path inside the archive, e.g. "项目/src/main.txt"
        let isDirectory: Bool
        let size: Int64
        let packed: Int64
        let modified: Date?
    }

    /// `7z l -slt` — one record per entry as `Key = Value` lines, blank line between
    /// records. The first record describes the archive itself, so it is skipped (it is
    /// the only one carrying a `Type` key and a Path equal to the archive).
    static func entries(in archive: URL) -> [Entry] {
        guard let z = sevenZip else { return [] }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var out: [Entry] = []
        for block in run(z, ["l", "-slt", archive.path]).output
            .components(separatedBy: "\n\n") {
            var dict: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                dict[k] = v
            }
            guard let path = dict["Path"], !path.isEmpty else { continue }
            if dict["Type"] != nil { continue }                  // archive summary block
            if path == archive.path { continue }
            let attrs = dict["Attributes"] ?? ""
            let isDir = dict["Folder"] == "+" || attrs.hasPrefix("D")
            // 7z writes "2026-09-16 12:17:56.5280097" — fractional seconds included, and
            // the fraction is absent on some builds — so take the fixed-width prefix
            // rather than a pattern that only matches one of the two.
            let stamp = dict["Modified"].map { String($0.prefix(19)) }
            out.append(Entry(path: path,
                             isDirectory: isDir,
                             size: Int64(dict["Size"] ?? "0") ?? 0,
                             packed: Int64(dict["Packed Size"] ?? "0") ?? 0,
                             modified: stamp.flatMap { fmt.date(from: $0) }))
        }
        appLog.notice("archive list \(archive.lastPathComponent, privacy: .public): \(out.count, privacy: .public) 条")
        return out
    }

    /// `7z x <archive> -o<dir> [-y] [<inner paths…>]`
    /// Empty `paths` extracts everything. Paths must be paths *inside* the archive.
    static func extractEntries(_ archive: URL, paths: [String], to dir: URL,
                               onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var args = ["x", archive.path, "-o\(dir.path)", "-y", "-bb1"]
        args.append(contentsOf: paths)
        let track = progressTracker(entries: entries(in: archive), selecting: paths, onProgress: onProgress)
        return run(z, args, onLine: { l in onLine?(l); track(l) }, onProgress: nil)
    }

    // MARK: - Editing an archive in place

    /// Formats 7-Zip can WRITE. Everything else is read-only here:
    /// RAR is proprietary (7-Zip extracts it but cannot update it), and ISO/DMG-style
    /// images are not filesystem-editable by 7z either. gz/xz/bz2/zst are single-stream
    /// containers — "adding a file" would silently replace the whole archive, so they are
    /// deliberately excluded from in-place editing.
    static let writableFormats: Set<String> = ["zip", "7z", "tar"]

    static func canModify(_ archive: URL) -> Bool {
        writableFormats.contains(archive.pathExtension.lowercased())
    }

    /// Human-readable reason an archive cannot be edited, for the UI to show.
    static func modifyRefusal(_ archive: URL) -> String? {
        let e = archive.pathExtension.lowercased()
        if canModify(archive) { return nil }
        switch e {
        case "rar":
            return "RAR 是专有格式，7-Zip 只能读取、无法写入或删除。要编辑请先转为 ZIP 或 7Z。"
        case "gz", "xz", "bz2", "zst", "zstd", "lzma":
            return "\(e.uppercased()) 是单文件压缩流，不支持增删条目。要编辑请先转为 ZIP 或 7Z。"
        case "iso", "cab":
            return "\(e.uppercased()) 属镜像/只读格式，7-Zip 无法就地修改。"
        default:
            return "该格式不支持就地增删（仅支持 ZIP / 7Z / TAR）。"
        }
    }

    /// `7z a <archive> <items…>` — add files into an existing archive.
    /// 7-Zip infers the container format from the archive's extension.
    static func addInto(_ archive: URL, items: [URL],
                        onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        guard canModify(archive) else {
            return Result(output: modifyRefusal(archive) ?? "该格式不支持修改", status: 1)
        }
        var args = ["a", "-bsp1", archive.path]
        args.append(contentsOf: items.map(\.path))
        appLog.notice("7z add-into \(archive.lastPathComponent, privacy: .public): \(items.count, privacy: .public) 项")
        return run(z, args, onLine: onLine, onProgress: onProgress)
    }

    /// `7z d <archive> <inner paths…>` — delete entries from an archive.
    static func deleteEntries(_ archive: URL, paths: [String],
                              onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        guard let z = sevenZip else { return Result(output: "找不到 7z 引擎", status: -1) }
        guard canModify(archive) else {
            return Result(output: modifyRefusal(archive) ?? "该格式不支持修改", status: 1)
        }
        guard !paths.isEmpty else { return Result(output: "没有要删除的条目", status: 1) }
        var args = ["d", "-bsp1", archive.path]
        args.append(contentsOf: paths)
        appLog.notice("7z delete \(archive.lastPathComponent, privacy: .public): \(paths.count, privacy: .public) 条")
        return run(z, args, onLine: onLine, onProgress: onProgress)
    }

    /// Overwrite-then-unlink: 7z has no shred, and APFS has no /dev/random trick that
    /// is cheaper. Three passes is what the original "secure delete" promised.
    static func secureDelete(_ url: URL, passes: Int = 3,
                             onLine: ((String) -> Void)?,
                    onProgress: ((Int, String?) -> Void)? = nil) -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return Result(output: "跳过（不是普通文件）：\(url.lastPathComponent)", status: 1)
        }
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 0,
              let fh = try? FileHandle(forWritingTo: url) else {
            return Result(output: "无法写入：\(url.lastPathComponent)", status: 1)
        }
        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        for pass in 1...passes {
            fh.seek(toFileOffset: 0)
            var written = 0
            while written < size {
                for i in 0..<chunk.count { chunk[i] = UInt8.random(in: 0...255) }
                let n = min(chunk.count, size - written)
                fh.write(Data(chunk[0..<n]))
                written += n
            }
            fh.synchronizeFile()
            onLine?("覆写第 \(pass)/\(passes) 遍完成 · \(url.lastPathComponent)")
        }
        try? fh.close()
        do {
            try fm.removeItem(at: url)
            return Result(output: "已安全删除：\(url.lastPathComponent)", status: 0)
        } catch {
            return Result(output: "删除失败：\(error.localizedDescription)", status: 1)
        }
    }
}
