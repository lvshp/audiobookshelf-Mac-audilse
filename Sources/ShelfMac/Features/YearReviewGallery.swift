import AppKit
import CoreTransferable
import ImageIO
import Observation
import ShelfCore
import SwiftUI
import UniformTypeIdentifiers

struct YearReviewStyle: Identifiable {
    let id: Int
    let title: String
    let size: CGSize
}

struct YearReviewPNG: Transferable, Sendable {
    let data: Data
    let filename: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName { $0.filename }
    }
}

struct YearReviewPNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor enum YearReviewRenderer {
    static func png<Content: View>(_ content: Content, size: CGSize) -> (image: NSImage, data: Data)? {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.proposedSize = .init(size)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let cgImage = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return nil }
        return (NSImage(cgImage: cgImage, size: size), data)
    }
}

/// The preview, file export, clipboard, and system share all use the same rendered PNG.
/// A caller supplies an account/year/data revision so stale artwork cannot be shared.
struct YearReviewGallery<Poster: View>: View {
    let title: String
    let filename: String
    let styles: [YearReviewStyle]
    let revision: String
    var isPreparing = false
    @ViewBuilder let poster: (Int) -> Poster
    @State private var selectedStyle = 0
    @State private var rendered: Rendered?
    @State private var exporting = false
    @State private var exportSnapshot: ExportSnapshot?
    @State private var error: String?
    @State private var copied = false
    @State private var renderAttempt = 0

    private struct RenderKey: Hashable { let revision: String; let style: Int; let language: AppLanguage; let preparing: Bool; let attempt: Int }
    private struct Rendered { let key: RenderKey; let image: NSImage; let data: Data }
    private struct ExportSnapshot { let key: RenderKey; let data: Data; let filename: String }
    private var style: YearReviewStyle { styles.first { $0.id == selectedStyle } ?? styles.first ?? .init(id: 0, title: "", size: .init(width: 800, height: 800)) }
    private var renderKey: RenderKey { .init(revision: revision, style: style.id, language: AppLanguageStore.shared.selection, preparing: isPreparing, attempt: renderAttempt) }
    private var current: Rendered? { !isPreparing && rendered?.key == renderKey ? rendered : nil }
    private var exportName: String { filename + "-\(style.id + 1).png" }

    var body: some View {
        let exportedKey = exportSnapshot?.key
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { stylePicker; Spacer(); actions }
                VStack(alignment: .leading, spacing: 12) { stylePicker; actions }
            }
            if let current {
                Image(nsImage: current.image).resizable().scaledToFit().frame(maxWidth: 800)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(title + " · " + style.title)
            } else if error == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(ShelfTheme.accent.opacity(0.06))
                    ProgressView(isPreparing ? L10n.tr("正在读取回顾封面…") : L10n.tr("正在生成回顾图片…"))
                }.frame(height: style.size.height / style.size.width * 440)
            }
            if let error {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                    if current == nil { Button(L10n.tr("重试")) { renderAttempt += 1 } }
                }
            }
            if copied { Text(L10n.tr("图片已复制")).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: renderKey) { _, _ in exporting = false; exportSnapshot = nil }
        .onDisappear { exporting = false; exportSnapshot = nil }
        .task(id: renderKey) {
            guard !Task.isCancelled else { return }
            let key = renderKey
            copied = false; error = nil
            guard !isPreparing else { rendered = nil; return }
            // Let the loading state be drawn before asking SwiftUI for a bitmap.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let output = YearReviewRenderer.png(poster(style.id), size: style.size)
            guard !Task.isCancelled, key == renderKey else { return }
            if let output { rendered = .init(key: key, image: output.image, data: output.data) }
            else { rendered = nil; error = L10n.tr("无法生成回顾图片，请刷新后重试。") }
        }
        .fileExporter(isPresented: $exporting, document: exportSnapshot.map { YearReviewPNGDocument(data: $0.data) }, contentType: .png, defaultFilename: exportSnapshot?.filename ?? exportName) { result in
            guard let exportedKey, exportedKey == renderKey, exportSnapshot?.key == exportedKey else { return }
            if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled { error = L10n.error(failure) }
        }
    }

    private var stylePicker: some View {
        Picker(L10n.tr("回顾版式"), selection: $selectedStyle) {
            ForEach(styles) { style in Text(style.title).tag(style.id) }
        }.pickerStyle(.menu).frame(maxWidth: 230).accessibilityIdentifier("year-review.style")
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("保存 PNG…"), systemImage: "square.and.arrow.down") {
                guard let current else { return }
                exportSnapshot = .init(key: current.key, data: current.data, filename: exportName)
                exporting = true
            }
                .disabled(current == nil).accessibilityIdentifier("year-review.save")
            Button(L10n.tr("复制图片"), systemImage: "doc.on.doc") {
                guard let current else { return }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setData(current.data, forType: .png) { copied = true; error = nil }
                else { error = L10n.tr("无法复制图片，请重试。") }
            }.disabled(current == nil).accessibilityIdentifier("year-review.copy")
            if let current {
                ShareLink(item: YearReviewPNG(data: current.data, filename: exportName), preview: SharePreview(title, image: Image(nsImage: current.image))) {
                    Label(L10n.tr("分享"), systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("year-review.share")
            }
        }.buttonStyle(.bordered)
    }
}

/// Covers are bounded thumbnails fetched with the current authenticated client.
/// Only a matching live account/request may publish images; cancellation never becomes a visible error.
@MainActor @Observable final class YearReviewCoverModel {
    private(set) var images: [String: NSImage] = [:]
    private(set) var isLoading = false
    private(set) var unavailableCount = 0
    private(set) var revision = UUID()
    private var generation = UUID()

    func load(store: AppStore, ids: [String]) async {
        guard !Task.isCancelled else { return }
        let operation = UUID(); generation = operation
        images = [:]; unavailableCount = 0; revision = UUID(); isLoading = false
        var seen = Set<String>()
        let ids = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(25))
        guard !ids.isEmpty else { return }
        guard !store.isOffline, !store.isConnecting, let account = store.partition, let client = store.client, store.user?.isActive == true else { unavailableCount = ids.count; return }
        func isCurrent() -> Bool {
            generation == operation && store.partition == account && store.client === client && !store.isOffline && !store.isConnecting && store.user?.isActive == true && !Task.isCancelled
        }
        isLoading = true
        defer { if generation == operation { isLoading = false; revision = UUID() } }
        await withTaskGroup(of: (String, Data?).self) { group in
            var next = 0
            func enqueue(_ id: String) {
                group.addTask {
                    guard !Task.isCancelled else { return (id, nil) }
                    let path = "api/items/\(ServerEndpoint.component(id))/cover?width=440&height=440&format=jpeg"
                    guard let data = try? await client.requestData(path: path), !Task.isCancelled, data.count < 12 * 1024 * 1024,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
                          let destinationData = CFDataCreateMutable(nil, 0),
                          let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else { return (id, nil) }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { return (id, nil) }
                    return (id, destinationData as Data)
                }
            }
            for id in ids.prefix(3) { enqueue(id); next += 1 }
            while let (id, data) = await group.next() {
                guard isCurrent() else { group.cancelAll(); return }
                if let data, let image = NSImage(data: data) { images[id] = image }
                else { unavailableCount += 1 }
                if next < ids.count { enqueue(ids[next]); next += 1 }
            }
        }
    }
}
