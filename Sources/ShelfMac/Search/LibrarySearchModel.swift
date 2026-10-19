import Foundation
import Observation
import ShelfCore

enum LibrarySearchScope: String, CaseIterable, Codable, Hashable, Sendable {
    case currentLibrary, allLibraries
}

/// Includes UI request options as well as the account and server snapshot.
/// Actions also check Model.isBound, because scope/limit belong to that model.
struct LibrarySearchSource: Hashable {
    let coverSource: CoverSource
    let partition: AccountPartition?
    let client: ObjectIdentifier?
    let database: ObjectIdentifier?
    let libraries: [Library]
    let currentLibraryID: String?
    let revision: UUID
    let offline: Bool
    let connecting: Bool
    let active: Bool
    let route: ShelfRoute
    let query: String
    let scope: LibrarySearchScope
    let limit: Int

    @MainActor init(store: AppStore, scope: LibrarySearchScope, limit: Int) {
        coverSource = CoverSource(store: store)
        partition = store.partition; client = store.client.map(ObjectIdentifier.init)
        database = store.database.map(ObjectIdentifier.init); libraries = store.libraries
        currentLibraryID = store.currentLibrary?.id; revision = store.libraryRevision
        offline = store.isOffline; connecting = store.isConnecting; active = store.user?.isActive == true
        route = store.route; query = store.search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope; self.limit = min(500, max(1, limit))
    }

    @MainActor func isCurrent(_ store: AppStore) -> Bool {
        partition != nil && active && !connecting &&
        self == LibrarySearchSource(store: store, scope: scope, limit: limit)
    }

    var requestedLibraries: [Library] {
        var seen = Set<String>()
        return libraries.filter {
            !$0.id.isEmpty && (scope == .allLibraries || $0.id == currentLibraryID) && seen.insert($0.id).inserted
        }
    }
}

enum LibrarySearchSectionState: Hashable, Sendable {
    case pending, loading, loaded, cached, missingCache, failed
}

struct LibrarySearchSection: Hashable, Identifiable, Sendable {
    let library: Library
    var response: LibrarySearchResponse?
    var state: LibrarySearchSectionState = .pending
    var error: String?
    var cacheError: String?
    var updatedAt: Date?
    var usesCache = false
    var id: String { library.id }
}

private struct CachedLibrarySearch: Codable, Sendable {
    let response: LibrarySearchResponse
    let updatedAt: Date
}

/// Search requests never enumerate items to build an unsolicited local index.
/// A larger limit replaces this query's prefix, rather than appending a page.
@MainActor @Observable final class LibrarySearchModel {
    var scope: LibrarySearchScope = .currentLibrary
    var limit = 12
    private(set) var sections: [LibrarySearchSection] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var source: LibrarySearchSource?
    private var generation = UUID()
    @ObservationIgnored private var requestTask: Task<Void, Never>?

    func isBound(to store: AppStore, source expected: LibrarySearchSource? = nil) -> Bool {
        guard let source, expected == nil || expected == source else { return false }
        return source.isCurrent(store) && source == LibrarySearchSource(store: store, scope: scope, limit: limit)
    }

    func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil
        source = nil; sections = []; error = nil; isLoading = false
    }

    func load(store: AppStore, source requested: LibrarySearchSource) async {
        // A cancelled old SwiftUI task must not replace the winner's generation.
        guard !Task.isCancelled, requested.isCurrent(store),
              requested == LibrarySearchSource(store: store, scope: scope, limit: limit) else { return }
        let operation = UUID(); generation = operation
        requestTask?.cancel(); requestTask = nil
        source = requested; error = nil; sections = []; isLoading = false
        guard !requested.query.isEmpty else { return }
        let libraries = requested.requestedLibraries
        guard !libraries.isEmpty else { error = L10n.tr("没有可搜索的书库。"); return }
        sections = libraries.map { LibrarySearchSection(library: $0) }
        guard let partition = requested.partition else { return }
        let client = store.client, database = store.database
        if !requested.offline && client == nil {
            error = L10n.tr("请先连接服务器。")
            sections = sections.map { var value = $0; value.state = .failed; value.error = error; return value }
            return
        }
        isLoading = true
        defer {
            if generation == operation {
                requestTask = nil; isLoading = false
                if Task.isCancelled { source = nil; sections = []; error = nil }
            }
        }
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.generation == operation && self.isBound(to: store, source: requested)
        }
        let publish: @MainActor @Sendable (LibrarySearchSection) -> Void = { [weak self] section in
            guard let self, current(), let index = self.sections.firstIndex(where: { $0.id == section.id }) else { return }
            self.sections[index] = section
        }
        let query = requested.query, limit = requested.limit, offline = requested.offline
        let request = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                for library in libraries.prefix(3) {
                    next += 1
                    group.addTask {
                        await Self.loadSection(library: library, query: query, limit: limit, offline: offline,
                                               partition: partition, client: client, database: database, current: current, publish: publish)
                    }
                }
                while await group.next() != nil {
                    guard current() else { group.cancelAll(); return }
                    if next < libraries.count {
                        let library = libraries[next]; next += 1
                        group.addTask {
                            await Self.loadSection(library: library, query: query, limit: limit, offline: offline,
                                                   partition: partition, client: client, database: database, current: current, publish: publish)
                        }
                    }
                }
            }
        }
        requestTask = request
        await withTaskCancellationHandler { await request.value } onCancel: { request.cancel() }
    }

    private static func loadSection(library: Library, query: String, limit: Int, offline: Bool,
                                    partition: AccountPartition, client: ABSClient?, database: ShelfDatabase?,
                                    current: @escaping @MainActor @Sendable () -> Bool,
                                    publish: @escaping @MainActor @Sendable (LibrarySearchSection) -> Void) async {
        guard current() else { return }
        var section = LibrarySearchSection(library: library, state: .loading)
        publish(section)
        let key = cacheKey(libraryID: library.id, query: query, limit: limit)
        if let database {
            do {
                let cached = try await database.load(CachedLibrarySearch.self, key: key, partition: partition)
                guard current() else { return }
                if let cached {
                    section.response = cached.response; section.updatedAt = cached.updatedAt; section.usesCache = true
                }
            } catch {
                guard current() else { return }
                section.cacheError = L10n.error(error)
            }
        }
        guard current() else { return }
        if offline {
            section.state = section.response == nil ? (section.cacheError == nil ? .missingCache : .failed) : .cached
            publish(section); return
        }
        publish(section)
        guard let client else { return }
        do {
            let response = try await client.searchLibrary(libraryID: library.id, query: query, limit: limit)
            guard current() else { return }
            let date = Date()
            section.response = response; section.updatedAt = date; section.usesCache = false; section.state = .loaded
            publish(section)
            if let database {
                do { try await database.save(CachedLibrarySearch(response: response, updatedAt: date), key: key, partition: partition) }
                catch {
                    guard current() else { return }
                    section.cacheError = L10n.error(error)
                    publish(section)
                }
                guard current() else { return }
            }
        } catch {
            guard current() else { return }
            section.error = L10n.error(error); section.state = section.response == nil ? .failed : .cached
            publish(section)
        }
    }

    private static func cacheKey(libraryID: String, query: String, limit: Int) -> String {
        "search.v1.\(libraryID.utf8.count):\(libraryID).\(query.utf8.count):\(query).\(limit)"
    }
}
