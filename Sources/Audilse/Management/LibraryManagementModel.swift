import Foundation
import Observation
import AudilseCore

struct ManagedFolderRow: Identifiable {
    let id = UUID()
    var serverID: String?
    var path: String
}
struct MetadataSourceRow: Identifiable {
    let id: String
    var included: Bool
    var label: String {
        switch id {
        case "folderStructure": L10n.tr("文件夹结构")
        case "audioMetatags": L10n.tr("音频标签或电子书元数据")
        case "nfoFile": L10n.tr("NFO 文件")
        case "txtFiles": "desc.txt / reader.txt"
        case "opfFile": L10n.tr("OPF 文件")
        case "absMetadata": L10n.tr("Audiobookshelf 元数据")
        default: id
        }
    }
}

struct LibraryCreationRequest: Identifiable {
    let id = UUID()
    let draft: LibraryDraft
    let sourceID: UUID
}

@MainActor @Observable final class LibraryManagementModel {
    let operation = ManagementOperation()
    var library: AdminLibrary?
    var name = ""
    var icon = "database"
    var provider = "google"
    var providers: [MetadataProvider] = []
    var folders: [ManagedFolderRow] = []
    var newFolderPath = ""
    var directoryPath = ""
    var directories: [ServerDirectory] = []
    var squareCovers = true
    var enableWatcher = true
    var skipASIN = false
    var skipISBN = false
    var audiobooksOnly = false
    var hideSingleSeries = false
    var laterBooksOnly = false
    var allowEpubScripts = false
    var podcastRegion = "us"
    var autoScanCron = ""
    var finishMode = "time"
    var finishValue = 10.0
    var metadataSources: [MetadataSourceRow] = []
    var uploadURLs: [URL] = []
    var uploadFolderID = ""
    var uploadTitle = ""
    var uploadAuthor = ""
    var uploadSeries = ""
    var uploadProgress: LibraryUploadProgress?
    var uploadIsActive = false
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var uploadAttempt: UUID?
    var page: ItemPage?
    var items: [AudilseCore.LibraryItem] = []
    var selectedIDs: Set<String> = []
    var issuesOnly = false
    var batchTagsEnabled = false
    var batchTags = ""
    var batchGenresEnabled = false
    var batchGenres = ""
    var batchNarratorsEnabled = false
    var batchNarrators = ""
    var batchPublisherEnabled = false
    var batchPublisher = ""
    var batchLanguageEnabled = false
    var batchLanguage = ""
    var batchExplicitEnabled = false
    var batchExplicit = false
    var batchAuthorsEnabled = false
    var batchAuthors = ""
    var batchSeriesEnabled = false
    var batchSeries: [SeriesDraft] = []
    var batchSubtitleEnabled = false
    var batchSubtitle = ""
    var batchPublishedYearEnabled = false
    var batchPublishedYear = ""
    var batchPublishedDateEnabled = false
    var batchPublishedDate = ""
    var batchDescriptionEnabled = false
    var batchDescription = ""
    var batchISBNEnabled = false
    var batchISBN = ""
    var batchASINEnabled = false
    var batchASIN = ""
    var batchAbridgedEnabled = false
    var batchAbridged = false
    var batchAppend = true
    var batchDeleteFiles = false
    var forceChapters = false
    var backupOriginals = true
    var createName = ""
    var createType = "book"
    var createPath = ""
    var libraryOrder: [AdminLibrary] = []
    private(set) var creationNotice: String?
    @ObservationIgnored private var consumedCreationRequests: Set<UUID> = []
    private var libraryID = ""
    private let sourceIDs = ["folderStructure", "audioMetatags", "nfoFile", "txtFiles", "opfFile", "absMetadata"]

    func open(store: AppStore, library: Library) async {
        operation.bind(store); libraryID = library.id; name = library.name
        await reload()
    }
    func openOrganization(store: AppStore) async {
        operation.bind(store); libraryID = ""; library = nil; name = ""
        await loadOrder()
    }
    func cancel() { uploadTask?.cancel(); uploadTask = nil; uploadAttempt = nil; uploadIsActive = false; uploadProgress = nil; operation.cancel() }
    func reload() async {
        guard !libraryID.isEmpty else { await loadOrder(); return }
        let id = libraryID
        await operation.run(work: { client in
            async let full = client.managedLibrary(id: id)
            async let catalog = client.metadataProviders()
            return try await (full, catalog)
        }, apply: { full, catalog in
            self.fill(full); self.providers = full.mediaType == "podcast" ? catalog.podcasts : catalog.books
        })
    }
    private func fill(_ library: AdminLibrary) {
        self.library = library; name = library.name; icon = library.icon ?? "database"; provider = library.provider ?? "google"
        folders = library.folders.map { .init(serverID: $0.id, path: $0.fullPath) }
        let settings = library.settings ?? .init()
        squareCovers = (settings.coverAspectRatio ?? 1) == 1; enableWatcher = !(settings.disableWatcher ?? false)
        skipASIN = settings.skipMatchingMediaWithAsin ?? false; skipISBN = settings.skipMatchingMediaWithIsbn ?? false
        audiobooksOnly = settings.audiobooksOnly ?? false; hideSingleSeries = settings.hideSingleBookSeries ?? false
        laterBooksOnly = settings.onlyShowLaterBooksInContinueSeries ?? false; allowEpubScripts = settings.epubsAllowScriptedContent ?? false
        podcastRegion = settings.podcastSearchRegion ?? "us"; autoScanCron = settings.autoScanCronExpression ?? ""
        if let percent = settings.markAsFinishedPercentComplete, percent > 0 { finishMode = "percent"; finishValue = percent }
        else { finishMode = "time"; finishValue = settings.markAsFinishedTimeRemaining ?? 10 }
        let precedence = settings.metadataPrecedence ?? sourceIDs
        metadataSources = precedence.reversed().map { .init(id: $0, included: true) }
        metadataSources += sourceIDs.filter { !precedence.contains($0) }.map { .init(id: $0, included: false) }
        if !library.folders.contains(where: { $0.id == uploadFolderID }) { uploadFolderID = library.folders.first?.id ?? "" }
    }
    func browseDirectories(path: String? = nil) async {
        let path = path ?? directoryPath
        await operation.run(.manageLibraries, work: { try await $0.serverDirectories(path: path.isEmpty ? nil : path) }, apply: { self.directories = $0.directories; self.directoryPath = path })
    }
    func parentDirectory() async {
        let path = directoryPath.replacingOccurrences(of: "\\", with: "/")
        let parent = (path as NSString).deletingLastPathComponent
        await browseDirectories(path: parent == path ? "" : parent)
    }
    func addFolder() {
        let path = newFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validServerPath(path) else { operation.error = L10n.tr("请输入有效的服务器绝对目录路径，且不要包含 . 或 .. 路径段。"); return }
        guard !folders.contains(where: { $0.path == path }) else { operation.error = L10n.tr("这个目录已经在书库中。"); return }
        folders.append(.init(serverID: nil, path: path)); newFolderPath = ""
    }
    static func validServerPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let absolute = normalized.hasPrefix("/") || (normalized.count > 2 && normalized.dropFirst().hasPrefix(":/"))
        return absolute && !normalized.contains("\u{0}") && !normalized.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    var removedFolderCount: Int { guard let library else { return 0 }; return library.folders.filter { old in !folders.contains { $0.serverID == old.id } }.count }
    func moveSource(_ index: Int, by delta: Int) {
        let next = index + delta
        guard metadataSources.indices.contains(index), metadataSources.indices.contains(next) else { return }
        metadataSources.swapAt(index, next)
    }
    func resetSources() { metadataSources = sourceIDs.reversed().map { .init(id: $0, included: true) } }
    func save() async {
        guard let old = library, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !folders.isEmpty else { operation.error = L10n.tr("书库需要名称和至少一个服务器目录。"); return }
        guard finishValue.isFinite, finishValue >= 0, finishMode != "percent" || finishValue <= 100 else { operation.error = L10n.tr("完成阈值必须为有效的非负数，百分比不能超过 100。"); return }
        let folderPayload = folders.map { LibraryFolderDraft(id: $0.serverID, fullPath: $0.path) }
        var update = LibraryUpdate()
        if name != old.name { update.name = name }
        if icon != old.icon ?? "database" { update.icon = icon }
        if provider != old.provider ?? "google" { update.provider = provider }
        if folderPayload != old.folders { update.folders = folderPayload }
        let prior = old.settings ?? .init()
        var settings = LibrarySettingsUpdate()
        if squareCovers != ((prior.coverAspectRatio ?? 1) == 1) { settings.coverAspectRatio = squareCovers ? 1 : 0 }
        if enableWatcher != !(prior.disableWatcher ?? false) { settings.disableWatcher = !enableWatcher }
        if autoScanCron != prior.autoScanCronExpression ?? "" {
            if autoScanCron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.clearAutoScanCronExpression = true }
            else { settings.autoScanCronExpression = autoScanCron }
        }
        if old.mediaType == "book" {
            if skipASIN != prior.skipMatchingMediaWithAsin ?? false { settings.skipMatchingMediaWithAsin = skipASIN }
            if skipISBN != prior.skipMatchingMediaWithIsbn ?? false { settings.skipMatchingMediaWithIsbn = skipISBN }
            if audiobooksOnly != prior.audiobooksOnly ?? false { settings.audiobooksOnly = audiobooksOnly }
            if hideSingleSeries != prior.hideSingleBookSeries ?? false { settings.hideSingleBookSeries = hideSingleSeries }
            if laterBooksOnly != prior.onlyShowLaterBooksInContinueSeries ?? false { settings.onlyShowLaterBooksInContinueSeries = laterBooksOnly }
            if allowEpubScripts != prior.epubsAllowScriptedContent ?? false { settings.epubsAllowScriptedContent = allowEpubScripts }
            let precedence = metadataSources.filter(\.included).map(\.id).reversed()
            if Array(precedence) != prior.metadataPrecedence ?? sourceIDs { settings.metadataPrecedence = Array(precedence) }
        } else if podcastRegion != prior.podcastSearchRegion ?? "us" { settings.podcastSearchRegion = podcastRegion }
        let oldMode = (prior.markAsFinishedPercentComplete ?? 0) > 0 ? "percent" : "time"
        let oldValue = oldMode == "percent" ? (prior.markAsFinishedPercentComplete ?? 0) : (prior.markAsFinishedTimeRemaining ?? 10)
        if finishMode != oldMode || finishValue != oldValue {
            if finishMode == "time" { settings.markAsFinishedTimeRemaining = finishValue; settings.clearMarkAsFinishedPercentComplete = true }
            else { settings.markAsFinishedPercentComplete = finishValue; settings.clearMarkAsFinishedTimeRemaining = true }
        }
        update.settings = settings
        let payload = update
        await operation.run(.manageLibraries, work: { try await $0.updateLibrary(id: old.id, update: payload) }, apply: { self.fill($0); self.operation.notice = L10n.tr("书库设置已保存。") })
    }
    func scan(force: Bool = false) async {
        let id = libraryID
        await operation.run(.manageLibraries, work: { try await $0.scanLibrary(id: id, force: force) }, apply: { self.operation.notice = L10n.tr("服务器已接受书库扫描任务。") })
    }
    func matchAll() async {
        let id = libraryID
        await operation.run(.manageLibraries, work: { try await $0.matchLibrary(id: id) }, apply: { self.operation.notice = L10n.tr("服务器已接受全书库匹配任务。") })
    }
    func removeIssues() async {
        let id = libraryID
        await operation.run(.manageLibraries, work: { try await $0.removeLibraryItemsWithIssues(id: id) }, apply: { self.operation.notice = L10n.tr("缺失或无效的书库记录已移除，原文件保留。"); self.items = []; self.selectedIDs = []; self.page = nil })
    }
    func removeMetadataFiles(kind: LibraryMetadataFileKind = .json) async {
        let id = libraryID
        await operation.run(.manageLibraries, work: { try await $0.removeLibraryMetadataFiles(id: id, kind: kind) }, apply: { self.operation.notice = L10n.format("找到 %1$@ 个 %2$@，已删除 %3$@ 个。", String(describing: $0.found), String(describing: kind.filename), String(describing: $0.removed ?? 0)) })
    }
    func deleteLibrary() async -> Bool {
        let id = libraryID
        var removed = false
        await operation.run(.manageLibraries, work: { try await $0.deleteLibrary(id: id) }, apply: { _ in removed = true })
        return removed
    }
    func startUpload() {
        guard uploadTask == nil, !operation.isBusy else { return }
        let attempt = UUID()
        uploadAttempt = attempt; uploadIsActive = true; uploadProgress = nil
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.upload(attempt: attempt)
            guard self.uploadAttempt == attempt else { return }
            self.uploadTask = nil; self.uploadAttempt = nil; self.uploadIsActive = false
        }
    }
    func cancelUpload() {
        uploadTask?.cancel()
        operation.notice = L10n.tr("已请求取消传输。若服务器已收到完整文件，仍可能完成入库；请刷新书库确认。")
    }
    private func upload(attempt: UUID) async {
        guard let library, library.folders.contains(where: { $0.id == uploadFolderID }), !uploadURLs.isEmpty, !uploadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { operation.error = L10n.tr("请选择文件、目标目录，并填写内容标题。"); return }
        let urls = uploadURLs
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let files = urls.map { AdminUploadFile(localURL: $0) }
        let details = LibraryUploadDetails(libraryID: library.id, folderID: uploadFolderID, title: uploadTitle, author: uploadAuthor.isEmpty ? nil : uploadAuthor, series: uploadSeries.isEmpty ? nil : uploadSeries)
        let report: @Sendable (LibraryUploadProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor [self] in
                guard self.uploadAttempt == attempt else { return }
                self.uploadProgress = progress
            }
        }
        await operation.run(.upload, work: { client in
            try await client.uploadLibraryFiles(files, details: details, progress: report)
        }, apply: { self.uploadURLs = []; self.operation.notice = L10n.tr("文件已上传。若书库未显示新内容，请在“扫描与清理”中选择“扫描整个书库”，完成后刷新书库。") })
    }
    func loadItems(more: Bool = false) async {
        let id = libraryID, issues = issuesOnly
        let next = more ? (page?.page ?? -1) + 1 : 0
        await operation.run(work: { client in
            if issues { return try await client.libraryItemsWithIssues(id: id, page: next, limit: 60) }
            return try await client.libraryItems(libraryID: id, page: next, limit: 60)
        }, apply: { page in
            if more { let known = Set(self.items.map(\.id)); self.items += page.results.filter { !known.contains($0.id) } }
            else { self.items = page.results; self.selectedIDs = [] }
            self.page = page
        })
    }
    func selectLoaded() { selectedIDs.formUnion(items.map(\.id)) }
    func toggleSelection(_ id: String) { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
    private func lines(_ value: String) -> [String] { value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    func saveBatch() async {
        guard !selectedIDs.isEmpty else { return }
        var edits = BatchMetadataEdits()
        if batchTagsEnabled { edits.tags = lines(batchTags) }
        if batchGenresEnabled { edits.genres = lines(batchGenres) }
        if batchNarratorsEnabled { edits.narrators = lines(batchNarrators) }
        if batchPublisherEnabled { edits.publisher = batchPublisher }
        if batchLanguageEnabled { edits.language = batchLanguage }
        if batchExplicitEnabled { edits.explicit = batchExplicit }
        if batchAuthorsEnabled { edits.authors = lines(batchAuthors) }
        if batchSeriesEnabled {
            let names = batchSeries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard !names.contains(""), Set(names).count == names.count else { operation.error = L10n.tr("批量系列名称不能为空或重复。"); return }
            edits.series = batchSeries.map { .init(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), sequence: $0.sequence.isEmpty ? nil : $0.sequence) }
        }
        if batchSubtitleEnabled { edits.subtitle = batchSubtitle }
        if batchPublishedYearEnabled { edits.publishedYear = batchPublishedYear }
        if batchPublishedDateEnabled { edits.publishedDate = batchPublishedDate }
        if batchDescriptionEnabled { edits.description = batchDescription }
        if batchISBNEnabled { edits.isbn = batchISBN }
        if batchASINEnabled { edits.asin = batchASIN }
        if batchAbridgedEnabled { edits.abridged = batchAbridged }
        guard !edits.isEmpty else { operation.error = L10n.tr("先启用需要批量修改的字段。"); return }
        let changes = edits, ids = Array(selectedIDs).sorted(), append = batchAppend
        await operation.run(.updateContent, work: { client in
            let fresh = try await client.batchItems(ids: ids)
            try Task.checkCancellation()
            return try await client.batchUpdateItemMedia(fresh.map { changes.applying(to: $0, appendLists: append) })
        }, apply: { self.operation.notice = L10n.format("批量保存完成，服务器更新了 %1$@ 项。", String(describing: $0.updates)) })
    }
    func scanSelected() async { let ids = Array(selectedIDs).sorted(); guard !ids.isEmpty else { return }; await operation.run(.manageServer, work: { try await $0.scanItems(ids: ids) }, apply: { self.operation.notice = L10n.format("已请求扫描 %1$@ 项内容。", String(describing: ids.count)) }) }
    func matchSelected() async { let ids = Array(selectedIDs).sorted(); guard !ids.isEmpty else { return }; await operation.run(.manageServer, work: { try await $0.matchItems(ids: ids, options: .init()) }, apply: { self.operation.notice = L10n.format("已请求匹配 %1$@ 项内容。", String(describing: ids.count)) }) }
    func embedSelected() async {
        let ids = Array(selectedIDs).sorted(), force = forceChapters, backup = backupOriginals
        guard !ids.isEmpty else { return }
        await operation.run(.manageServer, work: { try await $0.embedItemsMetadata(ids: ids, forceChapters: force, backup: backup) }, apply: { self.operation.notice = L10n.format("已请求向 %1$@ 项内容的原文件写入元数据。", String(describing: ids.count)) })
    }
    func deleteSelected() async {
        let ids = Array(selectedIDs).sorted(), hard = batchDeleteFiles
        guard !ids.isEmpty else { return }
        await operation.run(.deleteContent, work: { try await $0.deleteItems(ids: ids, deleteFiles: hard) }, apply: { self.items.removeAll { ids.contains($0.id) }; self.selectedIDs = []; self.page = nil; self.operation.notice = L10n.format("已删除 %1$@ 项内容。", String(describing: ids.count)) })
    }
    var isCreationDraftValid: Bool {
        !createName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.validServerPath(createPath.trimmingCharacters(in: .whitespacesAndNewlines))
            && ["book", "podcast"].contains(createType)
    }
    func prepareLibraryCreation() -> LibraryCreationRequest? {
        guard !operation.isBusy, operation.allows(.manageLibraries), let sourceID = operation.sourceID else { return nil }
        guard isCreationDraftValid else { operation.error = L10n.tr("新书库需要名称与有效的服务器绝对目录。"); return nil }
        let draft = LibraryDraft(name: createName.trimmingCharacters(in: .whitespacesAndNewlines),
                                 folders: [.init(fullPath: createPath.trimmingCharacters(in: .whitespacesAndNewlines))],
                                 mediaType: createType, provider: createType == "podcast" ? "itunes" : "google")
        return .init(draft: draft, sourceID: sourceID)
    }
    @discardableResult func createLibrary(_ request: LibraryCreationRequest) async -> Bool {
        guard !Task.isCancelled, !operation.isBusy, operation.sourceID == request.sourceID,
              operation.allows(.manageLibraries), !consumedCreationRequests.contains(request.id) else { return false }
        // Consume before crossing an await. Confirmation cannot repeat an uncertain POST.
        consumedCreationRequests.insert(request.id)
        var created = false
        await operation.run(.manageLibraries, expectedSource: request.sourceID, work: { try await $0.createLibrary(request.draft) }, apply: { library in
            created = true
            self.libraryOrder.removeAll { $0.id == library.id }
            self.libraryOrder.append(library)
            self.creationNotice = L10n.format("已创建书库“%1$@”。", library.name)
            if self.createName.trimmingCharacters(in: .whitespacesAndNewlines) == request.draft.name,
               self.createPath.trimmingCharacters(in: .whitespacesAndNewlines) == request.draft.folders.first?.fullPath,
               self.createType == request.draft.mediaType {
                self.createName = ""; self.createPath = ""
            }
        })
        // A separate read may fail. Preserve the confirmed result and never replay the write.
        if created, operation.sourceID == request.sourceID { await loadOrder() }
        return created
    }
    func loadOrder() async {
        await operation.run(.manageLibraries, work: { client in
            var result: [AdminLibrary] = []
            for library in try await client.libraries() { try Task.checkCancellation(); result.append(try await client.managedLibrary(id: library.id)) }
            return result.sorted { ($0.displayOrder ?? 0) < ($1.displayOrder ?? 0) }
        }, apply: { self.libraryOrder = $0 })
    }
    func moveLibrary(_ index: Int, by delta: Int) { let next = index + delta; guard libraryOrder.indices.contains(index), libraryOrder.indices.contains(next) else { return }; libraryOrder.swapAt(index, next) }
    func saveOrder() async {
        let order = libraryOrder.enumerated().map { LibraryOrderEntry(id: $0.element.id, newOrder: $0.offset + 1) }
        guard !order.isEmpty else { return }
        await operation.run(.manageLibraries, work: { try await $0.reorderLibraries(order) }, apply: { self.libraryOrder = $0.sorted { ($0.displayOrder ?? 0) < ($1.displayOrder ?? 0) }; self.operation.notice = L10n.tr("书库顺序已保存。") })
    }
}
