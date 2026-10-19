import Foundation
import Observation
import AudilseCore

/// Read scope also supports cached, offline browsing. Management retains the
/// stricter online LibraryPersonalScope and never widens its authorization.
struct NarratorDirectorySource: Hashable, Sendable {
    let personal: LibraryPersonalSource
    let baseURL: URL
    let library: Library
    let client: ABSClient?
    let database: ShelfDatabase
    let partition: AccountPartition
    let recoveryBusy: Bool
    let accessibleLibraries: [String]
    let selectedTags: [String]

    @MainActor init?(store: AppStore, library: Library) {
        guard !store.isDemo, !store.isConnecting, !store.recoveryBusy,
              let user = store.user, user.isActive, let profile = store.profile,
              let partition = store.partition, let database = store.database,
              partition.serverID == profile.id, partition.userID == user.id,
              library.mediaType == "book", store.currentLibrary?.id == library.id, store.currentLibrary?.mediaType == "book",
              store.libraries.contains(where: { $0.id == library.id && $0.mediaType == "book" }),
              store.isOffline || store.client != nil else { return nil }
        personal = .init(store: store, libraryID: library.id); baseURL = profile.baseURL
        self.library = library; client = store.client; self.database = database
        self.partition = partition; recoveryBusy = store.recoveryBusy
        accessibleLibraries = user.librariesAccessible; selectedTags = user.itemTagsSelected
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.personal == rhs.personal && lhs.baseURL == rhs.baseURL && lhs.library == rhs.library &&
        lhs.client === rhs.client && lhs.database === rhs.database && lhs.partition == rhs.partition && lhs.recoveryBusy == rhs.recoveryBusy &&
        lhs.accessibleLibraries == rhs.accessibleLibraries && lhs.selectedTags == rhs.selectedTags
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(personal); hasher.combine(baseURL); hasher.combine(library)
        hasher.combine(client.map(ObjectIdentifier.init)); hasher.combine(ObjectIdentifier(database)); hasher.combine(partition); hasher.combine(recoveryBusy)
        hasher.combine(accessibleLibraries); hasher.combine(selectedTags)
    }
    @MainActor func isCurrent(_ store: AppStore) -> Bool { Self(store: store, library: library) == self }
}

struct NarratorDirectoryChange {
    enum Kind: Sendable { case renamed(from: String, to: String), removed(name: String) }
    let source: NarratorDirectorySource
    let result: NarratorMutationResult
    let kind: Kind
    /// Confirmed server writes remain facts even if local cache eviction fails.
    /// The parent must block old cached browsing until it retries eviction.
    let cacheInvalidated: Bool
    @MainActor func isCurrent(_ store: AppStore) -> Bool { source.isCurrent(store) }
}

@MainActor @Observable final class NarratorDirectoryModel {
    let scope: LibraryPersonalScope
    let library: Library
    let entrySource: NarratorDirectorySource?
    private(set) var source: NarratorDirectorySource?
    /// nil means never loaded; [] is a successfully loaded empty directory.
    private(set) var narrators: [LibraryNarrator]?
    private(set) var isLoading = false
    private(set) var isCached = false
    private(set) var error: String?
    private(set) var cacheError: String?
    private(set) var confirmedChange: NarratorDirectoryChange?
    var search = ""
    var editing: LibraryNarrator?
    var draftName = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingMutationID: UUID?
    @ObservationIgnored private var requestTask: Task<NarratorSnapshot, Error>?
    @ObservationIgnored private let onChange: @MainActor (NarratorDirectoryChange) -> Void

    init(store: AppStore, library: Library, onChange: @escaping @MainActor (NarratorDirectoryChange) -> Void = { _ in }) {
        scope = .init(store: store, libraryID: library.id); self.library = library
        entrySource = .init(store: store, library: library); self.onChange = onChange
    }
    var identity: NarratorDirectorySource? { .init(store: scope.store, library: library) }
    var entryIsCurrent: Bool { entrySource != nil && entrySource == identity }
    var isBound: Bool { entryIsCurrent && source == entrySource }
    var canMutate: Bool {
        isBound && !isLoading && !scope.isWorking && !isCached && cacheError == nil && scope.available &&
        !scope.store.recoveryBusy && scope.store.user.map { LibraryNarratorPolicy.allowsMutation(user: $0, serverVersion: scope.source?.serverVersion) } == true
    }
    var visibleNarrators: [LibraryNarrator] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some upstream filter-data merges contain duplicate names. The directory
        // is a name association, so show one server entry rather than duplicate IDs.
        var names = Set<String>()
        return (narrators ?? []).filter { names.insert($0.name).inserted && (query.isEmpty || $0.name.localizedStandardContains(query)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var cacheKey: String { "narrators.\(library.id)" }

    func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil; scope.cancel()
        pendingMutationID = nil
        source = nil; narrators = nil; isLoading = false; isCached = false
        editing = nil; draftName = ""; error = nil; cacheError = nil
    }
    func load(expected: NarratorDirectorySource?) async {
        guard !Task.isCancelled else { return }
        guard expected == identity, expected == entrySource else { return }
        guard let expected else { cancel(); return }
        guard !scope.isWorking else { return }
        if !expected.personal.offline, scope.source == nil { scope.bind() }
        requestTask?.cancel(); let attempt = UUID(); generation = attempt
        source = expected; isLoading = true; error = nil
        let worker = Task { try await self.snapshot(expected, attempt: attempt) }
        requestTask = worker
        defer {
            worker.cancel()
            if generation == attempt { requestTask = nil; isLoading = false }
        }
        do {
            let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try check(expected, attempt: attempt)
            narrators = value.narrators; isCached = value.cached; error = value.readError
        } catch {
            guard !Task.isCancelled, generation == attempt, source == expected, expected.isCurrent(scope.store), !Self.isCancellation(error) else { return }
            self.error = L10n.error(error)
        }
    }
    private func snapshot(_ expected: NarratorDirectorySource, attempt: UUID) async throws -> NarratorSnapshot {
        try check(expected, attempt: attempt)
        do {
            try await expected.database.retryFailedCacheInvalidation(partition: expected.partition)
            try check(expected, attempt: attempt)
            cacheError = nil
        } catch {
            try check(expected, attempt: attempt)
            cacheError = L10n.error(error)
        }
        if expected.personal.offline {
            let cached = try await expected.database.load([LibraryNarrator].self, key: cacheKey, partition: expected.partition)
            try check(expected, attempt: attempt)
            return .init(narrators: cached, cached: true, readError: nil)
        }
        guard let client = expected.client else { throw ABSError.sessionChanged }
        do {
            let result = try await client.libraryNarrators(libraryID: library.id)
            try check(expected, attempt: attempt)
            // A failed cache eviction must never repopulate old browse/item rows.
            // Fresh directory data can still be shown, while mutations stay blocked.
            if cacheError == nil { try await expected.database.save(result, key: cacheKey, partition: expected.partition) }
            try check(expected, attempt: attempt)
            return .init(narrators: result, cached: false, readError: nil)
        } catch {
            try check(expected, attempt: attempt)
            // After a confirmed write, a failed refresh must not revive old names.
            guard confirmedChange == nil, cacheError == nil, !Self.isCancellation(error),
                  let cached = try await expected.database.load([LibraryNarrator].self, key: cacheKey, partition: expected.partition) else { throw error }
            try check(expected, attempt: attempt)
            return .init(narrators: cached, cached: true, readError: L10n.error(error))
        }
    }
    private func check(_ expected: NarratorDirectorySource, attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt, source == expected, expected == entrySource, expected.isCurrent(scope.store) else { throw ABSError.sessionChanged }
    }

    func beginRename(_ narrator: LibraryNarrator) {
        guard canMutate, narrators?.contains(narrator) == true else { return }
        editing = narrator; draftName = narrator.name
    }
    func requestRename() {
        let newName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let narrator = editing, canMutate, !newName.isEmpty, newName != narrator.name,
              narrators?.contains(narrator) == true, let readSource = source,
              let (writeSource, client, scopeGeneration) = try? scope.context(requiring: [.updateContent]) else { return }
        editing = nil
        let intent = UUID(); pendingMutationID = intent
        scope.confirm(.init(title: L10n.tr("改名朗读者？"),
                            message: L10n.format("将此书库所有图书中的“%1$@”改为“%2$@”；改为已有名称时会合并关联。", narrator.name, newName), action: {
            await self.mutate(intent: intent, readSource: readSource, writeSource: writeSource, client: client, scopeGeneration: scopeGeneration,
                              kind: .renamed(from: narrator.name, to: newName)) {
                try await client.renameLibraryNarrator(libraryID: self.library.id, currentName: narrator.name, newName: newName)
            }
        }))
    }
    func requestRemove(_ narrator: LibraryNarrator) {
        guard canMutate, narrators?.contains(narrator) == true, let readSource = source,
              let (writeSource, client, scopeGeneration) = try? scope.context(requiring: [.updateContent]) else { return }
        editing = nil; draftName = ""
        let intent = UUID(); pendingMutationID = intent
        scope.confirm(.init(title: L10n.tr("移除朗读者？"),
                            message: L10n.format("从此书库所有图书中移除“%1$@”的朗读者关联。保留图书、文件及播放进度。", narrator.name), destructive: true, action: {
            await self.mutate(intent: intent, readSource: readSource, writeSource: writeSource, client: client, scopeGeneration: scopeGeneration,
                              kind: .removed(name: narrator.name)) {
                try await client.removeLibraryNarrator(libraryID: self.library.id, name: narrator.name)
            }
        }))
    }
    private func mutate(intent: UUID, readSource: NarratorDirectorySource, writeSource: LibraryPersonalSource, client: ABSClient,
                        scopeGeneration: UUID, kind: NarratorDirectoryChange.Kind,
                        operation: @escaping @MainActor () async throws -> NarratorMutationResult) async {
        // A confirmation can outlive a permission, account, library or screen.
        guard pendingMutationID == intent, canMutate, source == readSource, readSource.isCurrent(scope.store),
              (try? scope.check(writeSource, scopeGeneration)) != nil,
              scope.store.user.map({ LibraryNarratorPolicy.allowsMutation(user: $0, serverVersion: writeSource.serverVersion) }) == true else { return }
        // Consume synchronously before suspension; duplicate activation cannot
        // submit the same confirmed write twice.
        pendingMutationID = nil
        let changed = await scope.run(source: writeSource, generation: scopeGeneration) {
            try self.scope.check(writeSource, scopeGeneration)
            let result = try await operation()
            try self.scope.check(writeSource, scopeGeneration)
            guard readSource.isCurrent(self.scope.store) else { throw ABSError.sessionChanged }
            // Account cache eviction preserves downloads, resume records and the
            // offline listening queue. Do it before exposing confirmed success.
            let cacheFailure: String?
            do { try await readSource.database.clearCache(partition: readSource.partition); cacheFailure = nil }
            catch { cacheFailure = L10n.error(error) }
            try self.scope.check(writeSource, scopeGeneration)
            guard readSource.isCurrent(self.scope.store) else { throw ABSError.sessionChanged }
            return NarratorWriteOutcome(result: result, cacheFailure: cacheFailure)
        } apply: { outcome in
            let change = NarratorDirectoryChange(source: readSource, result: outcome.result, kind: kind,
                                                cacheInvalidated: outcome.cacheFailure == nil)
            self.confirmedChange = change; self.cacheError = outcome.cacheFailure
            self.narrators = nil; self.isCached = false
            self.scope.notice = L10n.format("服务器已确认修改，影响 %1$@ 本图书。", String(outcome.result.updated))
            self.onChange(change)
        }
        if changed { await load(expected: readSource) }
        else if scope.source == writeSource, writeSource.isCurrent(scope.store), let failure = scope.error {
            scope.error = failure + " " + L10n.tr("部分图书可能已修改。请刷新检查结果；不会自动重发此操作。")
        }
    }
    func browse(_ narrator: LibraryNarrator, renderedSource: NarratorDirectorySource?) -> Bool {
        guard let renderedSource, renderedSource == source, isBound,
              renderedSource.isCurrent(scope.store), narrators?.contains(narrator) == true else { return false }
        scope.store.browse(libraryID: library.id, filter: .narrator(narrator.name))
        return true
    }
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled
    }
}

private struct NarratorSnapshot: Sendable { let narrators: [LibraryNarrator]?; let cached: Bool; let readError: String? }
private struct NarratorWriteOutcome: Sendable { let result: NarratorMutationResult; let cacheFailure: String? }

extension LibraryNarratorError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .unsafeServerVersion: L10n.tr("此服务端版本的朗读者修改可能影响其他书库。请升级到 2.36.1 或更新版本后修改。")
        case .emptyName: L10n.tr("朗读者名称不能为空。")
        }
    }
}
