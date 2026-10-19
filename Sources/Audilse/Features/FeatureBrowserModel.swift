import Foundation
import Observation
import AudilseCore

struct FeatureGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var count: Int
    var books: [AudilseCore.LibraryItem] = []
    var entries: [PlaylistEntry] = []
    var libraryID: String?
}

@MainActor @Observable final class FeatureBrowserModel {
    var groups: [FeatureGroup] = []
    var history: [ListeningHistoryEntry] = []
    var statistics: ListeningStatistics?
    var yearly: YearlyStatistics?
    var selectedYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    var availableYears: [Int] = []
    var statisticsError: String?
    var yearlyError: String?
    var isYearLoading = false
    var isLoading = false
    var hasMore = false
    var error: String?
    private var page = 0
    private var generation = UUID()
    private var yearGeneration = UUID()
    private struct YearlySource {
        let account: AccountPartition
        let client: ABSClient
        let year: Int
    }
    private var yearlySource: YearlySource?

    /// Keep a previous response from being relabelled during the frame before a new task starts.
    func currentYearly(store: AppStore) -> YearlyStatistics? {
        guard let source = yearlySource, !isYearLoading, !store.isOffline, !store.isConnecting,
              store.user?.isActive == true, store.user?.id == source.account.userID,
              source.account == store.partition, source.client === store.client,
              source.year == selectedYear else { return nil }
        return yearly
    }

    func load(store: AppStore, kind: FeatureKind, more: Bool = false) async {
        guard !Task.isCancelled else { return }
        if more && isLoading { return }
        let operation = UUID(); generation = operation
        yearGeneration = UUID(); isYearLoading = false
        if !more { groups = []; history = []; statistics = nil; yearly = nil; yearlySource = nil; statisticsError = nil; yearlyError = nil; hasMore = false; page = 0 }
        isLoading = true; error = nil
        defer { if generation == operation { isLoading = false } }
        if kind == .statistics {
            await loadStatistics(store: store, operation: operation)
            return
        }
        guard let partition = store.partition, let library = store.currentLibrary else { return }
        let client = store.client
        let offline = store.isOffline
        let query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "feature.\(library.id).\(kind.rawValue)"
        func isCurrent() -> Bool {
            generation == operation && store.partition == partition && store.client === client &&
            store.currentLibrary?.id == library.id && store.search.trimmingCharacters(in: .whitespacesAndNewlines) == query &&
            store.isOffline == offline && !Task.isCancelled
        }
        do {
            if offline {
                if let database = store.database {
                    let cached = try await database.load([FeatureGroup].self, key: cacheKey, partition: partition) ?? []
                    guard isCurrent() else { return }; groups = cached
                }
                return
            }
            guard let client else { return }
            if !query.isEmpty && !more { try await Task.sleep(for: .milliseconds(300)) }
            repeat {
                try Task.checkCancellation()
                guard isCurrent() else { return }
                let requestedPage = page
                var next: [FeatureGroup] = []; var moreAvailable = false
                switch kind {
                case .authors:
                    let result = try await client.authors(libraryID: library.id, page: requestedPage)
                    next = result.results.map { .init(id: $0.id, title: $0.name, summary: $0.description?.shelfPlainText ?? "", count: $0.numBooks, books: $0.libraryItems, libraryID: library.id) }; moreAvailable = result.hasMore
                case .series:
                    let result = try await client.series(libraryID: library.id, page: requestedPage)
                    next = result.results.map { .init(id: $0.id, title: $0.name, summary: $0.description?.shelfPlainText ?? "", count: $0.books.count, books: $0.books, libraryID: library.id) }; moreAvailable = result.hasMore
                case .collections:
                    let result = try await client.collections(libraryID: library.id, page: requestedPage)
                    next = result.results.map { .init(id: $0.id, title: $0.name, summary: $0.description?.shelfPlainText ?? "", count: $0.books.count, books: $0.books, libraryID: library.id) }; moreAvailable = result.hasMore
                case .playlists:
                    let result = try await client.playlists(libraryID: library.id, page: requestedPage)
                    next = result.results.map { .init(id: $0.id, title: $0.name, summary: $0.description?.shelfPlainText ?? "", count: $0.items.count, books: $0.items.compactMap(\.libraryItem), entries: $0.items, libraryID: library.id) }; moreAvailable = result.hasMore
                case .history:
                    let result = try await client.listeningHistory(page: requestedPage)
                    guard isCurrent() else { return }
                    let ids = Set(history.map(\.id)); history += result.sessions.filter { !ids.contains($0.id) }
                    moreAvailable = result.hasMore && !result.sessions.isEmpty
                case .statistics:
                    break // Statistics requests publish independently in loadStatistics.
                }
                guard isCurrent() else { return }
                if kind != .history && kind != .statistics {
                    let ids = Set(groups.map(\.id)); groups += next.filter { !ids.contains($0.id) }
                    // Empty pages end scanning even if a stale server total claims more.
                    moreAvailable = moreAvailable && !next.isEmpty
                }
                page = requestedPage + 1; hasMore = moreAvailable
                // Search scans every server page; partial matches remain visible as it proceeds.
                if query.isEmpty || !hasMore { break }
            } while true
            if kind != .history && kind != .statistics, isCurrent() {
                try await store.database?.save(groups, key: cacheKey, partition: partition)
            }
        } catch is CancellationError { }
        catch ABSError.sessionChanged { }
        catch let failure as URLError where failure.code == .cancelled { }
        catch { if isCurrent() { self.error = L10n.error(error) } }
    }

    private func loadStatistics(store: AppStore, operation: UUID) async {
        updateAvailableYears(createdAt: store.user?.createdAt)
        guard !store.isOffline, !store.isConnecting, let partition = store.partition, let client = store.client else { return }
        // A failed annual request must not discard successful lifetime statistics, or vice versa.
        async let overall: Void = loadOverallStatistics(store: store, partition: partition, client: client, operation: operation)
        async let annual: Void = loadYear(store: store, year: selectedYear)
        _ = await (overall, annual)
    }

    private func loadOverallStatistics(store: AppStore, partition: AccountPartition, client: ABSClient, operation: UUID) async {
        func isCurrent() -> Bool {
            generation == operation && store.partition == partition && store.client === client && !store.isOffline && !Task.isCancelled
        }
        do {
            let result = try await client.listeningStats()
            guard isCurrent() else { return }
            statistics = result
            updateAvailableYears(createdAt: store.user?.createdAt)
        } catch {
            guard isCurrent(), !Self.isCancellation(error) else { return }
            statisticsError = L10n.error(error)
        }
    }

    func loadYear(store: AppStore, year: Int) async {
        guard !Task.isCancelled, selectedYear == year, availableYears.contains(year), !store.isOffline, !store.isConnecting, let partition = store.partition, let client = store.client else { return }
        let operation = UUID(); yearGeneration = operation
        let parentOperation = generation
        yearly = nil; yearlySource = nil; yearlyError = nil; isYearLoading = true
        func isCurrent() -> Bool {
            yearGeneration == operation && generation == parentOperation && selectedYear == year &&
            store.partition == partition && store.client === client && !store.isOffline && !Task.isCancelled
        }
        defer { if yearGeneration == operation { isYearLoading = false } }
        do {
            let result = try await client.yearlyStatistics(year: year)
            guard isCurrent() else { return }
            yearly = result
            yearlySource = .init(account: partition, client: client, year: year)
        } catch {
            guard isCurrent(), !Self.isCancellation(error) else { return }
            if case ABSError.http(status: 404, message: _) = error { yearlyError = L10n.tr("此服务器未提供年度统计，累计统计仍可查看。") }
            else { yearlyError = L10n.error(error) }
        }
    }

    private func updateAvailableYears(createdAt: Double?) {
        let calendar = Calendar(identifier: .gregorian)
        let current = calendar.component(.year, from: Date())
        let createdYear = createdAt.flatMap { value -> Int? in
            guard value.isFinite, value > 0 else { return nil }
            return calendar.component(.year, from: Date(timeIntervalSince1970: value / 1_000))
        }
        let firstListeningYear = statistics?.days.keys.compactMap { Int($0.prefix(4)) }.min()
        let oldest = max(2000, min(current, createdYear ?? firstListeningYear ?? current))
        availableYears = Array((oldest...current).reversed())
        if !availableYears.contains(selectedYear) { selectedYear = current }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ABSError.sessionChanged = error { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

func fetchFeatureGroup(client: ABSClient, kind: FeatureKind, id: String, libraryID: String) async throws -> FeatureGroup {
    switch kind {
    case .authors:
        let value = try await client.author(id: id)
        let books = try await allFeatureBooks { try await client.items(libraryID: libraryID, authorID: id, page: $0) }
        return .init(id: value.id, title: value.name, summary: value.description?.shelfPlainText ?? "", count: books.count, books: books, libraryID: libraryID)
    case .series:
        let value = try await client.series(id: id, libraryID: libraryID)
        let items = try await allFeatureBooks { try await client.items(libraryID: libraryID, seriesID: id, page: $0) }
        let books = items.sorted { lhs, rhs in
            let left = lhs.media.metadata.series.first { $0.id == id }?.sequence
            let right = rhs.media.metadata.series.first { $0.id == id }?.sequence
            if left != right {
                if let left, let right { return left.localizedStandardCompare(right) == .orderedAscending }
                return left != nil
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return .init(id: value.id, title: value.name, summary: value.description?.shelfPlainText ?? "", count: books.count, books: books, libraryID: libraryID)
    case .collections:
        let value = try await client.collection(id: id)
        return .init(id: value.id, title: value.name, summary: value.description?.shelfPlainText ?? "", count: value.books.count, books: value.books, libraryID: value.libraryId)
    case .playlists:
        let value = try await client.playlist(id: id)
        return .init(id: value.id, title: value.name, summary: value.description?.shelfPlainText ?? "", count: value.items.count, books: value.items.compactMap(\.libraryItem), entries: value.items, libraryID: value.libraryId)
    default: throw ABSError.invalidResponse
    }
}

private func allFeatureBooks(_ fetch: (Int) async throws -> ItemPage) async throws -> [AudilseCore.LibraryItem] {
    var books: [AudilseCore.LibraryItem] = [], ids = Set<String>(), page = 0
    repeat {
        try Task.checkCancellation()
        let result = try await fetch(page)
        for item in result.results where ids.insert(item.id).inserted { books.append(item) }
        if !result.hasMore || result.results.isEmpty { return books }
        page += 1
    } while true
}
