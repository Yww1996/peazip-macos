#if DEBUG
import AppKit

/// Debug-build integration probe. Never included in a distributable release.
enum ServiceLaunchProbe {
    static var kind: String? { ProcessInfo.processInfo.environment["PEAZIP_TEST_LAUNCH_KIND"] }
    static var maximumVisibleWindows = 0
    private static var observer: NSObjectProtocol?

    static func started(provider: AppDelegate) {
        guard kind != nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in sample() }
        sample()
        if let input = ProcessInfo.processInfo.environment["PEAZIP_TEST_ARCHIVE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + (kind == "service" ? 0.15 : 1.5)) {
                let board = NSPasteboard.withUniqueName()
                board.writeObjects([URL(fileURLWithPath: input) as NSURL])
                var error: NSString = ""
                provider.peaExtractDesktop(board, userData: "", error: &error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            finished()
            NSApp.terminate(nil)
        }
    }

    static func sample() {
        let count = NSApp.windows.filter { $0.isVisible && $0.frame.height > 100 }.count
        maximumVisibleWindows = max(maximumVisibleWindows, count)
    }

    static func finished() {
        guard kind != nil,
              let path = ProcessInfo.processInfo.environment["PEAZIP_TEST_REPORT"] else { return }
        sample()
        let result: [String: Any] = ["kind": kind!, "maxVisibleWindows": maximumVisibleWindows,
                                    "backgroundOnly": AppDelegate.backgroundOnly]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
