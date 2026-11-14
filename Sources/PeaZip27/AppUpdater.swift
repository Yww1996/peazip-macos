import AppKit
import Combine
import Sparkle
import SwiftUI

struct AppUpdateMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("检查应用更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates && updater.installationProblem == nil)
    }
}

/// Keeps a pending installation from terminating a running archive/engine operation.
@MainActor
final class UpdateRelaunchGate {
    private var busy = false
    private var resume: (() -> Void)?

    func setBusy(_ value: Bool) {
        busy = value
        guard !busy, let action = resume else { return }
        resume = nil
        action()
    }

    func postponeIfBusy(_ action: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        resume = action
        return true
    }
}

/// Sparkle owns download, Ed25519 verification, replacement, rollback and relaunch.
/// The controller lives for the entire app lifetime, rather than a settings window.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var waitingForTasks = false
    @Published private(set) var installationProblem: String?

    private var controller: SPUStandardUpdaterController!
    private var observations = Set<AnyCancellable>()
    private let relaunchGate = UpdateRelaunchGate()
    private var started = false
    private var observingTasks = false

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func start(model: AppModel?) {
        // SwiftUI may create its StateObject after the AppKit launch callback.
        // Bind when the main view appears as well, without starting a second updater.
        if !observingTasks, let model {
            observingTasks = true
            relaunchGate.setBusy(model.busy || EngineUpdater.shared.state.isWorking)
            Publishers.CombineLatest(model.$busy, EngineUpdater.shared.$state)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] busy, engineState in
                    guard let self else { return }
                    let working = busy || engineState.isWorking
                    if !working { self.waitingForTasks = false }
                    self.relaunchGate.setBusy(working)
                }
                .store(in: &observations)
        }
        guard !started else { return }
        installationProblem = UpdateInstallationHealth.problem(in: Bundle(for: SPUUpdater.self).bundleURL)
        guard installationProblem == nil else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        installationProblem = UpdateInstallationHealth.problem(in: Bundle(for: SPUUpdater.self).bundleURL)
        if let installationProblem {
            let alert = NSAlert()
            alert.messageText = "自动更新暂不可用"
            alert.informativeText = installationProblem
            alert.addButton(withTitle: "下载完整安装包")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "https://github.com/Yww1996/peazip-macos/releases/latest")!)
            }
            return
        }
        if !started { start(model: AppDelegate.model) }
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        if let problem = UpdateInstallationHealth.problem(in: Bundle(for: SPUUpdater.self).bundleURL) {
            installationProblem = problem
            throw NSError(domain: "com.yww.pea27.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: problem])
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        waitingForTasks = relaunchGate.postponeIfBusy(installHandler)
        return waitingForTasks
    }
}
