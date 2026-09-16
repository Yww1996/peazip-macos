import Foundation
import AppKit
import os

/// Updates the bundled 7z engine from PeaZip's own release.
///
/// Why PeaZip and not 7-zip.org: the bundled engine is a copy of PeaZip's `bin/`
/// directory — the "7-Zip (z)" build plus brotli/zstd/zpaq helpers. 7-zip.org ships a
/// plain upstream build with a different feature set, so swapping it in would silently
/// change which formats the app can open.
///
/// Version bookkeeping gotcha: the PeaZip release tag (11.2.0) and the 7-Zip version
/// inside it (26.02) are unrelated, so `latest release != recorded release` is the only
/// reliable "an update exists" test. The recorded release is stored next to the engine.
/// Not `@MainActor` at the type level: the install path shells out to hdiutil/ditto/
/// codesign, and those block. Only the two methods that touch published UI state are
/// main-actor bound, so the blocking work can be pushed off the main thread.
final class EngineUpdater: ObservableObject {

    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .working(let s), .done(let s), .failed(let s): return s
            }
        }
        var isWorking: Bool { if case .working = self { return true }; return false }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latestRelease: String?
    @Published private(set) var updateAvailable = false

    /// 7-Zip version of the engine currently in the bundle, e.g. "26.02".
    let installedEngineVersion: String? = EngineUpdater.parseEngineVersion(ArchiveEngine.version)
    /// PeaZip release the bundled engine was taken from, e.g. "11.2.0".
    let bundledFromRelease: String? = EngineUpdater.recordedRelease()

    private static let api = URL(string: "https://api.github.com/repos/peazip/PeaZip/releases/latest")!

    // MARK: - Version bookkeeping

    /// Grab the dotted version out of either banner form:
    /// raw `7-Zip (z) 26.02 (arm64) : Copyright …` or cleaned `7-Zip 26.02 (arm64)`.
    ///
    /// Positional parsing is wrong here: the raw banner has "(z)" between the product and
    /// the version, so "the second token" yields "(z)" — which is exactly what the first
    /// real update reported as the new engine version.
    static func parseEngineVersion(_ banner: String?) -> String? {
        guard let banner,
              let r = banner.range(of: #"\d+(\.\d+)+"#, options: .regularExpression)
        else { return nil }
        return String(banner[r])
    }

    /// Raw `7z i` banner, straight from the engine (uncleaned).
    static func rawBanner(of engine: URL) -> String? {
        guard let out = try? run(engine.path, ["i"]).output else { return nil }
        return out.split(separator: "\n").first.map(String.init)
    }

    /// Marker written next to the engine when it was vendored. Absent for an engine that
    /// predates this feature, which we treat as "unknown" rather than "up to date".
    static func recordedRelease() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("bin/.peazip-release")
        return (try? String(contentsOf: p, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    static func writeRecordedRelease(_ tag: String) {
        guard let res = Bundle.main.resourceURL else { return }
        try? tag.write(to: res.appendingPathComponent("bin/.peazip-release"),
                       atomically: true, encoding: .utf8)
    }

    // MARK: - Queries

    struct Release { let tag: String; let dmg: URL }

    @MainActor
    func refresh() {
        state = .working("正在检查 PeaZip 最新版本…")
        Task {
            do {
                let r = try await Self.fetchLatest()
                latestRelease = r.tag
                if let bundled = bundledFromRelease {
                    updateAvailable = r.tag != bundled
                    state = .done(updateAvailable
                        ? "有新版本：PeaZip \(r.tag)（当前引擎来自 \(bundled)）"
                        : "已是最新（PeaZip \(r.tag)）")
                } else {
                    updateAvailable = true
                    state = .done("有可用的引擎来源：PeaZip \(r.tag)（当前引擎未记录来源）")
                }
            } catch {
                state = .failed("检查失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func installLatest() {
        state = .working("准备下载…")
        Task {
            do {
                let r = try await Self.fetchLatest()
                let dmg = try await Self.download(r.dmg) { msg in
                    Task { @MainActor in self.state = .working(msg) }
                }
                defer { try? FileManager.default.removeItem(at: dmg) }
                // Mounting, copying and re-signing block for seconds — keep them off the
                // main thread so the Settings window stays responsive.
                let newVersion = try await Task.detached(priority: .userInitiated) {
                    try await Self.install(dmg: dmg, tag: r.tag) { msg in
                        Task { @MainActor in self.state = .working(msg) }
                    }
                }.value
                state = .done("已更新到 7-Zip \(newVersion)（PeaZip \(r.tag)）—— 重启 app 后完全生效")
                updateAvailable = false
            } catch {
                state = .failed("更新失败：\(error.localizedDescription)")
            }
        }
    }

    /// Headless entry point (`--engine-check`, `--engine-update`): the same code the
    /// Settings buttons use, minus the UI, so the whole path is verifiable without
    /// clicking. Runs entirely off the main actor — blocking the main thread on a
    /// semaphore while awaiting a main-actor task would deadlock.
    static func headless(forceInstall: Bool) -> Never {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var lines: [String] = []
        func log(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }

        print("PeaZip 引擎自检")
        log("内置 7z      : \(ArchiveEngine.version ?? "?")")
        log("引擎来源记录 : \(recordedRelease() ?? "（未记录）")")
        // Regression guard: the install path parses the RAW banner while the UI shows the
        // cleaned one. Both must yield the same version, or an update reports nonsense.
        if let z = ArchiveEngine.sevenZip {
            let raw = parseEngineVersion(rawBanner(of: z)) ?? "?"
            let clean = parseEngineVersion(ArchiveEngine.version) ?? "?"
            log("版本解析自检 : 原始→\(raw)  已清理→\(clean)  \(raw == clean ? "✅" : "❌ 不一致")")
        }

        Task.detached {
            do {
                let r = try await fetchLatest()
                log("最新 PeaZip  : \(r.tag)")
                log("macOS 包     : \(r.dmg.lastPathComponent)")
                let need = forceInstall || recordedRelease() != r.tag
                log("判断         : \(need ? (forceInstall ? "强制更新" : "需要更新") : "已是最新")")
                if need {
                    let dmg = try await download(r.dmg, progress: log)
                    defer { try? FileManager.default.removeItem(at: dmg) }
                    let v = try await install(dmg: dmg, tag: r.tag, progress: log)
                    log("结果         : ✅ 已更新到 7-Zip \(v)")
                } else {
                    log("结果         : ✅ 无需更新")
                }
            } catch {
                log("结果         : ❌ \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        lines.forEach { print("  " + $0) }
        if let res = Bundle.main.resourceURL {
            let p = res.appendingPathComponent("bin/7z/7z")
            let ok = (try? run(p.path, ["i"]))?.status == 0
            print("  更新后引擎可执行: \(ok ? "✅" : "❌")")
        }
        exit(0)
    }

    // MARK: - GitHub

    private static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err("GitHub 返回 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            throw Err("无法解析 GitHub 响应")
        }
        #if arch(arm64)
        let want = "aarch64"
        #else
        let want = "x86_64"
        #endif
        guard let a = assets.first(where: {
            let n = ($0["name"] as? String ?? "").uppercased()
            return n.contains("DARWIN") && n.contains(want.uppercased()) && n.hasSuffix(".DMG")
        }), let s = a["browser_download_url"] as? String, let u = URL(string: s) else {
            throw Err("发布版里没有 \(want) 的 macOS 包")
        }
        appLog.notice("engine check: latest=\(tag, privacy: .public)")
        return Release(tag: tag, dmg: u)
    }

    // MARK: - Download

    private static func download(_ url: URL,
                                 progress: @escaping (String) -> Void) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("peazip-engine-\(UUID().uuidString).dmg")
        progress("正在下载 \(url.lastPathComponent)…")
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err("下载失败，HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        appLog.notice("engine download: \(size, privacy: .public) bytes")
        progress("下载完成（\(size / 1024 / 1024) MB），正在校验…")
        return dest
    }

    // MARK: - Install

    /// Extract, verify, then swap. The old engine is only removed after the new one has
    /// been proven to run, so a failed update leaves a working app rather than a shell.
    private static func install(dmg: URL, tag: String,
                                progress: @escaping (String) -> Void) async throws -> String {
        guard let res = Bundle.main.resourceURL else { throw Err("找不到 bundle 资源目录") }
        let binDir = res.appendingPathComponent("bin")
        let mnt = FileManager.default.temporaryDirectory
            .appendingPathComponent("peazip-mnt-\(UUID().uuidString)")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("peazip-bin-\(UUID().uuidString)")
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mnt.path, "-quiet"])
            try? FileManager.default.removeItem(at: mnt)
            try? FileManager.default.removeItem(at: staging)
        }

        progress("正在挂载镜像…")
        try FileManager.default.createDirectory(at: mnt, withIntermediateDirectories: true)
        _ = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-quiet",
                                         "-mountpoint", mnt.path])
        let srcBin = mnt.appendingPathComponent("peazip.app/Contents/MacOS/bin")
        guard FileManager.default.fileExists(atPath: srcBin.appendingPathComponent("7z/7z").path) else {
            throw Err("镜像里没有找到引擎（peazip.app/Contents/MacOS/bin/7z/7z）")
        }

        progress("正在校验新引擎…")
        let src7z = srcBin.appendingPathComponent("7z/7z")
        let srcOut = try run(src7z.path, ["i"])
        guard srcOut.status == 0 else { throw Err("新引擎无法运行") }
        let newVersion = parseEngineVersion(
            srcOut.output.split(separator: "\n").first.map(String.init)) ?? "?"
        appLog.notice("engine candidate: \(newVersion, privacy: .public)")

        // stage next to the bundle so all verification happens before anything is replaced
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", [srcBin.path, staging.path])
        let staged7z = staging.appendingPathComponent("7z/7z")
        guard try run(staged7z.path, ["i"]).status == 0 else { throw Err("暂存后的引擎无法运行") }

        progress("正在替换内置引擎…")
        let old = res.appendingPathComponent("bin.old-\(UUID().uuidString)")
        var movedOld = false
        do {
            if FileManager.default.fileExists(atPath: binDir.path) {
                try FileManager.default.moveItem(at: binDir, to: old)
                movedOld = true
            }
            try FileManager.default.moveItem(at: staging, to: binDir)
        } catch {
            if movedOld { try? FileManager.default.moveItem(at: old, to: binDir) }
            throw Err("替换失败：\(error.localizedDescription)")
        }

        let inPlace = binDir.appendingPathComponent("7z/7z")
        guard try run(inPlace.path, ["i"]).status == 0 else {
            // put the working engine back before surfacing the error
            try? FileManager.default.removeItem(at: binDir)
            if movedOld { try? FileManager.default.moveItem(at: old, to: binDir) }
            throw Err("替换后引擎无法运行，已回滚")
        }
        writeRecordedRelease(tag)
        try? FileManager.default.removeItem(at: old)

        // Swapping files invalidates the code signature; re-sign so the bundle stays valid.
        progress("正在重新签名…")
        if let app = Bundle.main.bundleURL as URL? {
            _ = try? run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        }
        progress("完成")
        return newVersion
    }

    // MARK: - Helpers

    struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
