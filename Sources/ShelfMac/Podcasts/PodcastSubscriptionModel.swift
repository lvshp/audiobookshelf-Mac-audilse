import Foundation
import Observation
import ShelfCore

@MainActor @Observable final class PodcastSubscriptionModel {
    var library: Library?
    var folders: [LibraryFolder] = []
    var folderID = ""
    var path = ""
    var rssURL = ""
    var feed: PodcastFeed?
    var podcastType = "episodic"
    var searchTerm = ""
    var searchCountry = "us" { didSet { searchCountryWasChosen = true } }
    var searchResults: [PodcastDirectoryResult] = []
    var existingTitles: [ExistingPodcastTitle] = []
    var selectedDirectoryResult: PodcastDirectoryResult?
    var selectedExistingItem: ShelfCore.LibraryItem?
    @ObservationIgnored private var parsedRSSInput: String?
    @ObservationIgnored private var searchCountryWasChosen = false
    var autoDownload = false
    var schedule = "0 * * * *"
    var opmlText = ""
    var opmlFeeds: [OPMLFeed] = []
    var selectedFeeds: Set<String> = []
    var exportedOPML: Data?
    var isBusy = false
    var error: String?
    var notice: String?
    @ObservationIgnored let account = PodcastAccountSession()
    var folder: LibraryFolder? { folders.first { $0.id == folderID } }

    func open(store: AppStore, library: Library) async {
        guard !Task.isCancelled else { return }
        account.bind(store)
        isBusy = false; error = nil; notice = nil
        self.library = library.mediaType == "podcast" ? library : store.libraries.first { $0.mediaType == "podcast" }
        searchCountry = "us"; searchCountryWasChosen = false
        feed = nil; podcastType = "episodic"; parsedRSSInput = nil; selectedDirectoryResult = nil; selectedExistingItem = nil; searchResults = []; existingTitles = []
        await loadFolders()
    }
    func cancel() { account.cancel(); isBusy = false }
    private func perform<T: Sendable>(admin: Bool = true, operation: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async {
        guard !isBusy else { return }
        let snapshot: (ABSClient, UUID)
        do { snapshot = try account.snapshot(admin: admin) }
        catch { self.error = L10n.error(error); return }
        let (client, attempt) = snapshot
        isBusy = true; error = nil; notice = nil
        defer { if account.isCurrent(attempt) { isBusy = false } }
        do {
            let result = try await account.run(attempt) { try await operation(client) }
            try account.validate(attempt)
            apply(result)
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch { if account.isCurrent(attempt) { self.error = L10n.error(error) } }
    }
    func loadFolders() async {
        guard let library else { error = L10n.tr("请先创建播客书库，再添加订阅。"); return }
        await perform(admin: false, operation: { try await $0.libraryDetails(id: library.id) }, apply: {
            // Inherit once per open. Explicit choices made while the first
            // request is pending, including "us", win over the library default.
            if !self.searchCountryWasChosen {
                let region = $0.settings?.podcastSearchRegion?.lowercased() ?? ""
                self.searchCountry = region.isEmpty ? "us" : region
            }
            let previousFolder = self.folder
            self.folders = $0.folders
            if let currentFolder = self.folder {
                if previousFolder?.fullPath != currentFolder.fullPath { self.updatePath() }
            } else {
                self.folderID = $0.folders.first?.id ?? ""
                self.updatePath()
            }
        })
    }
    func updatePath() {
        guard let folder else { path = ""; return }
        let title = (feed?.metadata.title ?? L10n.tr("新播客")).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-").replacingOccurrences(of: "\0", with: "")
        path = folder.fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if folder.fullPath.hasPrefix("/") { path = "/" + path }
        path += "/" + (title == "." || title == ".." || title.isEmpty ? L10n.tr("新播客") : title)
    }
    func parseRSS() async {
        let url = rssURL.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform(operation: { client in
            do { return try await client.podcastFeed(url: url) }
            catch ABSError.http(status: 404, message: _) { throw PodcastUIError.feedUnavailable }
        }, apply: {
            self.feed = $0; self.parsedRSSInput = url; self.updatePath()
            if self.selectedDirectoryResult?.feedUrl != url { self.selectedDirectoryResult = nil }
            self.podcastType = self.selectedDirectoryResult?.type ?? $0.metadata.type ?? "episodic"
        })
    }
    func searchDirectory() async {
        guard let library else { return }
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines), country = searchCountry.lowercased()
        guard !term.isEmpty else { return }
        await perform(operation: { client in
            async let results = client.searchPodcastDirectory(term: term, country: country)
            async let existing = client.existingPodcasts(libraryID: library.id)
            return try await (results, existing)
        }, apply: { results, existing in self.searchResults = results.filter { !($0.feedUrl ?? "").isEmpty }; self.existingTitles = existing })
    }
    func existingPodcast(_ result: PodcastDirectoryResult) -> ExistingPodcastTitle? {
        existingTitles.first { $0.itunesId == result.id || $0.title.caseInsensitiveCompare(result.title) == .orderedSame }
    }
    func openExistingPodcast(_ result: PodcastDirectoryResult) async {
        guard let existing = existingPodcast(result) else { return }
        await perform(admin: false, operation: { try await $0.item(id: existing.libraryItemId) }, apply: { self.selectedExistingItem = $0 })
    }
    func selectDirectoryResult(_ result: PodcastDirectoryResult) async {
        guard existingPodcast(result) == nil, let url = result.feedUrl else { return }
        selectedDirectoryResult = result; rssURL = url
        await parseRSS()
    }
    func subscribe() async {
        guard let library, let folder else { error = PodcastUIError.invalidPath.localizedDescription; return }
        guard let feed, parsedRSSInput == rssURL.trimmingCharacters(in: .whitespacesAndNewlines) else { error = PodcastUIError.missingFeed.localizedDescription; return }
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = folder.fullPath.hasSuffix("/") ? String(folder.fullPath.dropLast()) : folder.fullPath
        guard clean.hasPrefix(base + "/"), !clean.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), !clean.contains("\0") else { error = PodcastUIError.invalidPath.localizedDescription; return }
        let draft = PodcastSubscriptionDraft(libraryId: library.id, folderId: folder.id, path: clean, metadata: feed.metadata, autoDownloadEpisodes: autoDownload, autoDownloadSchedule: schedule, directoryResult: selectedDirectoryResult, typeOverride: podcastType)
        await perform(operation: { try await $0.createPodcast(draft) }, apply: { self.notice = L10n.format("已订阅「%1$@」。", String(describing: $0.title)); self.feed = nil; self.rssURL = ""; self.parsedRSSInput = nil; self.selectedDirectoryResult = nil; self.searchResults = [] })
    }
    func readOPML(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let snapshot: (ABSClient, UUID)
        do { snapshot = try account.snapshot(admin: true) }
        catch { self.error = L10n.error(error); return }
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                let limit = 10 * 1024 * 1024
                if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { throw PodcastUIError.oversizedOPML }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var content = Data()
                while let chunk = try handle.read(upToCount: min(65_536, limit + 1 - content.count)), !chunk.isEmpty {
                    content.append(chunk)
                    guard content.count <= limit else { throw PodcastUIError.oversizedOPML }
                }
                guard let text = String(data: content, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                return text
            }.value
            try account.validate(snapshot.1)
            opmlText = text
            await parseOPML()
        } catch { if account.isCurrent(snapshot.1) { self.error = L10n.error(error) } }
    }
    func parseOPML() async {
        let text = opmlText
        await perform(operation: { try await $0.parseOPML(text: text) }, apply: { self.opmlFeeds = $0; self.selectedFeeds = Set($0.map(\.id)) })
    }
    func importOPML() async {
        guard let library, let folder else { error = PodcastUIError.invalidPath.localizedDescription; return }
        let urls = opmlFeeds.filter { selectedFeeds.contains($0.id) }.map(\.feedUrl)
        guard !urls.isEmpty else { return }
        let auto = autoDownload
        guard let store = account.store else { return }
        await perform(operation: { client in
            try await store.requireServerTaskActivity(client: client)
            try Task.checkCancellation()
            try await client.importOPML(feedURLs: urls, libraryID: library.id, folderID: folder.id, autoDownloadEpisodes: auto)
        }, apply: { self.notice = L10n.format("已将 %1$@ 个订阅交给服务器导入；结果会显示在服务器活动中。", String(describing: urls.count)); self.opmlFeeds = []; self.selectedFeeds = [] })
    }
    func exportOPML() async {
        guard let library else { return }
        await perform(admin: false, operation: { try await $0.exportOPML(libraryID: library.id) }, apply: { self.exportedOPML = $0 })
    }
}
