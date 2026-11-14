import XCTest
@testable import PeaZip27

final class UpdateInstallationHealthTests: XCTestCase {
    private func framework() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for path in ["Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let info: [String: String] = ["CFBundleExecutable": "Updater", "CFBundleIdentifier": "test.Updater",
                                     "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Updater.app/Contents/Info.plist"))
        return root
    }

    func testCompleteInstallationPasses() throws {
        XCTAssertNil(UpdateInstallationHealth.problem(in: try framework()))
    }

    func testEmptyExecutableIsRejectedEvenWhenMarkedExecutable() throws {
        let root = try framework()
        try Data().write(to: root.appendingPathComponent("Autoupdate"))
        XCTAssertNotNil(UpdateInstallationHealth.problem(in: root))
    }

    func testEmptyHelperPlaceholderFromBlockedSymlinkIsRejected() throws {
        let root = try framework()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Updater.app"))
        try Data().write(to: root.appendingPathComponent("Updater.app"))
        XCTAssertNotNil(UpdateInstallationHealth.problem(in: root))
    }

    func testHelperMissingBundleMetadataIsRejected() throws {
        let root = try framework()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Updater.app/Contents/Info.plist"))
        XCTAssertNotNil(UpdateInstallationHealth.problem(in: root))
    }
}
