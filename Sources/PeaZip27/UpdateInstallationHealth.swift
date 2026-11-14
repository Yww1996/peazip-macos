import Foundation

enum UpdateInstallationHealth {
    static let repairMessage = "当前安装中的更新组件不完整，请下载完整安装包并替换应用后再更新。"

    static func problem(in framework: URL) -> String? {
        let manager = FileManager.default
        for path in ["Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"] {
            let file = framework.appendingPathComponent(path)
            guard manager.isExecutableFile(atPath: file.path),
                  let size = (try? manager.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
                  size.int64Value > 0 else { return repairMessage }
        }
        // Sparkle obtains the helper through NSBundle, not just its executable path.
        let helper = framework.appendingPathComponent("Updater.app", isDirectory: true)
        guard let bundle = Bundle(url: helper), bundle.bundleIdentifier != nil,
              bundle.executableURL != nil else { return repairMessage }
        return nil
    }
}
