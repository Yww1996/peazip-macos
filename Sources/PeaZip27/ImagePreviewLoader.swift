import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Include metadata so refreshing a replaced image invalidates the preview task.
struct ImagePreviewRequest: Hashable, Sendable {
    let fileURL: URL
    var archiveURL: URL? = nil
    var entryPath: String? = nil
    var modified: Date = .distantPast
    var size: Int64 = 0

    static func supports(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

struct ImagePreviewResult: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let frameCount: Int
}

enum ImagePreviewError: LocalizedError {
    case unsafeEntry, extractionFailed, unreadableImage

    var errorDescription: String? {
        switch self {
        case .unsafeEntry: return "无法安全预览这个压缩包条目。"
        case .extractionFailed: return "未能提取图片。压缩包可能已加密、损坏或无法访问。"
        case .unreadableImage: return "无法读取图片。文件可能已损坏，或系统暂不支持这种图像格式。"
        }
    }
}

/// The actor serializes extraction/decoding away from the main actor. Cancelled
/// queued selections are skipped; an already-running 7z job cleans its own scratch
/// directory before the next selection is loaded.
actor ImagePreviewLoader {
    static let shared = ImagePreviewLoader()
    static let maxPixelSize = 1600

    func load(_ request: ImagePreviewRequest) throws -> ImagePreviewResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }
        let imageURL: URL

        if let archive = request.archiveURL {
            guard let entry = request.entryPath, !entry.isEmpty,
                  !entry.hasPrefix("/"), !entry.contains("\\"),
                  !entry.split(separator: "/").contains("..") else {
                throw ImagePreviewError.unsafeEntry
            }
            let directory = fm.temporaryDirectory.appendingPathComponent("peazip-image-\(UUID().uuidString)", isDirectory: true)
            scratch = directory
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let access = archive.startAccessingSecurityScopedResource()
            let result = ArchiveEngine.extractEntries(archive, paths: [entry], to: directory, onLine: nil)
            if access { archive.stopAccessingSecurityScopedResource() }
            try Task.checkCancellation()
            guard result.ok else { throw ImagePreviewError.extractionFailed }
            let extracted = directory.appendingPathComponent(entry).resolvingSymlinksInPath().standardizedFileURL
            let allowed = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard extracted.path.hasPrefix(allowed) else { throw ImagePreviewError.unsafeEntry }
            imageURL = extracted
        } else {
            imageURL = request.fileURL
        }

        try Task.checkCancellation()
        let access = imageURL.startAccessingSecurityScopedResource()
        defer { if access { imageURL.stopAccessingSecurityScopedResource() } }
        return try Self.decode(imageURL)
    }

    private static func decode(_ url: URL) throws -> ImagePreviewResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ImagePreviewError.unreadableImage }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ImagePreviewError.unreadableImage
        }
        try Task.checkCancellation()
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? image.width
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? image.height
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = [5, 6, 7, 8].contains(orientation)
        return ImagePreviewResult(image: image, pixelWidth: rotated ? height : width,
                                  pixelHeight: rotated ? width : height,
                                  frameCount: CGImageSourceGetCount(source))
    }
}
