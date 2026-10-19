import Foundation
import Observation
import ShelfCore

/// Progress changes do not invalidate a management page; account/access changes do.
struct ServerPlaybackSessionsSource: Hashable, Sendable {
    let client: ABSClient
    let partition: AccountPartition
    let profileID: UUID
    let baseURL: URL
    let version: String?
    let accountEpoch: UUID
    let actor: UserAccount

    @MainActor init?(store: AppStore) {
        guard !store.isDemo, !store.isOffline, !store.isConnecting,
              store.serverRecovery == nil, !store.recoveryBusy,
              let client = store.client, let partition = store.partition, let profile = store.profile,
              var actor = store.user, AdminPolicy.allows(.manageServer, user: actor),
              partition.serverID == profile.id, partition.userID == actor.id,
              profile.userID == nil || profile.userID == actor.id else { return nil }
        actor.mediaProgress = []; actor.seriesHideFromContinueListening = []; actor.createdAt = nil
        actor.librariesAccessible = Array(Set(actor.librariesAccessible)).sorted()
        actor.itemTagsSelected = Array(Set(actor.itemTagsSelected)).sorted()
        self.client = client; self.partition = partition; profileID = profile.id; baseURL = profile.baseURL
        version = profile.serverVersion; accountEpoch = store.accountOperationID; self.actor = actor
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.client === rhs.client && lhs.partition == rhs.partition && lhs.profileID == rhs.profileID &&
        lhs.baseURL == rhs.baseURL && lhs.version == rhs.version && lhs.accountEpoch == rhs.accountEpoch && lhs.actor == rhs.actor
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(client)); hasher.combine(partition); hasher.combine(profileID)
        hasher.combine(baseURL); hasher.combine(version); hasher.combine(accountEpoch); hasher.combine(actor)
    }
    func canAccess(_ item: LibraryItem) -> Bool {
        // ABS applies library/tag restrictions even to administrators. The fresh
        // authenticated item GET additionally enforces fields this DTO omits.
        guard actor.isActive, actor.permissions.accessAllLibraries || actor.librariesAccessible.contains(item.libraryId),
              !item.media.metadata.explicit || actor.permissions.accessExplicitContent else { return false }
        if actor.permissions.accessAllTags { return true }
        let selected = Set(actor.itemTagsSelected), tags = Set(item.media.tags)
        return actor.permissions.selectedTagsNotAccessible ? selected.isDisjoint(with: tags) : !selected.isDisjoint(with: tags)
    }
    @MainActor func isCurrent(store: AppStore) -> Bool { Self(store: store) == self }
}

struct ServerHistoricalPlaybackRequest: Identifiable, Sendable {
    let id = UUID()
    let source: ServerPlaybackSessionsSource
    let item: LibraryItem
    let episodeID: String?
    let position: Double
    let title: String
}

struct ServerPlaybackSessionsQuery: Hashable, Sendable {
    var page = 0
    var limit = 10
    var userID: String?
    var sort: AdminPlaybackSessionSort = .updatedAt
    var descending = true
}

struct ServerPlaybackSessionDetail: Identifiable, Sendable {
    let session: AdminPlaybackSession
    let kind: AdminPlaybackSessionKind
    var id: String { "\(kind.rawValue):\(session.id)" }
}

struct ServerPlaybackSessionMutation: Identifiable, Sendable {
    enum Action: Sendable { case deleteOne, deleteBatch, close }
    let id = UUID()
    let source: ServerPlaybackSessionsSource
    let rows: [AdminPlaybackSession]
    let action: Action
    let revision: UUID
    var ids: Set<String> { Set(rows.map(\.id)) }
}

@MainActor @Observable final class ServerPlaybackSessionsModel {
    let targetUserID: String?
    var query = ServerPlaybackSessionsQuery()
    var selectedIDs: Set<String> = []
    var detail: ServerPlaybackSessionDetail?
    private(set) var source: ServerPlaybackSessionsSource?
    private(set) var history: AdminPlaybackSessionPage?
    private(set) var users: [AdminUser] = []
    private(set) var openSessions: [AdminPlaybackSession] = []
    private(set) var shareSessions: [AdminPlaybackSession] = []
    private(set) var historyLoading = false
    private(set) var usersLoading = false
    private(set) var openLoading = false
    private(set) var shareLoading = false
    private(set) var historyError: String?
    private(set) var usersError: String?
    private(set) var openError: String?
    private(set) var shareError: String?
    private(set) var actionError: String?
    private(set) var notice: String?
    private(set) var isMutating = false
    private(set) var isPreparingPlayback = false
    private(set) var confirmation: ServerPlaybackSessionMutation?
    private(set) var playbackConfirmation: ServerHistoricalPlaybackRequest?
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var usersGeneration = UUID()
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var shareGeneration = UUID()
    @ObservationIgnored private var playbackGeneration = UUID()
    @ObservationIgnored private var loadedQuery: ServerPlaybackSessionsQuery?
    @ObservationIgnored private var historyTask: Task<AdminPlaybackSessionPage, Error>?
    @ObservationIgnored private var usersTask: Task<[AdminUser], Error>?
    @ObservationIgnored private var openTask: Task<AdminPlaybackSessionSnapshot, Error>?
    @ObservationIgnored private var shareTask: Task<AdminPlaybackSessionSnapshot, Error>?
    @ObservationIgnored private var playbackTask: Task<LibraryItem, Error>?
    @ObservationIgnored private var consumedConfirmations: Set<UUID> = []

    init(targetUserID: String? = nil) { self.targetUserID = targetUserID }
    var historyRows: [AdminPlaybackSession] { loadedQuery == query ? history?.sessions ?? [] : [] }
    var selectedRows: [AdminPlaybackSession] { historyRows.filter { selectedIDs.contains($0.id) } }
    var canBatchDelete: Bool { source.map { AdminPlaybackSessionPolicy.canBatchDelete(selectedRows, actor: $0.actor) } == true && !isMutating }
    func isBound(to store: AppStore) -> Bool { source?.isCurrent(store: store) == true }
    func canDelete(_ row: AdminPlaybackSession, kind: AdminPlaybackSessionKind) -> Bool {
        source.map { AdminPlaybackSessionPolicy.canDelete(row, kind: kind, actor: $0.actor) } == true && !isMutating
    }
    func canClose(_ row: AdminPlaybackSession, kind: AdminPlaybackSessionKind) -> Bool {
        source.map { AdminPlaybackSessionPolicy.canClose(row, kind: kind, actor: $0.actor, serverVersion: $0.version) } == true && !isMutating
    }
    func cancel() {
        lifecycle = UUID(); invalidateHistory(); usersGeneration = UUID(); openGeneration = UUID(); shareGeneration = UUID(); playbackGeneration = UUID()
        usersTask?.cancel(); openTask?.cancel(); shareTask?.cancel(); playbackTask?.cancel()
        usersTask = nil; openTask = nil; shareTask = nil; playbackTask = nil
        source = nil; history = nil; loadedQuery = nil; users = []; openSessions = []; shareSessions = []
        detail = nil; selectedIDs = []; confirmation = nil; playbackConfirmation = nil; consumedConfirmations = []
        historyLoading = false; usersLoading = false; openLoading = false; shareLoading = false; isMutating = false; isPreparingPlayback = false
        historyError = nil; usersError = nil; openError = nil; shareError = nil; actionError = nil; notice = nil
    }
    @discardableResult func bind(store: AppStore, source expected: ServerPlaybackSessionsSource) -> Bool {
        guard !Task.isCancelled, expected.isCurrent(store: store) else { return false }
        if source != expected { cancel(); source = expected; query = .init() }
        return true
    }
    func queryChanged() {
        invalidateHistory(); history = nil; loadedQuery = nil; selectedIDs = []; detail = nil
        playbackGeneration = UUID(); playbackTask?.cancel(); playbackTask = nil; isPreparingPlayback = false
        confirmation = nil; playbackConfirmation = nil; revision = UUID()
    }
    func changeSort(_ sort: AdminPlaybackSessionSort) {
        if query.sort == sort { query.descending.toggle() } else { query.sort = sort }
        queryChanged()
    }
    private func invalidateHistory() { historyGeneration = UUID(); historyTask?.cancel(); historyTask = nil; historyLoading = false }
    private func current(_ store: AppStore, _ expected: ServerPlaybackSessionsSource, _ generation: UUID, _ attempt: UUID) -> Bool {
        !Task.isCancelled && generation == attempt && source == expected && expected.isCurrent(store: store)
    }
    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled
    }
    func loadHistory(store: AppStore, source expected: ServerPlaybackSessionsSource, query requested: ServerPlaybackSessionsQuery, force: Bool = false) async {
        guard !isMutating, bind(store: store, source: expected), query == requested else { return }
        if !force, loadedQuery == requested, history != nil, historyError == nil { return }
        guard requested.page >= 0, [10, 20, 25, 50, 100].contains(requested.limit),
              requested.userID.map(AdminPlaybackSessionPolicy.isValidIdentifier) != false,
              targetUserID.map(AdminPlaybackSessionPolicy.isValidIdentifier) != false else {
            historyError = L10n.tr("收听会话的用户筛选标识无效。请重新选择用户。"); return
        }
        invalidateHistory(); let attempt = UUID(); historyGeneration = attempt
        selectedIDs = []; confirmation = nil; revision = UUID()
        if loadedQuery != requested { history = nil }
        loadedQuery = requested; historyLoading = true; historyError = nil
        let target = targetUserID
        let task = Task {
            try Task.checkCancellation()
            if let target { return try await expected.client.userListeningHistory(id: target, page: requested.page, limit: requested.limit) }
            return try await expected.client.adminPlaybackSessions(page: requested.page, limit: requested.limit, userID: requested.userID, sort: requested.sort, descending: requested.descending)
        }; historyTask = task
        defer { task.cancel(); if historyGeneration == attempt { historyTask = nil; historyLoading = false } }
        do {
            var value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, historyGeneration, attempt), query == requested else { return }
            try validatePage(value, requested: requested)
            // Deleting the final page or an external change can invalidate a page.
            // Clamp once; never turn a failed GET into another mutation.
            var adoptedQuery = requested
            if requested.page > 0, requested.page >= max(1, value.numPages) {
                var corrected = requested; corrected.page = max(0, value.numPages - 1)
                if let target { value = try await expected.client.userListeningHistory(id: target, page: corrected.page, limit: corrected.limit) }
                else { value = try await expected.client.adminPlaybackSessions(page: corrected.page, limit: corrected.limit, userID: corrected.userID, sort: corrected.sort, descending: corrected.descending) }
                guard current(store, expected, historyGeneration, attempt), query == requested else { return }
                try validatePage(value, requested: corrected)
                adoptedQuery = corrected
            }
            history = value; loadedQuery = adoptedQuery; query = adoptedQuery
        } catch {
            if current(store, expected, historyGeneration, attempt), !Self.cancelled(error) { historyError = L10n.error(error) }
        }
    }
    private func validatePage(_ value: AdminPlaybackSessionPage, requested: ServerPlaybackSessionsQuery) throws {
        let target = targetUserID ?? requested.userID
        guard value.page == requested.page, value.itemsPerPage == requested.limit, value.total >= 0, value.numPages >= 0,
              target.map({ value.userId == nil || value.userId == $0 }) != false,
              value.sessions.allSatisfy({ row in target.map { (row.userId == nil || row.userId == $0) && (row.user?.id == nil || row.user?.id == $0) } ?? true }) else { throw ABSError.invalidResponse }
    }
    func loadUsers(store: AppStore, source expected: ServerPlaybackSessionsSource) async {
        guard targetUserID == nil, bind(store: store, source: expected) else { return }
        let attempt = UUID(); usersGeneration = attempt; usersTask?.cancel(); usersLoading = true; usersError = nil
        let task = Task { try Task.checkCancellation(); return try await expected.client.adminUsers() }; usersTask = task
        defer { task.cancel(); if usersGeneration == attempt { usersTask = nil; usersLoading = false } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, usersGeneration, attempt) else { return }; users = value
        } catch { if current(store, expected, usersGeneration, attempt), !Self.cancelled(error) { usersError = L10n.error(error) } }
    }
    func loadSnapshot(store: AppStore, source expected: ServerPlaybackSessionsSource, kind: AdminPlaybackSessionKind) async {
        guard targetUserID == nil, kind == .open || kind == .share, !isMutating, bind(store: store, source: expected) else { return }
        let attempt = UUID()
        if kind == .open { openGeneration = attempt; openTask?.cancel(); openLoading = true; openError = nil }
        else { shareGeneration = attempt; shareTask?.cancel(); shareLoading = true; shareError = nil }
        let task = Task { try Task.checkCancellation(); return try await expected.client.adminPlaybackSessionSnapshot() }
        if kind == .open { openTask = task } else { shareTask = task }
        defer {
            task.cancel()
            if kind == .open, openGeneration == attempt { openTask = nil; openLoading = false }
            if kind == .share, shareGeneration == attempt { shareTask = nil; shareLoading = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, kind == .open ? openGeneration : shareGeneration, attempt) else { return }
            if kind == .open { openSessions = value.sessions } else { shareSessions = value.shareSessions }
        } catch {
            if current(store, expected, kind == .open ? openGeneration : shareGeneration, attempt), !Self.cancelled(error) {
                if kind == .open { openError = L10n.error(error) } else { shareError = L10n.error(error) }
            }
        }
    }
    func prepareDeletion(_ row: AdminPlaybackSession) {
        guard let source, canDelete(row, kind: .history), historyRows.contains(where: { $0.id == row.id }) else { return }
        confirmation = .init(source: source, rows: [row], action: .deleteOne, revision: revision); playbackConfirmation = nil; actionError = nil
    }
    func prepareBatchDeletion() {
        guard let source, canBatchDelete else { return }
        confirmation = .init(source: source, rows: selectedRows, action: .deleteBatch, revision: revision); playbackConfirmation = nil; actionError = nil
    }
    func prepareClosure(_ row: AdminPlaybackSession) {
        guard let source, canClose(row, kind: .open), openSessions.contains(where: { $0.id == row.id }) else { return }
        confirmation = .init(source: source, rows: [row], action: .close, revision: revision); playbackConfirmation = nil; actionError = nil
    }
    func cancelConfirmation() { confirmation = nil; playbackConfirmation = nil; playbackGeneration = UUID(); playbackTask?.cancel(); isPreparingPlayback = false }
    func confirm(_ request: ServerPlaybackSessionMutation, store: AppStore) async {
        guard !isMutating, confirmation?.id == request.id, !consumedConfirmations.contains(request.id),
              request.revision == revision, request.source == source, request.source.isCurrent(store: store), allowed(request) else { return }
        consumedConfirmations.insert(request.id); confirmation = nil; isMutating = true; actionError = nil; notice = nil
        let life = lifecycle
        var leaseAcquired = false
        var leaseFinished = false
        defer {
            if lifecycle == life { isMutating = false }
            if leaseAcquired && !leaseFinished { Task { await store.finishPlaybackSessionMutation(ids: request.ids, source: request.source) } }
        }
        do {
            try await store.preparePlaybackSessionMutation(ids: request.ids, source: request.source, deleting: request.action != .close)
            leaseAcquired = true
            guard !Task.isCancelled, lifecycle == life, request.revision == revision, request.source.isCurrent(store: store), allowed(request) else { throw CancellationError() }
            invalidateHistory(); openGeneration = UUID(); openTask?.cancel(); openLoading = false
            switch request.action {
            case .deleteOne: try await request.source.client.deletePlaybackSession(id: request.rows[0].id)
            case .deleteBatch: try await request.source.client.deletePlaybackSessions(ids: request.rows.map(\.id))
            case .close: try await request.source.client.closeAdminPlaybackSession(id: request.rows[0].id)
            }
            var completionError: Error?
            do { try await store.completePlaybackSessionMutation(ids: request.ids, source: request.source, deleted: request.action != .close) }
            catch { completionError = error }
            await store.finishPlaybackSessionMutation(ids: request.ids, source: request.source); leaseFinished = true
            guard !Task.isCancelled, lifecycle == life, request.source.isCurrent(store: store) else { return }
            if request.action != .close { history?.sessions.removeAll { request.ids.contains($0.id) }; selectedIDs.subtract(request.ids) }
            openSessions.removeAll { request.ids.contains($0.id) }
            if detail.map({ request.ids.contains($0.session.id) }) == true { detail = nil }
            notice = request.action == .close ? L10n.tr("服务器已确认关闭会话。") : L10n.tr("服务器已确认删除所选收听记录。")
            if let completionError, !Self.cancelled(completionError) {
                actionError = L10n.format("服务器操作已完成，本机收尾失败：%1$@。请重试本机同步，不要重复服务器操作。", L10n.error(completionError))
            }
            guard !Task.isCancelled, lifecycle == life, request.source.isCurrent(store: store) else { return }
            isMutating = false
            await loadHistory(store: store, source: request.source, query: query, force: true)
            if targetUserID == nil { await loadSnapshot(store: store, source: request.source, kind: .open) }
        } catch {
            if leaseAcquired { await store.finishPlaybackSessionMutation(ids: request.ids, source: request.source); leaseFinished = true }
            if lifecycle == life, request.source.isCurrent(store: store), !Self.cancelled(error) {
                actionError = L10n.format("操作未确认完成：%1$@。请刷新记录核对后再操作。", L10n.error(error))
            }
        }
    }
    private func allowed(_ request: ServerPlaybackSessionMutation) -> Bool {
        switch request.action {
        case .deleteOne: request.rows.count == 1 && AdminPlaybackSessionPolicy.canDelete(request.rows[0], kind: .history, actor: request.source.actor)
        case .deleteBatch: AdminPlaybackSessionPolicy.canBatchDelete(request.rows, actor: request.source.actor)
        case .close: request.rows.count == 1 && AdminPlaybackSessionPolicy.canClose(request.rows[0], kind: .open, actor: request.source.actor, serverVersion: request.source.version)
        }
    }
    func preparePlayback(_ row: AdminPlaybackSession, kind: AdminPlaybackSessionKind, store: AppStore) async {
        guard !isMutating, let expected = source, expected.isCurrent(store: store), contains(row, kind: kind),
              let itemID = row.libraryItemId, !itemID.isEmpty, let position = row.currentTime, position.isFinite, position >= 0 else { return }
        playbackGeneration = UUID(); let attempt = playbackGeneration; playbackTask?.cancel()
        isPreparingPlayback = true; actionError = nil; confirmation = nil; playbackConfirmation = nil
        let task = Task { try Task.checkCancellation(); return try await expected.client.item(id: itemID) }; playbackTask = task
        defer { task.cancel(); if playbackGeneration == attempt { playbackTask = nil; isPreparingPlayback = false } }
        do {
            let item = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, playbackGeneration, attempt) else { return }
            guard item.id == itemID, !item.libraryId.isEmpty, !item.isMissing, !item.isInvalid,
                  expected.canAccess(item),
                  row.episodeId.map({ id in item.mediaType == "podcast" && item.media.episodes.contains { $0.id == id } }) ?? (item.mediaType == "book") else { throw ABSError.invalidResponse }
            playbackConfirmation = .init(source: expected, item: item, episodeID: row.episodeId, position: position, title: row.displayTitle ?? item.title)
        } catch { if current(store, expected, playbackGeneration, attempt), !Self.cancelled(error) { actionError = L10n.error(error) } }
    }
    func confirmPlayback(_ request: ServerHistoricalPlaybackRequest, store: AppStore) async {
        guard !isMutating, playbackConfirmation?.id == request.id, !consumedConfirmations.contains(request.id),
              request.source == source, request.source.isCurrent(store: store) else { return }
        consumedConfirmations.insert(request.id); playbackConfirmation = nil; isMutating = true; actionError = nil
        let life = lifecycle
        defer { if lifecycle == life { isMutating = false } }
        do { try await store.playHistoricalSession(request) }
        catch { if lifecycle == life, request.source.isCurrent(store: store), !Self.cancelled(error) { actionError = L10n.error(error) } }
    }
    private func contains(_ row: AdminPlaybackSession, kind: AdminPlaybackSessionKind) -> Bool {
        switch kind { case .history: historyRows.contains { $0.id == row.id }; case .open: openSessions.contains { $0.id == row.id }; case .share: shareSessions.contains { $0.id == row.id } }
    }

}
