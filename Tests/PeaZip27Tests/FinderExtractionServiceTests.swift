import XCTest
@testable import PeaZip27

final class FinderExtractionServiceTests: XCTestCase {
    private var root: URL!
    private var desktop: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        desktop = root.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func makeArchive(_ name: String) throws -> URL {
        let file = root.appendingPathComponent("内容.txt")
        try Data("后台解压测试".utf8).write(to: file)
        let archive = root.appendingPathComponent(name)
        let result = ArchiveEngine.add(sources: [file], to: archive, format: .zip, level: 1,
                                       exclusions: [], onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        return archive
    }

    func testDesktopExtractionCreatesNamedFolderAndPreservesContent() throws {
        let archive = try makeArchive("收球照片.zip")
        let outputs = try FinderExtractionService.perform([archive], destination: .desktop,
                                                          desktop: desktop, downloads: root)
        XCTAssertEqual(outputs, [desktop.appendingPathComponent("收球照片", isDirectory: true)])
        XCTAssertEqual(try Data(contentsOf: outputs[0].appendingPathComponent("内容.txt")),
                       Data("后台解压测试".utf8))
    }

    func testBesideArchiveDoesNotUseDesktop() throws {
        let archive = try makeArchive("样品.zip")
        let outputs = try FinderExtractionService.perform([archive], destination: .besideArchive,
                                                          desktop: desktop, downloads: root)
        XCTAssertEqual(outputs[0].deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
    }

    func testRepeatedExtractionDoesNotOverwriteExistingFolder() throws {
        let archive = try makeArchive("照片.zip")
        let existing = desktop.appendingPathComponent("照片")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("原文件.txt")
        try Data("保留".utf8).write(to: marker)
        let outputs = try FinderExtractionService.perform([archive], destination: .desktop,
                                                          desktop: desktop, downloads: root)
        XCTAssertEqual(outputs[0].lastPathComponent, "照片 (2)")
        XCTAssertEqual(try Data(contentsOf: marker), Data("保留".utf8))
    }

    func testExistingSymlinkIsNotFollowed() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: desktop.appendingPathComponent("照片"),
                                                   withDestinationURL: outside)
        let output = try FinderExtractionService.reserveFolder(named: "照片", under: desktop)
        XCTAssertEqual(output.lastPathComponent, "照片 (2)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testUnavailableDesktopFailsWithoutFallingBackToDownloads() throws {
        let archive = try makeArchive("照片.zip")
        XCTAssertThrowsError(try FinderExtractionService.perform([archive], destination: .desktop,
            desktop: root.appendingPathComponent("missing/Desktop"), downloads: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("照片").path))
    }

    func testCompoundArchiveSuffixIsRemoved() {
        XCTAssertEqual(FinderExtractionService.folderName(for: URL(fileURLWithPath: "/tmp/资料.tar.gz")), "资料")
    }

    func testMultipleArchivesAreExtractedSeparately() throws {
        let first = try makeArchive("照片.zip")
        let second = try makeArchive("资料.zip")
        let outputs = try FinderExtractionService.perform([first, second], destination: .desktop,
                                                          desktop: desktop, downloads: root)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["照片", "资料"])
        for output in outputs {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("内容.txt")),
                           Data("后台解压测试".utf8))
        }
    }
}
