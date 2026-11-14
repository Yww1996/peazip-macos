import AppKit
import SwiftUI

/// Window tabs belong to AppKit's titlebar, outside the SwiftUI detail view.
/// Use standard expanded window chrome while that bar is present, so AppKit
/// lays it out independently of NavigationSplitView's unified toolbar columns.
struct WindowTabLayout: NSViewRepresentable {
    @Binding var tabBarVisible: Bool

    func makeNSView(context: Context) -> TabLayoutView { TabLayoutView() }

    func updateNSView(_ view: TabLayoutView, context: Context) {
        view.visibilityChanged = { visible in
            if tabBarVisible != visible { tabBarVisible = visible }
        }
        view.scheduleRefresh()
    }

    final class TabLayoutView: NSView {
        var visibilityChanged: ((Bool) -> Void)?
        private var updateObserver: NSObjectProtocol?
        private var windowsObserver: NSKeyValueObservation?
        private weak var observedGroup: NSWindowTabGroup?
        private var refreshScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
            updateObserver = nil
            windowsObserver = nil
            observedGroup = nil
            guard window != nil else { return }
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            }
            scheduleRefresh()
        }

        func scheduleRefresh() {
            guard !refreshScheduled, window != nil else { return }
            refreshScheduled = true
            // Avoid changing SwiftUI state inside a view update or a tab-group mutation.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }

        private func refresh() {
            guard let window else { return }
            let group = window.tabGroup
            if observedGroup !== group {
                observedGroup = group
                windowsObserver = group?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    self?.scheduleRefresh()
                }
            }
            let visible = group?.isTabBarVisible == true
            let style: NSWindow.ToolbarStyle = visible ? .expanded : .unified
            if window.titleVisibility != .visible { window.titleVisibility = .visible }
            if window.toolbarStyle != style { window.toolbarStyle = style }
            visibilityChanged?(visible)
        }

        deinit {
            if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        }
    }
}
