import SwiftUI

struct ImagePreviewPane: View {
    let item: FileItem?
    let archive: URL?
    let selectionCount: Int
    @State private var result: ImagePreviewResult?
    @State private var loading = false
    @State private var failure: String?
    @State private var loadedRequest: ImagePreviewRequest?

    private var visibleResult: ImagePreviewResult? {
        loadedRequest == request ? result : nil
    }

    private var request: ImagePreviewRequest? {
        guard let item, !item.isDirectory, ImagePreviewRequest.supports(item.url) else { return nil }
        return ImagePreviewRequest(fileURL: item.url, archiveURL: item.fromArchive ? archive : nil,
                                   entryPath: item.entryPath, modified: item.modified, size: item.size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text("图片预览").font(.headline)
                Spacer()
            }
            .padding(16)
            Divider()
            GeometryReader { geometry in
                Group {
                    if let result = visibleResult {
                        Image(decorative: result.image, scale: 1)
                            .resizable().scaledToFit()
                            .accessibilityLabel(item?.name ?? "图片预览")
                            .padding(14)
                    } else if loading {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(item?.fromArchive == true ? "正在提取图片…" : "正在读取图片…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let failure {
                        placeholder("无法预览", symbol: "exclamationmark.triangle", detail: failure)
                    } else if selectionCount > 1 {
                        placeholder("已选中 \(selectionCount) 项", symbol: "photo.on.rectangle",
                                    detail: "选中一张图片即可查看预览。")
                    } else {
                        placeholder(item == nil ? "选中图片查看预览" : "此项目不支持图片预览",
                                    symbol: "photo", detail: "支持 PNG、JPEG、HEIC 等图片格式。")
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(Color(nsColor: .textBackgroundColor))
            if let item {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.name).font(.callout.weight(.semibold))
                        .lineLimit(2).textSelection(.enabled)
                    HStack {
                        Text(item.kind)
                        Spacer()
                        Text(item.sizeText).monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let result = visibleResult {
                        Text("\(result.pixelWidth) × \(result.pixelHeight) 像素")
                            .font(.caption).foregroundStyle(.secondary)
                        if result.frameCount > 1 {
                            Text("多帧图片，当前显示静态预览")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if item.fromArchive {
                        Label("压缩包内图片", systemImage: "doc.zipper")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: request) {
            result = nil
            loadedRequest = nil
            failure = nil
            loading = request != nil
            guard let request else { return }
            do {
                // Avoid extracting every intermediate row when using the arrow keys.
                try await Task.sleep(nanoseconds: 180_000_000)
                let loaded = try await ImagePreviewLoader.shared.load(request)
                try Task.checkCancellation()
                result = loaded
                loadedRequest = request
                loading = false
            } catch is CancellationError {
                // The new task owns the UI state; an old completion cannot replace it.
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
                loading = false
            }
        }
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
