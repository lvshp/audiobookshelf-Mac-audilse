import AudilseCore
import SwiftUI

/// Freeze the account and access scope when the containing item page opens.
/// An old row must never start a request with a newly selected account's client.
struct ItemFileActionSource: Equatable {
    let partition: AccountPartition
    let client: ABSClient?
    let baseURL: URL
    let libraryID: String
    let mediaType: String
    let permissions: UserPermissions
    let accessibleLibraries: [String]
    let selectedTags: [String]
    let offline: Bool

    @MainActor init?(store: AppStore, item: AudilseCore.LibraryItem) {
        guard !store.isDemo, !store.isConnecting, !store.recoveryBusy, store.serverRecovery == nil,
              let profile = store.profile, let partition = store.partition,
              let user = store.user, user.isActive,
              partition.serverID == profile.id, partition.userID == user.id,
              store.libraries.contains(where: { $0.id == item.libraryId && $0.mediaType == item.mediaType }),
              store.isOffline || store.client != nil else { return nil }
        self.partition = partition; client = store.client; baseURL = profile.baseURL
        libraryID = item.libraryId; mediaType = item.mediaType; permissions = user.permissions
        accessibleLibraries = user.librariesAccessible; selectedTags = user.itemTagsSelected
        offline = store.isOffline
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.partition == rhs.partition && lhs.client === rhs.client && lhs.baseURL == rhs.baseURL &&
        lhs.libraryID == rhs.libraryID && lhs.mediaType == rhs.mediaType && lhs.permissions == rhs.permissions &&
        lhs.accessibleLibraries == rhs.accessibleLibraries && lhs.selectedTags == rhs.selectedTags && lhs.offline == rhs.offline
    }

    @MainActor func isCurrent(_ store: AppStore, item: AudilseCore.LibraryItem) -> Bool {
        Self(store: store, item: item) == self
    }
}

/// Unlike a Boolean plus an optional file, this target always supplies the file
/// and its metadata when SwiftUI constructs the reader sheet.
struct SelectedReaderTarget: Identifiable {
    let id = UUID()
    let item: AudilseCore.LibraryItem
    let fileIno: String
    let source: ItemFileActionSource

    @MainActor init?(store: AppStore, item: AudilseCore.LibraryItem, file: MediaFile, source: ItemFileActionSource?) {
        guard !file.ino.isEmpty, ItemFileCatalog.canRead(file), let source,
              source.isCurrent(store, item: item) else { return nil }
        var snapshot = item
        snapshot.libraryFiles.removeAll { $0.ino == file.ino }
        snapshot.libraryFiles.append(file)
        self.item = snapshot; fileIno = file.ino; self.source = source
    }
}

struct SelectedReaderSheet: View {
    let store: AppStore
    let target: SelectedReaderTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if target.source.isCurrent(store, item: target.item) {
                ReaderView(store: store, item: target.item, fileIno: target.fileIno)
            } else {
                VStack(spacing: 18) {
                    ContentUnavailableView(L10n.tr("无法打开文件"), systemImage: "book.closed",
                                           description: Text(L10n.tr("账户或内容访问权限已改变，请重新打开详情。")))
                    Button(L10n.tr("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(24).frame(width: 520, height: 300)
            }
        }
        .onChange(of: target.source.isCurrent(store, item: target.item)) { _, current in
            if !current { dismiss() }
        }
    }
}

enum ItemFileCatalog {
    static func rawFiles(in item: AudilseCore.LibraryItem) -> [MediaFile] {
        item.libraryFiles + item.media.audioFiles + [item.media.ebookFile].compactMap { $0 } + item.media.episodes.compactMap(\.audioFile)
    }

    /// Preserve library-file metadata while filling in audio-specific fields.
    /// Empty inode entries remain visible but cannot become request targets.
    static func deduplicated(_ files: [MediaFile]) throws -> [MediaFile] {
        var result: [MediaFile] = [], indexes: [String: Int] = [:]
        for file in files {
            try Task.checkCancellation()
            guard !file.ino.isEmpty else { result.append(file); continue }
            guard let index = indexes[file.ino] else {
                indexes[file.ino] = result.count; result.append(file); continue
            }
            var merged = result[index]
            if merged.metadata.filename.isEmpty { merged.metadata.filename = file.metadata.filename }
            if merged.metadata.ext == nil { merged.metadata.ext = file.metadata.ext }
            if merged.metadata.path == nil { merged.metadata.path = file.metadata.path }
            if merged.metadata.relPath == nil { merged.metadata.relPath = file.metadata.relPath }
            if merged.metadata.size == nil { merged.metadata.size = file.metadata.size }
            if merged.duration == nil { merged.duration = file.duration }
            if merged.index == nil { merged.index = file.index }
            if merged.mimeType == nil { merged.mimeType = file.mimeType }
            merged.exclude = merged.exclude || file.exclude
            merged.isInvalid = merged.isInvalid || file.isInvalid
            if merged.error == nil { merged.error = file.error }
            result[index] = merged
        }
        return result
    }

    static func canRead(_ file: MediaFile) -> Bool { (try? EbookFormat(filename: file.metadata.filename)) != nil }

    static func icon(_ file: MediaFile) -> String {
        if canRead(file) { return "book.closed" }
        if file.duration != nil || file.mimeType?.hasPrefix("audio/") == true { return "waveform" }
        return "doc"
    }

    static func pageRange(count: Int, page: Int, pageSize: Int = 80) -> Range<Int> {
        let boundedPage = min(max(0, page), max(0, (count - 1) / pageSize))
        let start = min(count, boundedPage * pageSize)
        return start..<min(count, start + pageSize)
    }
}

struct OriginalFilePagination: View {
    let count: Int
    @Binding var page: Int
    private let pageSize = 80
    private var pageCount: Int { max(1, (count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(max(0, page), pageCount - 1) }

    var body: some View {
        if count > pageSize {
            HStack(spacing: 12) {
                Text(L10n.format("%1$@–%2$@ / 共 %3$@ %4$@", String(currentPage * pageSize + 1),
                                 String(min(count, (currentPage + 1) * pageSize)), String(count), L10n.tr("个文件")))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { page = currentPage - 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0).accessibilityLabel(L10n.tr("上一页"))
                Picker(L10n.tr("页码"), selection: $page) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Text(L10n.format("第 %1$@ / %2$@ 页", String(index + 1), String(pageCount))).tag(index)
                    }
                }.labelsHidden().frame(width: 120)
                Button { page = currentPage + 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage == pageCount - 1).accessibilityLabel(L10n.tr("下一页"))
            }.controlSize(.small).padding(.vertical, 6)
        }
    }
}
