import XCTest
@testable import PeaZip27

final class LegacyZIPExtractionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    // Synthetic stored ZIP, avoiding any dependence on external Python or a real
    // customer's documents. Every file contains "hello" with its known CRC-32.
    private func zip(_ entries: [(String, Bool)], unflaggedUTF8: Bool = false) throws -> URL {
        var local = Data(), central = Data()
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for (name, utf8) in entries {
            let bytes = try XCTUnwrap(name.data(using: utf8 ? .utf8 : gb))
            let directory = name.hasSuffix("/")
            let payload = directory ? Data() : Data("hello".utf8)
            let crc: UInt32 = directory ? 0 : 0x3610a686
            let offset = UInt32(local.count), flags: UInt16 = utf8 && !unflaggedUTF8 ? 0x800 : 0
            local.le(UInt32(0x04034b50)); local.le(UInt16(20)); local.le(flags)
            for _ in 0..<3 { local.le(UInt16(0)) }
            local.le(crc); local.le(UInt32(payload.count)); local.le(UInt32(payload.count))
            local.le(UInt16(bytes.count)); local.le(UInt16(0)); local.append(bytes); local.append(payload)
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(flags)
            for _ in 0..<3 { central.le(UInt16(0)) }
            central.le(crc); central.le(UInt32(payload.count)); central.le(UInt32(payload.count))
            central.le(UInt16(bytes.count))
            for _ in 0..<4 { central.le(UInt16(0)) }
            central.le(UInt32(directory ? 0x10 : 0)); central.le(offset); central.append(bytes)
        }
        let offset = UInt32(local.count)
        local.append(central); local.le(UInt32(0x06054b50))
        local.le(UInt16(0)); local.le(UInt16(0))
        local.le(UInt16(entries.count)); local.le(UInt16(entries.count))
        local.le(UInt32(central.count)); local.le(offset); local.le(UInt16(0))
        let archive = root.appendingPathComponent("test.zip")
        try local.write(to: archive)
        return archive
    }

    func testGBKLongNameIsDecodedBeforeWriting() throws {
        let name = "资料/" + String(repeating: "长", count: 60) + ".txt"
        let archive = try zip([("资料/", false), (name, false)])
        let output = root.appendingPathComponent("output")
        let result = ArchiveEngine.extract(archive, to: output, onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(name)), Data("hello".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["资料"])
    }

    func testSelectedNameWithBracketsIsLiteral() throws {
        let archive = try zip([("资料/图[1].txt", false), ("资料/图1.txt", false)])
        let output = root.appendingPathComponent("output")
        let result = ArchiveEngine.extractEntries(archive, paths: ["资料/图[1].txt"], to: output, onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("资料/图[1].txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("资料/图1.txt").path))
    }

    func testSelectingDirectoryIncludesChildrenOnly() throws {
        let archive = try zip([("资料/a.txt", false), ("资料/子目录/b.txt", false), ("其他.txt", false)])
        let output = root.appendingPathComponent("output")
        let result = ArchiveEngine.extractEntries(archive, paths: ["资料"], to: output, onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("资料/子目录/b.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("其他.txt").path))
    }

    func testUTF8FlagIsRespectedInMixedZIP() throws {
        let archive = try zip([("中文.txt", false), ("另一份.txt", true)])
        let output = root.appendingPathComponent("output")
        let result = ArchiveEngine.extract(archive, to: output, onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("另一份.txt").path))
    }

    func testParentTraversalIsRejectedBeforeWriting() throws {
        let archive = try zip([("../越界.txt", false)])
        let result = ArchiveEngine.extract(archive, to: root.appendingPathComponent("output"), onLine: nil)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("越界.txt").path))
    }

    func testUnflaggedUTF8SiblingIsNotReinterpretedAsGBK() throws {
        let archive = try zip([("中文.txt", false), ("另一份.txt", true)], unflaggedUTF8: true)
        XCTAssertFalse(LegacyZipNames.canExtractAsGB18030(archive))
        let output = root.appendingPathComponent("output")
        let result = ArchiveEngine.extract(archive, to: output, onLine: nil)
        XCTAssertTrue(result.ok, result.output)
        for name in ["中文.txt", "另一份.txt"] {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(name)), Data("hello".utf8))
        }
    }

    func testMixedEncodingDoesNotBypassTraversalCheck() throws {
        let archive = try zip([("../越界.txt", false), ("另一份.txt", true)], unflaggedUTF8: true)
        let result = ArchiveEngine.extract(archive, to: root.appendingPathComponent("output"), onLine: nil)
        XCTAssertFalse(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("越界.txt").path))
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var number = value.littleEndian
        Swift.withUnsafeBytes(of: &number) { append(contentsOf: $0) }
    }
}
