import Foundation
import Observation
import ShelfCore

struct ChapterDraft: Identifiable {
    let id = UUID()
    var title: String
    var start: Double
    var end: Double
}
struct SeriesDraft: Identifiable {
    let id = UUID()
    var name: String
    var sequence: String
}

@MainActor @Observable final class ContentManagementModel {
    var item: ShelfCore.LibraryItem?
    let operation = ManagementOperation()
    var title = ""
    var subtitle = ""
    var authors = ""
    var series: [SeriesDraft] = []
    var narrators = ""
    var genres = ""
    var tags = ""
    var publisher = ""
    var publishedYear = ""
    var language = ""
    var description = ""
    var isbn = ""
    var asin = ""
    var publishedDate = ""
    var explicit = false
    var abridged = false
    var podcastType = ""
    var provider = "google"
    var providers: [MetadataProvider] = []
    var coverProviders: [MetadataProvider] = []
    var coverProvider = "google"
    var coverURL = ""
    var serverCoverPath = ""
    var coverResults: [String] = []
    var metadataResults: [MetadataSearchBook] = []
    var overrideDetails = false
    var overrideCover = false
    var orderedFiles: [OrderedAudioFile] = []
    var libraryFiles: [ManagedLibraryFile] = []
    var chapters: [ChapterDraft] = []
    var diagnostic = ""
    var forceChapters = false
    var backupOriginals = true
    var codec = "aac"
    var bitrate = "128k"
    var channels = "2"
    var deleteOriginalFiles = false

    func open(store: AppStore, item: ShelfCore.LibraryItem) async {
        operation.bind(store); self.item = item; provider = item.mediaType == "podcast" ? "itunes" : "google"; coverProvider = provider; fill(item)
        await reload()
    }
    func cancel() { operation.cancel() }
    func reload() async {
        guard let id = item?.id else { return }
        await operation.run(work: { client in
            async let full = client.item(id: id)
            async let providers = client.metadataProviders()
            async let files = client.managedItemFiles(id: id)
            return try await (full, providers, files)
        }, apply: { full, catalog, files in
            self.fill(full); self.providers = full.mediaType == "podcast" ? catalog.podcasts : catalog.books; self.coverProviders = full.mediaType == "podcast" ? catalog.podcasts : catalog.booksCovers
            self.libraryFiles = files
        })
    }
    private func fill(_ item: ShelfCore.LibraryItem) {
        self.item = item
        let metadata = item.media.metadata
        title = metadata.title; subtitle = metadata.subtitle ?? ""; authors = metadata.authors.map(\.name).joined(separator: "\n")
        if authors.isEmpty { authors = metadata.authorName ?? metadata.author ?? "" }
        series = metadata.series.map { .init(name: $0.name, sequence: $0.sequence ?? "") }
        narrators = metadata.narrators.joined(separator: "\n"); genres = metadata.genres.joined(separator: "\n"); tags = item.media.tags.joined(separator: "\n")
        publisher = metadata.publisher ?? ""; publishedYear = metadata.publishedYear ?? ""; language = metadata.language ?? ""; description = metadata.description ?? ""; explicit = metadata.explicit
        isbn = metadata.isbn ?? ""; asin = metadata.asin ?? ""; publishedDate = metadata.publishedDate ?? ""; abridged = metadata.abridged ?? false
        podcastType = metadata.type ?? ""
        orderedFiles = item.media.audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }.map { OrderedAudioFile(ino: $0.ino, exclude: $0.exclude) }
        chapters = item.media.chapters.map { ChapterDraft(title: $0.title, start: $0.start, end: $0.end) }
    }
    private func lines(_ value: String) -> [String] { value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func saveMetadata() async {
        guard let item else { return }
        let old = item.media.metadata
        let seriesNames = series.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !seriesNames.contains(""), Set(seriesNames).count == seriesNames.count else { operation.error = L10n.tr("系列名称不能为空或重复；不需要的系列请移除。"); return }
        var update = MetadataUpdate()
        if title != old.title { update.title = title }
        if subtitle != old.subtitle ?? "" { update.subtitle = subtitle }
        let authorNames = lines(authors)
        let oldNames = old.authors.isEmpty ? lines(old.authorName ?? old.author ?? "") : old.authors.map(\.name)
        if authorNames != oldNames {
            if item.mediaType == "podcast" { update.author = authorNames.joined(separator: ", ") }
            else { update.authors = authorNames.map { name in old.authors.first { $0.name == name } ?? NamedEntity(name: name) } }
        }
        let seriesPayload = series.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { draft in
            NamedEntity(id: old.series.first { $0.name == draft.name }?.id ?? "", name: draft.name, sequence: draft.sequence.isEmpty ? nil : draft.sequence)
        }
        let sameSeries = series.count == old.series.count && zip(series, old.series).allSatisfy { draft, existing in
            draft.name == existing.name && draft.sequence == (existing.sequence ?? "")
        }
        if item.mediaType == "book", !sameSeries { update.series = seriesPayload }
        if lines(narrators) != old.narrators { update.narrators = lines(narrators) }
        if lines(genres) != old.genres { update.genres = lines(genres) }
        if publisher != old.publisher ?? "" { update.publisher = publisher }
        if publishedYear != old.publishedYear ?? "" { update.publishedYear = publishedYear }
        if language != old.language ?? "" { update.language = language }
        if description != old.description ?? "" { update.description = description }
        if isbn != old.isbn ?? "" { update.isbn = isbn }
        if asin != old.asin ?? "" { update.asin = asin }
        if publishedDate != old.publishedDate ?? "" { update.publishedDate = publishedDate }
        if abridged != old.abridged ?? false { update.abridged = abridged }
        if explicit != old.explicit { update.explicit = explicit }
        if item.mediaType == "podcast", podcastType != (old.type ?? "") { update.type = podcastType }
        let payload = MediaUpdate(metadata: update, tags: lines(tags) == item.media.tags ? nil : lines(tags))
        await operation.run(.updateContent, work: { try await $0.updateItemMedia(id: item.id, update: payload) }, apply: { self.fill($0.libraryItem); self.operation.notice = L10n.tr("内容信息已保存。") })
    }
    func searchMetadata() async {
        guard let id = item?.id else { return }
        let query = MetadataSearchQuery(title: title, author: lines(authors).joined(separator: ", "), provider: provider, itemID: id)
        await operation.run(work: { try await $0.searchBookMetadata(query) }, apply: { self.metadataResults = $0 })
    }
    func previewMetadata(_ match: MetadataSearchBook) {
        title = match.title ?? title; subtitle = match.subtitle ?? subtitle; authors = match.author ?? authors; narrators = match.narrator ?? narrators
        description = match.description ?? description; publisher = match.publisher ?? publisher; publishedYear = match.publishedYear ?? publishedYear
        isbn = match.isbn ?? isbn; asin = match.asin ?? asin; language = match.language ?? language; genres = match.genres?.joined(separator: "\n") ?? genres
        if let series = match.series { self.series = series.map { .init(name: $0.series, sequence: $0.sequence ?? "") } }
        if let tags = match.tags { self.tags = tags.joined(separator: "\n") }
        if let explicit = match.explicit { self.explicit = explicit }
        if let abridged = match.abridged { self.abridged = abridged }
        if let cover = match.cover ?? match.covers?.first { coverURL = cover }
        operation.notice = L10n.tr("已载入候选信息，检查后点击保存。")
    }
    func quickMatch() async {
        guard let item else { return }
        var options = MatchItemOptions(); options.provider = provider; options.title = title; options.author = lines(authors).joined(separator: ", "); options.asin = asin.isEmpty ? nil : asin; options.isbn = isbn.isEmpty ? nil : isbn; options.overrideCover = overrideCover; options.overrideDetails = overrideDetails
        let payload = options
        await operation.run(.updateContent, work: { try await $0.matchItem(id: item.id, options: payload) }, apply: { result in
            if let full = result.libraryItem { self.fill(full) }
            if let error = result.error { self.operation.error = error } else { self.operation.notice = result.warning ?? (result.updated == true ? L10n.tr("匹配信息已更新。") : L10n.tr("匹配完成，没有需要更新的字段。")) }
        })
    }
    func searchCovers() async {
        let title = title, author = lines(authors).joined(separator: ", "), provider = coverProvider, podcast = item?.mediaType == "podcast"
        await operation.run(work: { try await $0.searchCovers(title: title, author: author, provider: provider, podcast: podcast) }, apply: { self.coverResults = $0 })
    }
    func setCover(url: String? = nil) async {
        guard let id = item?.id else { return }
        let url = url ?? coverURL
        await operation.run(.updateContent, requiring: [.upload], work: { try await $0.setItemCover(id: id, remoteURL: url) }, apply: { _ in self.operation.notice = L10n.tr("封面已更新。") })
    }
    func selectCover() async {
        guard let id = item?.id else { return }; let path = serverCoverPath
        await operation.run(.updateContent, work: { try await $0.selectItemCover(id: id, serverPath: path) }, apply: { _ in self.operation.notice = L10n.tr("封面已更新。") })
    }
    func uploadCover(_ url: URL) async {
        guard let id = item?.id else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = AdminUploadFile(localURL: url, mimeType: "image/" + (url.pathExtension.lowercased() == "jpg" ? "jpeg" : url.pathExtension.lowercased()))
        await operation.run(.updateContent, requiring: [.upload], work: { try await $0.uploadItemCover(id: id, file: file) }, apply: { _ in self.operation.notice = L10n.tr("封面图片已上传。") })
    }
    func deleteCover() async {
        guard let id = item?.id else { return }
        await operation.run(.deleteContent, work: { try await $0.deleteItemCover(id: id) }, apply: { self.operation.notice = L10n.tr("封面已移除。") })
    }
    func moveTrack(_ index: Int, by delta: Int) { let next = index + delta; guard orderedFiles.indices.contains(index), orderedFiles.indices.contains(next) else { return }; orderedFiles.swapAt(index, next) }
    func saveTracks() async {
        guard let id = item?.id else { return }; let files = orderedFiles
        await operation.run(.updateContent, work: { try await $0.updateAudioTrackOrder(itemID: id, files: files) }, apply: { self.fill($0); self.operation.notice = L10n.tr("音轨顺序已保存。") })
    }
    func saveChapters() async {
        guard let id = item?.id else { return }
        guard chapters.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }), zip(chapters, chapters.dropFirst()).allSatisfy({ $0.0.start <= $0.1.start }) else { operation.error = L10n.tr("章节起止时间必须有效，并按开始时间升序排列。"); return }
        let chapters = chapters.enumerated().map { Chapter(id: $0.offset, title: $0.element.title, start: $0.element.start, end: $0.element.end) }
        await operation.run(.updateContent, work: { try await $0.updateChapters(itemID: id, chapters: chapters) }, apply: { _ in self.operation.notice = L10n.tr("章节已保存。") })
    }
    func findChapters() async {
        let asin = asin
        await operation.run(work: { try await $0.searchChapters(asin: asin) }, apply: { result in
            if let error = result.error { self.operation.error = error; return }
            self.chapters = (result.chapters ?? []).map { chapter in let start = chapter.startOffsetSec ?? (chapter.startOffsetMs ?? 0) / 1000; return ChapterDraft(title: chapter.title, start: start, end: start + (chapter.lengthMs ?? 0) / 1000) }
            self.operation.notice = L10n.tr("已载入候选章节，检查后点击保存。")
        })
    }
    func scan() async {
        guard let id = item?.id else { return }
        await operation.run(.updateContent, requiring: [.manageServer], work: { try await $0.scanItem(id: id) }, apply: { self.operation.notice = L10n.format("扫描结果：%1$@", String(describing: $0.result)) })
    }
    func inspectEmbedded() async {
        guard let id = item?.id else { return }
        await operation.run(work: { try await $0.embeddedMetadata(itemID: id) }, apply: { self.diagnostic = ManagementOperation.diagnostic($0) })
    }
    func probe(_ file: MediaFile) async {
        guard let id = item?.id else { return }
        await operation.run(.manageServer, work: { try await $0.probeMediaFile(itemID: id, fileID: file.ino) }, apply: { self.diagnostic = ManagementOperation.diagnostic($0) })
    }
    func deleteFile(_ file: MediaFile) async {
        guard let id = item?.id else { return }
        await operation.run(.deleteContent, work: { try await $0.deleteMediaFile(itemID: id, fileID: file.ino); return try await $0.item(id: id) }, apply: { self.fill($0); self.operation.notice = L10n.tr("服务器文件已删除。") })
    }
    func deleteLibraryFile(_ file: ManagedLibraryFile) async {
        guard let id = item?.id else { return }
        await operation.run(.deleteContent, work: { client in
            try await client.deleteMediaFile(itemID: id, fileID: file.ino)
            return try await (client.item(id: id), client.managedItemFiles(id: id))
        }, apply: { full, files in self.fill(full); self.libraryFiles = files; self.operation.notice = L10n.tr("服务器文件已删除。") })
    }
    func toggleEBook(_ file: ManagedLibraryFile) async {
        guard let id = item?.id, file.isEBook else { return }
        await operation.run(.updateContent, work: { client in
            let fresh = try await client.managedItemFiles(id: id)
            guard let current = fresh.first(where: { $0.ino == file.ino }), current.isSupplementary == file.isSupplementary else {
                throw ContentManagementError.fileStatusChanged
            }
            try Task.checkCancellation()
            try await client.toggleEBookSupplementary(itemID: id, fileID: file.ino)
            return try await (client.item(id: id), client.managedItemFiles(id: id))
        }, apply: { full, files in self.fill(full); self.libraryFiles = files; self.operation.notice = L10n.tr("电子书主辅状态已更新。") })
    }
    func encodeM4B(cancel: Bool = false) async {
        guard let id = item?.id else { return }
        var options = M4BEncodeOptions(); options.codec = codec; options.channels = channels; options.bitrate = bitrate; let payload = options
        await operation.run(.manageServer, work: { client in if cancel { try await client.cancelM4BEncoding(itemID: id) } else { try await client.encodeM4B(itemID: id, options: payload) } }, apply: { self.operation.notice = cancel ? L10n.tr("已请求取消 M4B 编码。") : L10n.tr("已将 M4B 编码任务交给服务器。") })
    }
    func embed() async {
        guard let id = item?.id else { return }; let force = forceChapters, backup = backupOriginals
        await operation.run(.manageServer, work: { try await $0.embedItemMetadata(itemID: id, forceChapters: force, backup: backup) }, apply: { self.operation.notice = L10n.tr("已将嵌入元数据任务交给服务器。") })
    }
    func deleteItem() async -> Bool {
        guard let id = item?.id else { return false }; let hard = deleteOriginalFiles
        var deleted = false
        await operation.run(.deleteContent, work: { try await $0.deleteItem(id: id, deleteFiles: hard) }, apply: { deleted = true; self.operation.notice = L10n.tr("内容已删除。") })
        return deleted
    }
}

private enum ContentManagementError: Error, LocalizedError {
    case fileStatusChanged
    var errorDescription: String? { L10n.tr("该文件已被其他设备修改，请刷新后重新选择。") }
}
