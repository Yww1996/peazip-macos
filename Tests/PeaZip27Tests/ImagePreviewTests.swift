import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PeaZip27

final class ImagePreviewTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peazip-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeImage(_ name: String = "照片.png", width: Int = 80, height: Int = 40,
                           type: UTType = .png, orientation: Int = 1, frames: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testLargeImageIsDownsampledWithoutLosingOriginalDimensions() async throws {
        let url = try makeImage(width: 3200, height: 1200)
        let result = try await ImagePreviewLoader.shared.load(ImagePreviewRequest(fileURL: url))
        XCTAssertEqual(result.pixelWidth, 3200)
        XCTAssertEqual(result.pixelHeight, 1200)
        XCTAssertLessThanOrEqual(max(result.image.width, result.image.height), 1600)
    }

    func testEXIFOrientationMatchesDisplayedDimensions() async throws {
        let url = try makeImage("旋转.jpg", width: 80, height: 40, type: .jpeg, orientation: 6)
        let result = try await ImagePreviewLoader.shared.load(ImagePreviewRequest(fileURL: url))
        XCTAssertEqual(result.pixelWidth, 40)
        XCTAssertEqual(result.pixelHeight, 80)
        XCTAssertLessThan(result.image.width, result.image.height)
    }

    func testGIFReportsMultipleFrames() async throws {
        let url = try makeImage("动画.gif", type: .gif, frames: 2)
        let result = try await ImagePreviewLoader.shared.load(ImagePreviewRequest(fileURL: url))
        XCTAssertEqual(result.frameCount, 2)
    }

    func testNestedChineseImageInsideZIPAndScratchCleanup() async throws {
        let image = try makeImage("图片目录/照片.png")
        let archive = directory.appendingPathComponent("图片.zip")
        let engine = try XCTUnwrap(ArchiveEngine.sevenZip)
        let packed = ArchiveEngine.run(engine, ["a", archive.path, image.deletingLastPathComponent().path, "-tzip"])
        XCTAssertTrue(packed.ok, packed.output)
        let before = try scratchImages()
        let request = ImagePreviewRequest(fileURL: archive.appendingPathComponent("图片目录/照片.png"),
                                          archiveURL: archive, entryPath: "图片目录/照片.png")
        let result = try await ImagePreviewLoader.shared.load(request)
        XCTAssertEqual(result.pixelWidth, 80)
        XCTAssertEqual(result.pixelHeight, 40)
        XCTAssertEqual(try scratchImages(), before)
    }

    func testCorruptImageGivesReadableError() async throws {
        let url = directory.appendingPathComponent("损坏.png")
        try Data("not an image".utf8).write(to: url)
        do {
            _ = try await ImagePreviewLoader.shared.load(ImagePreviewRequest(fileURL: url))
            XCTFail("A corrupt image must not be accepted")
        } catch ImagePreviewError.unreadableImage { }
    }

    func testUnsafeArchivePathIsRejectedBeforeExtraction() async throws {
        let archive = directory.appendingPathComponent("missing.zip")
        for path in ["../outside.png", "/outside.png", "a/../outside.png", "a\\outside.png"] {
            do {
                _ = try await ImagePreviewLoader.shared.load(ImagePreviewRequest(fileURL: archive,
                    archiveURL: archive, entryPath: path))
                XCTFail("Unsafe path accepted: \(path)")
            } catch ImagePreviewError.unsafeEntry { }
        }
    }

    func testCancelledSelectionDoesNotReadImage() async throws {
        let request = ImagePreviewRequest(fileURL: directory.appendingPathComponent("missing.png"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImagePreviewLoader.shared.load(request)
        }
        do { _ = try await task.value; XCTFail("Cancelled selection was loaded") }
        catch is CancellationError { }
    }

    private func scratchImages() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("peazip-image-") })
    }
}
