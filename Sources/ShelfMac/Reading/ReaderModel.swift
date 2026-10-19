import AppKit
import Foundation
import Observation
import PDFKit
import ShelfCore
import WebKit

struct ReaderEntry: Identifiable, Hashable {
    let id: String
    let title: String
    var depth = 0
}

enum ReaderShutdownError: Error, LocalizedError {
    case checkpointFailed(String)
    var errorDescription: String? { if case let .checkpointFailed(message) = self { message } else { nil } }
}

@MainActor @Observable final class ReaderModel {
    var title = ""
    var format: EbookFormat?
    var fileURL: URL?
    var pdfDocument: PDFDocument?
    var comicPages: [URL] = []
    var page = 1
    var pageCount = 0
    var location = ""
    var progress = 0.0
    var toc: [ReaderEntry] = []
    var searchResults: [ReaderEntry] = []
    private(set) var hasSearched = false
    var search = ""
    var showContents = false
    var isLoading = true
    var isCalculatingProgress = false
    var isSearching = false
    var isClosing = false
    private(set) var isClosed = false
    var closeError: String?
    private(set) var comicScale = 1.0
    var error: String?
    var syncNotice: String?
    var conflict: ReadingConflict?
    var fontSize = UserDefaults.standard.integer(forKey: "reader.fontSize") == 0 ? 20 : UserDefaults.standard.integer(forKey: "reader.fontSize")
    var fontFamily = UserDefaults.standard.string(forKey: "reader.fontFamily") ?? "serif"
    var theme = UserDefaults.standard.string(forKey: "reader.theme") ?? "paper"
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored weak var pdfView: PDFView?
    @ObservationIgnored private var repository: ReadingRepository?
    @ObservationIgnored private var partition: AccountPartition?
    @ObservationIgnored private var client: ABSClient?
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var sourceClientID: ObjectIdentifier?
    @ObservationIgnored private var sourceAccountOperationID: UUID?
    @ObservationIgnored private var sourceActivityID: UUID?
    @ObservationIgnored private var fileIno: String?
    @ObservationIgnored private var itemID = ""
    @ObservationIgnored private var baseline: MediaProgress?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    // canSearch must update when the task finishes after its result message.
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Bool, Never>?
    @ObservationIgnored private var closeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var closeSynchronizationAllowed = true

    func open(store: AppStore, item: ShelfCore.LibraryItem, fileIno: String? = nil) async {
        guard itemID.isEmpty else { return }
        title = item.title
        itemID = item.id
        let attempt = epoch
        guard let partition = store.partition else { isLoading = false; error = L10n.tr("请先连接服务器。"); return }
        self.partition = partition
        self.store = store
        self.sourceClientID = store.client.map(ObjectIdentifier.init)
        self.sourceAccountOperationID = store.accountOperationID
        self.sourceActivityID = store.readingActivityID
        self.fileIno = fileIno
        self.client = store.isOffline ? nil : store.client
        baseline = fileIno == nil ? store.progressByItem[item.id] : nil
        do {
            guard let repository = store.readingRepository else { throw ReadingError.invalidDownload }
            self.repository = repository
            let (descriptor, url) = try await repository.original(item: item, fileIno: fileIno, partition: partition, client: client)
            guard isCurrent(attempt) else { return }
            if fileIno != nil { title = descriptor.filename }
            format = descriptor.format
            if descriptor.format == .epub {
                try await EbookArchiveInspector().validateEPUB(source: url)
                guard isCurrent(attempt) else { return }
            }
            let saved: ReadingCheckpoint?
            if let fileIno { saved = try await repository.position(itemID: item.id, fileIno: fileIno, partition: partition) }
            else { saved = try await repository.position(itemID: item.id, partition: partition) }
            guard isCurrent(attempt) else { return }
            if fileIno == nil, let client, let remote = try? await client.progress(itemID: item.id) {
                guard isCurrent(attempt) else { return }
                baseline = remote
            }
            // A queued local position takes precedence until its explicit conflict is resolved.
            let pending = fileIno == nil ? try await repository.pending(partition: partition).contains { $0.itemID == item.id } : false
            guard isCurrent(attempt) else { return }
            // MOBI/KF8 positions never synchronize with ABS. Its shared lastUpdate
            // can advance from audio alone, and its ebook fields may refer to a
            // previously selected format. Restore location and progress as a pair.
            if fileIno != nil || !descriptor.format.supportsServerProgress {
                location = saved?.location ?? ""
                progress = saved?.progress ?? 0
            } else if let saved, pending || saved.updatedAt >= (baseline?.lastUpdate ?? 0) {
                location = saved.location
                progress = saved.progress
            } else if let remoteLocation = baseline?.ebookLocation, !remoteLocation.isEmpty {
                location = remoteLocation
                progress = baseline?.ebookProgress ?? 0
            } else {
                location = saved?.location ?? ""
                progress = saved?.progress ?? 0
            }
            if let saved, pending {
                baseline = MediaProgress(libraryItemId: item.id, lastUpdate: saved.baselineUpdatedAt, ebookLocation: saved.baselineLocation, ebookProgress: saved.baselineProgress)
            }
            fileURL = url
            if descriptor.format == .pdf {
                guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw ReadingError.invalidDownload }
                pdfDocument = document; pageCount = document.pageCount; page = clampedPage(location)
                toc = (0..<document.pageCount).map { ReaderEntry(id: String($0 + 1), title: L10n.format("第 %1$@ 页", String(describing: $0 + 1))) }
                isLoading = false
            } else if descriptor.format.isComic {
                let output = url.deletingPathExtension().appendingPathExtension("pages")
                comicPages = try await ComicArchive().extract(source: url, destination: output)
                guard isCurrent(attempt) else { return }
                pageCount = comicPages.count; page = clampedPage(location)
                toc = comicPages.enumerated().map { ReaderEntry(id: String($0.offset + 1), title: $0.element.lastPathComponent) }
                isLoading = false
            }
            if fileIno != nil { syncNotice = L10n.tr("此文件的阅读位置仅保存在本机。") }
        } catch { if isCurrent(attempt) { self.error = L10n.error(error); isLoading = false } }
    }

    private func isCurrent(_ attempt: UUID) -> Bool {
        guard epoch == attempt, let store, store.partition == partition,
              store.accountOperationID == sourceAccountOperationID,
              repository == nil || store.readingRepository === repository,
              store.client.map(ObjectIdentifier.init) == sourceClientID else { return false }
        return true
    }

    var canSearch: Bool {
        guard !isLoading, !isClosing, !isClosed, !isSearching, searchTask == nil,
              error == nil, isCurrent(epoch), let format else { return false }
        if format == .pdf { return pdfDocument != nil }
        if format.isComic { return true }
        return webView != nil
    }

    var canZoomComicOut: Bool { comicScale > 0.5 }
    var canZoomComicIn: Bool { comicScale < 3 }
    func setComicScale(_ scale: Double) {
        guard format?.isComic == true, scale.isFinite, !isClosed, !isClosing else { return }
        comicScale = min(3, max(0.5, scale))
    }
    func zoomComic(by step: Double) { setComicScale((comicScale * 10 + step * 10).rounded() / 10) }

    private func clampedPage(_ saved: String) -> Int { min(pageCount, max(1, Int(saved) ?? 1)) }
    func previous() {
        if format == .pdf { pdfView?.goToPreviousPage(nil) }
        else if format?.isComic == true { setPage(page - 1) }
        else { command("previous") }
    }
    func next() {
        if format == .pdf { pdfView?.goToNextPage(nil) }
        else if format?.isComic == true { setPage(page + 1) }
        else { command("next") }
    }
    func setPage(_ newPage: Int) {
        page = min(pageCount, max(1, newPage))
        if format == .pdf, let pdfDocument, let target = pdfDocument.page(at: page - 1) { pdfView?.go(to: target) }
        moved(location: String(page), progress: ReadingCheckpoint.pageProgress(page: page, count: pageCount))
    }
    func go(_ entry: ReaderEntry, searchResult: Bool = false) {
        if format == .pdf || format?.isComic == true { setPage(Int(entry.id) ?? 1) }
        else { command(searchResult ? "searchGo" : "go", argument: entry.id) }
    }
    func settingsChanged() {
        UserDefaults.standard.set(fontSize, forKey: "reader.fontSize")
        UserDefaults.standard.set(fontFamily, forKey: "reader.fontFamily")
        UserDefaults.standard.set(theme, forKey: "reader.theme")
        command("configure", argument: ["fontSize": fontSize, "fontFamily": fontFamily, "theme": theme])
    }
    func find() {
        guard searchTask == nil, !isSearching else { return }
        guard canSearch else { isSearching = false; return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { clearSearch(); return }
        showContents = true
        hasSearched = true
        searchResults = []
        if format == .pdf, let pdfDocument {
            let selections = pdfDocument.findString(query, withOptions: [.caseInsensitive])
            searchResults = selections.prefix(200).compactMap { selection in
                guard let pdfPage = selection.pages.first else { return nil }
                return ReaderEntry(id: String(pdfDocument.index(for: pdfPage) + 1), title: selection.string ?? search)
            }
        } else if format?.isComic == true { searchResults = []; syncNotice = L10n.tr("漫画为图片内容，暂不支持正文搜索。") }
        else if let webView {
            isSearching = true
            let attempt = epoch
            searchTask = Task { [weak self, weak webView] in
                guard let self else { return }
                defer { self.searchTask = nil; self.isSearching = false }
                do {
                    guard let webView else { return }
                    // Await the bridge's Promise as well as its result message. Its
                    // error message must never leave a native spinner running.
                    _ = try await webView.callAsyncJavaScript("await ShelfReader.search(query)", arguments: ["query": query], in: nil, contentWorld: .page)
                } catch {
                    if self.isCurrent(attempt), !Task.isCancelled { self.error = L10n.error(error) }
                }
            }
        }
    }
    func clearSearch() {
        guard !isSearching, searchTask == nil else { return }
        search = ""
        searchResults = []
        hasSearched = false
    }
    func command(_ method: String, argument: Any? = nil) {
        let arguments: String
        if let argument, let data = try? JSONSerialization.data(withJSONObject: [argument], options: [.fragmentsAllowed]), let string = String(data: data, encoding: .utf8) {
            arguments = String(string.dropFirst().dropLast())
        } else { arguments = "" }
        webView?.evaluateJavaScript("void ShelfReader.\(method)(\(arguments))") { [weak self] _, error in
            if let error { Task { @MainActor in self?.error = L10n.error(error) } }
        }
    }
    func moved(location: String, progress: Double) {
        guard !isClosed, !isClosing, isCurrent(epoch), progress.isFinite, !location.isEmpty else { return }
        self.location = location; self.progress = min(1, max(0, progress))
        checkpointTask?.cancel()
        checkpointTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            // Once a checkpoint starts uploading, a later page turn must not cancel
            // an uncertain PATCH and mistake our own completed write for another device.
            self?.checkpointTask = nil
            await self?.savePosition()
        }
    }
    func savePosition(synchronize: Bool = true) async {
        guard let repository, let partition, let format, !location.isEmpty else { return }
        let attempt = epoch
        do {
            try await checkpointCurrentPosition()
        } catch {
            if isCurrent(attempt) { syncNotice = L10n.format("无法保存本机阅读位置：%1$@", L10n.error(error)) }
            return
        }
        do {
            guard epoch == attempt else { return }
            guard synchronize, isCurrent(attempt) else { return }
            if fileIno == nil, format.supportsServerProgress, let client {
                let conflicts = try await repository.synchronize(partition: partition, client: client, authorize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireSynchronizationSource(attempt)
                })
                guard isCurrent(attempt) else { return }
                conflict = conflicts.first { $0.id == itemID }
                if conflict == nil {
                    let remainsPending = try await repository.pending(partition: partition).contains { $0.itemID == itemID }
                    if !remainsPending { baseline = try await client.progress(itemID: itemID); syncNotice = L10n.tr("阅读位置已同步") }
                }
            } else if fileIno != nil { syncNotice = L10n.tr("此文件的阅读位置仅保存在本机。") }
            else { syncNotice = format.supportsServerProgress ? L10n.tr("阅读位置已保存在本机，联网后同步。") : L10n.tr("此格式的位置仅保存在本机。") }
        } catch { if isCurrent(attempt), !Task.isCancelled, !(error is CancellationError) { syncNotice = L10n.format("位置已保留，暂未同步：%1$@", String(describing: L10n.error(error))) } }
    }
    func resolve(useLocal: Bool) async {
        guard fileIno == nil, isCurrent(epoch), let conflict, let repository, let partition, let client else { return }
        let attempt = epoch
        do {
            try await repository.resolve(conflict, useLocal: useLocal, partition: partition, client: client, authorize: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireSynchronizationSource(attempt)
            })
            guard isCurrent(attempt) else { return }
            self.conflict = nil
            baseline = try await client.progress(itemID: itemID)
            guard isCurrent(attempt) else { return }
            if !useLocal, let location = baseline?.ebookLocation {
                self.location = location; progress = baseline?.ebookProgress ?? 0
                if format == .epub { command("go", argument: location) } else { setPage(Int(location) ?? 1) }
            }
        } catch { if isCurrent(attempt), !Task.isCancelled, !(error is CancellationError) { self.error = L10n.error(error) } }
    }
    private func checkpointCurrentPosition() async throws {
        guard let repository, let partition, let format, !location.isEmpty else { return }
        let checkpoint = ReadingCheckpoint(itemID: itemID, format: format, location: location, progress: progress, baselineLocation: baseline?.ebookLocation, baselineProgress: baseline?.ebookProgress, baselineUpdatedAt: baseline?.lastUpdate)
        // This snapshot intentionally belongs to the original account even when
        // shutdown is requested during an account transition.
        if let fileIno { try await repository.checkpoint(checkpoint, fileIno: fileIno, partition: partition) }
        else { try await repository.checkpoint(checkpoint, partition: partition) }
    }

    private func requireSynchronizationSource(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(attempt), let store, !store.isOffline, !store.isDemo, !store.isConnecting,
              store.serverRecovery == nil, !store.recoveryBusy, store.user?.isActive == true,
              store.user?.id == partition?.userID,
              store.readingActivityID == nil || store.readingActivityID == sourceActivityID else { throw CancellationError() }
    }

    private func startCloseSynchronization() {
        guard closeSyncTask == nil, closeSynchronizationAllowed, fileIno == nil,
              format?.supportsServerProgress == true, let repository, let partition, let client else { return }
        let attempt = epoch
        closeSyncTask = Task { [self] in
            defer { closeSyncTask = nil }
            do {
                try requireSynchronizationSource(attempt)
                let conflicts = try await repository.synchronize(partition: partition, client: client, authorize: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireSynchronizationSource(attempt)
                })
                try requireSynchronizationSource(attempt)
                store?.readingConflicts = conflicts
            } catch {
                guard isCurrent(attempt), !Task.isCancelled, !(error is CancellationError) else { return }
                store?.errorMessage = L10n.format("位置已保留，暂未同步：%1$@", L10n.error(error))
            }
        }
    }

    @discardableResult func close(synchronize: Bool = true) async -> Bool {
        if !synchronize { closeSynchronizationAllowed = false; closeSyncTask?.cancel() }
        if let closeTask { return await closeTask.value }
        guard !isClosed else { return true }
        isClosing = true
        closeError = nil
        epoch = UUID()
        checkpointTask?.cancel()
        searchTask?.cancel()
        isSearching = false
        webView?.stopLoading()
        // Keep this local commit alive if the view/caller is cancelled. Remote
        // work is separately cancellable and never delays the close result.
        let task = Task { [self] in
            do {
                try await checkpointCurrentPosition()
                isClosed = true
                isClosing = false
                return true
            } catch {
                closeError = L10n.format("无法保存本机阅读位置：%1$@", L10n.error(error))
                isClosing = false
                return false
            }
        }
        closeTask = task
        let saved = await task.value
        closeTask = nil
        if saved, synchronize, closeSynchronizationAllowed, !Task.isCancelled { startCloseSynchronization() }
        return saved
    }

    func shutdown() async throws {
        guard await close(synchronize: false) else {
            throw ReaderShutdownError.checkpointFailed(closeError ?? L10n.tr("无法保存本机阅读位置。"))
        }
    }
}
