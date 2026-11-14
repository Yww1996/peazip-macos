// Run from the repository root:
// swiftc Sources/PeaZip27/WindowTabLayout.swift tools/tab_layout_test.swift -o /tmp/peazip-tab-layout-test
// /tmp/peazip-tab-layout-test
import AppKit
import SwiftUI

@main
struct TabLayoutIntegrationTest {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var windows: [NSWindow] = []
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1120, height: 700),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.toolbar = NSToolbar(identifier: UUID().uuidString)
            window.tabbingIdentifier = "PeaZipLayoutTest"
            let probe = WindowTabLayout.TabLayoutView(frame: .zero)
            window.contentView!.addSubview(probe)
            windows.append(window)
            return window
        }
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        let first = makeWindow()
        first.orderFront(nil)
        pump()
        precondition(first.toolbarStyle == .unified)
        for _ in 0..<3 {
            let window = makeWindow()
            first.addTabbedWindow(window, ordered: .above)
        }
        pump()
        precondition(first.tabGroup?.windows.count == 4)
        precondition(first.tabGroup?.isTabBarVisible == true)
        for window in windows { precondition(window.toolbarStyle == .expanded) }
        first.setContentSize(NSSize(width: 900, height: 520))
        pump()
        precondition(first.toolbarStyle == .expanded)
        for window in windows.dropFirst() { first.tabGroup?.removeWindow(window); window.close() }
        pump()
        if first.tabGroup?.isTabBarVisible == true { first.toggleTabBar(nil); pump() }
        precondition(first.toolbarStyle == .unified)
        first.close()
        print("PASS: four tabs, resize, detach/close and restore single-window chrome")
    }
}
