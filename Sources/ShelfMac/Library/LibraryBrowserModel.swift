import Foundation
import Observation
import CryptoKit
import ShelfCore

enum LibraryDisplayMode: String, Codable, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
}
struct LibraryBrowserPreferences: Codable {
    var options: LibraryBrowseOptions
    var display: LibraryDisplayMode = .grid
    var coverSize: Double = 160
    var showSubtitles = false
    var sortByProgressPercentage = false
    init(options: LibraryBrowseOptions, display: LibraryDisplayMode = .grid, coverSize: Double = 160, showSubtitles: Bool = false, sortByProgressPercentage: Bool = false) {
        self.options = options; self.display = display; self.coverSize = coverSize
        self.showSubtitles = showSubtitles; self.sortByProgressPercentage = sortByProgressPercentage
    }
    private enum CodingKeys: String, CodingKey { case options, display, coverSize, showSubtitles, sortByProgressPercentage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decode(LibraryBrowseOptions.self, forKey: .options)
        display = try c.decodeIfPresent(LibraryDisplayMode.self, forKey: .display) ?? .grid
        coverSize = try c.decodeIfPresent(Double.self, forKey: .coverSize) ?? 160
        showSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showSubtitles) ?? false
        // The previous UI called the server's update-date sort "listening progress".
        sortByProgressPercentage = try c.decodeIfPresent(Bool.self, forKey: .sortByProgressPercentage) ?? (options.sort == .progress)
    }
    mutating func normalize(library: Library, user: UserAccount?, version: String?) {
        options.page = 0; options.limit = 60
        if library.mediaType != "book" { sortByProgressPercentage = false }
        if sortByProgressPercentage { options.sort = .title; options.collapseSeries = false }
        if !options.filter.isAvailable(mediaType: library.mediaType, user: user) { options.filter = .all }
        if library.mediaType != "book" { options.collapseSeries = false }
        if case .series = options.filter, options.collapseSeries,
           [.progress, .progressStarted, .progressFinished, .random].contains(options.sort) {
            options.sort = .sequence; options.descending = false
        }
        if !LibraryBrowseSort.available(mediaType: library.mediaType, filter: options.filter, serverVersion: version).contains(options.sort) {
            options.sort = .title; options.descending = false
        }
        coverSize = min(240, max(120, coverSize.isFinite ? coverSize : 160))
    }
}

/// Book and podcast libraries retain their own settings inside an account partition.
@MainActor struct LibraryBrowserPreferencesStore {
    var defaults: UserDefaults = .standard
    func load(partition: AccountPartition?, library: Library, fallback: ClientPreferences) -> LibraryBrowserPreferences {
        if let partition, let data = defaults.data(forKey: key(partition, library.id)),
           let saved = try? JSONDecoder().decode(LibraryBrowserPreferences.self, from: data) { return saved }
        var options = LibraryBrowseOptions()
        options.sort = LibraryBrowseSort(rawValue: fallback.orderBy) ?? .title
        options.descending = fallback.orderDesc; options.collapseSeries = library.mediaType == "book" && fallback.collapseSeries
        return .init(options: options, coverSize: min(240, max(120, fallback.coverSize)), showSubtitles: fallback.showSubtitles)
    }
    func save(_ preferences: LibraryBrowserPreferences, partition: AccountPartition, libraryID: String) throws {
        var saved = preferences; saved.options.page = 0
        saved.coverSize = min(240, max(120, saved.coverSize.isFinite ? saved.coverSize : 160))
        defaults.set(try JSONEncoder().encode(saved), forKey: key(partition, libraryID))
    }
    private func key(_ partition: AccountPartition, _ libraryID: String) -> String { "ShelfMac.LibraryBrowser." + partition.directoryName + "." + libraryID }
}

private struct CachedLibraryPage: Codable, Sendable {
    var entries: [LibraryBrowseEntry]
    var total: Int?
}
private struct PercentageSourceContext: Hashable {
    var partition: AccountPartition
    var client: ObjectIdentifier?
    var offline: Bool
    var revision: UUID
    var key: String
}

@MainActor @Observable final class LibraryBrowserModel {
    var entries: [LibraryBrowseEntry] = []
    var metadata: LibraryFilterMetadata?
    var total: Int?
    var hasMore = false
    var isLoading = false
    var metadataLoading = false
    var error: String?
    var metadataError: String?
    var usesLegacyCache = false
    private var generation = UUID()
    private var metadataGeneration = UUID()
    private(set) var coverSource: CoverSource?
    private var boundPartition: AccountPartition?
    private var boundClient: ABSClient?
    private var boundLibraryID: String?
    @ObservationIgnored private var percentageSource: (context: PercentageSourceContext, entries: [LibraryBrowseEntry])?

    func isBound(to store: AppStore, libraryID: String) -> Bool {
        boundPartition == store.partition && boundClient === store.client && boundLibraryID == libraryID && store.user?.isActive == true
    }
    func cancel() { coverSource = nil; generation = UUID(); metadataGeneration = UUID(); boundPartition = nil; boundClient = nil; boundLibraryID = nil; percentageSource = nil; isLoading = false; metadataLoading = false }

    func load(store: AppStore, library: Library, options: LibraryBrowseOptions, search: String, progressPercentage: Bool = false) async {
        guard !Task.isCancelled, store.currentLibrary?.id == library.id else { return }
        let operation = UUID(); generation = operation
        let client = store.client, partition = store.partition, offline = store.isOffline
        coverSource = CoverSource(store: store)
        boundPartition = partition; boundClient = client; boundLibraryID = library.id
        entries = []; total = nil; hasMore = false; isLoading = true; error = nil; usesLegacyCache = false
        defer { if generation == operation { isLoading = false } }
        guard let partition, let database = store.database else { return }
        func current() -> Bool { generation == operation && store.partition == partition && store.client === client && store.currentLibrary?.id == library.id && store.isOffline == offline && !Task.isCancelled }
        do {
            guard options.page >= 0, (1...200).contains(options.limit) else { throw ABSError.invalidResponse }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if progressPercentage && query.isEmpty {
                var scan = options; scan.page = 0; scan.limit = 200; scan.sort = .title; scan.descending = false; scan.collapseSeries = false
                let key = "percentage-source." + cacheKey(library.id, scan)
                let context = PercentageSourceContext(partition: partition, client: client.map(ObjectIdentifier.init), offline: offline, revision: store.libraryRevision, key: key)
                let all: [LibraryBrowseEntry]
                if let cached = percentageSource, cached.context == context { all = cached.entries }
                else if offline {
                    let cached = try await database.load(CachedLibraryPage.self, key: key, partition: partition)
                    guard current() else { return }
                    if let cached { all = cached.entries }
                    else if options.filter == .all {
                        let old = try await database.load([ShelfCore.LibraryItem].self, key: "items.\(library.id)", partition: partition) ?? []
                        guard current() else { return }; all = old.map { .init(item: $0) }
                    } else { all = [] }
                } else {
                    guard let client else { return }
                    var found: [LibraryBrowseEntry] = [], seen = Set<String>()
                    while true {
                        try Task.checkCancellation()
                        let result = try await client.browseLibrary(libraryID: library.id, options: scan)
                        guard current() else { return }
                        let fresh = result.results.filter { seen.insert($0.id).inserted }
                        found += fresh
                        if !result.hasMore { break }
                        guard !fresh.isEmpty else { throw ABSError.invalidResponse }
                        scan.page += 1
                    }
                    all = found
                    try await database.save(CachedLibraryPage(entries: all, total: all.count), key: key, partition: partition)
                    guard current() else { return }
                }
                guard current() else { return }
                percentageSource = (context, all)
                let progress = store.progressByItem, descending = options.descending
                let sorting = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return LibraryProgressOrdering.sorted(all, progress: progress, descending: descending)
                }
                let sorted = try await withTaskCancellationHandler(operation: { try await sorting.value }, onCancel: { sorting.cancel() })
                guard current() else { return }
                entries = Array(sorted.dropFirst(options.page * options.limit).prefix(options.limit))
                total = sorted.count; hasMore = (options.page + 1) * options.limit < sorted.count
                return
            }
            if offline {
                if query.isEmpty {
                    let cached = try await database.load(CachedLibraryPage.self, key: cacheKey(library.id, options), partition: partition)
                    let nextKey = { var next = options; next.page += 1; return self.cacheKey(library.id, next) }()
                    let next = try await database.load(CachedLibraryPage.self, key: nextKey, partition: partition)
                    guard current() else { return }
                    if let cached { entries = cached.entries; total = cached.total; hasMore = next != nil }
                    else if options.filter == .all && !options.collapseSeries && options.sort == .title {
                        let old = try await database.load([ShelfCore.LibraryItem].self, key: "items.\(library.id)", partition: partition) ?? []
                        guard current() else { return }
                        let sorted = old.sorted { options.descending ? $0.title.localizedStandardCompare($1.title) == .orderedDescending : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                        entries = sorted.dropFirst(options.page * options.limit).prefix(options.limit).map { .init(item: $0) }
                        total = sorted.count; hasMore = (options.page + 1) * options.limit < sorted.count; usesLegacyCache = true
                    }
                } else {
                    let cached = try await database.load([ShelfCore.LibraryItem].self, key: "items.\(library.id)", partition: partition) ?? []
                    guard current() else { return }
                    let matches = cached.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.authorName.localizedCaseInsensitiveContains(query) }
                    entries = matches.dropFirst(options.page * options.limit).prefix(options.limit).map { .init(item: $0) }
                    total = matches.count; hasMore = (options.page + 1) * options.limit < matches.count
                }
                return
            }
            guard let client else { return }
            if !query.isEmpty {
                try await Task.sleep(for: .milliseconds(300))
                let result = try await client.libraryItems(libraryID: library.id, page: options.page, limit: options.limit, search: query)
                guard current() else { return }
                entries = result.results.map { .init(item: $0) }; hasMore = result.hasMore
                // ABS search returns an expanding prefix rather than an exact total.
                total = result.hasMore ? nil : result.total
            } else {
                let result = try await client.browseLibrary(libraryID: library.id, options: options)
                guard current() else { return }
                entries = result.results; total = result.total; hasMore = result.hasMore
                try await database.save(CachedLibraryPage(entries: result.results, total: result.total), key: cacheKey(library.id, options), partition: partition)
                guard current() else { return }
                // Also retain visited unfiltered individual books for offline text search.
                if options.filter == .all && !options.collapseSeries {
                    let old = try await database.load([ShelfCore.LibraryItem].self, key: "items.\(library.id)", partition: partition) ?? []
                    guard current() else { return }
                    let pageEntries = result.results
                    let merging = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        var merged = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                        for entry in pageEntries { merged[entry.item.id] = entry.item }
                        let sorted = merged.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                        try Task.checkCancellation()
                        return sorted
                    }
                    let merged = try await withTaskCancellationHandler(operation: { try await merging.value }, onCancel: { merging.cancel() })
                    guard current() else { return }
                    try await database.save(merged, key: "items.\(library.id)", partition: partition)
                }
            }
        } catch is CancellationError {} catch ABSError.sessionChanged {}
        catch let failure as URLError where failure.code == .cancelled {}
        catch { if current() { self.error = L10n.error(error) } }
    }

    func loadMetadata(store: AppStore, library: Library) async {
        guard !Task.isCancelled, store.currentLibrary?.id == library.id else { return }
        let operation = UUID(); metadataGeneration = operation
        let partition = store.partition, client = store.client, offline = store.isOffline
        metadata = nil; metadataError = nil; metadataLoading = true
        defer { if metadataGeneration == operation { metadataLoading = false } }
        guard let partition else { return }
        func current() -> Bool { metadataGeneration == operation && store.partition == partition && store.client === client && store.currentLibrary?.id == library.id && store.isOffline == offline && !Task.isCancelled }
        do {
            if offline {
                let cached = try await store.database?.load(LibraryFilterMetadata.self, key: "filters.\(library.id)", partition: partition)
                guard current() else { return }; metadata = cached
            } else if let client {
                let result = try await client.libraryFilterMetadata(libraryID: library.id)
                guard current() else { return }; metadata = result
                try await store.database?.save(result, key: "filters.\(library.id)", partition: partition)
            }
        } catch is CancellationError {} catch ABSError.sessionChanged {}
        catch let failure as URLError where failure.code == .cancelled {}
        catch { if current() { metadataError = L10n.error(error) } }
    }

    private func cacheKey(_ libraryID: String, _ options: LibraryBrowseOptions) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(options)) ?? Data()
        return "browse.\(libraryID)." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
