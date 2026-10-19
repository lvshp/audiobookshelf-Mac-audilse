import Foundation
import Observation
import ShelfCore

struct ServerUserDetailSource: Hashable, Sendable {
    let accountSource: ServerPlaybackSessionsSource
    let partition: AccountPartition
    let profileID: UUID
    let client: ABSClient
    let administratorID: String
    let administratorType: String
    let userID: String
    let version: String?

    @MainActor init?(store: AppStore, userID: String) {
        guard AdminPlaybackSessionPolicy.isValidIdentifier(userID), let accountSource = ServerPlaybackSessionsSource(store: store),
              !store.isConnecting, !store.isOffline, !store.isDemo,
              let user = store.user, AdminPolicy.allows(.manageServer, user: user),
              let partition = store.partition, let profile = store.profile, let client = store.client,
              partition.serverID == profile.id, partition.userID == user.id else { return nil }
        self.accountSource = accountSource; self.partition = partition; profileID = profile.id; self.client = client
        administratorID = user.id; administratorType = user.type; self.userID = userID; version = profile.serverVersion
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountSource == rhs.accountSource && lhs.partition == rhs.partition && lhs.profileID == rhs.profileID && lhs.client === rhs.client &&
        lhs.administratorID == rhs.administratorID && lhs.administratorType == rhs.administratorType &&
        lhs.userID == rhs.userID && lhs.version == rhs.version
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(accountSource); hasher.combine(partition); hasher.combine(profileID); hasher.combine(ObjectIdentifier(client))
        hasher.combine(administratorID); hasher.combine(administratorType); hasher.combine(userID); hasher.combine(version)
    }
    @MainActor func isCurrent(store: AppStore) -> Bool { Self(store: store, userID: userID) == self }
}

@MainActor @Observable final class ServerUserDetailModel {
    var historyPage = 0
    private(set) var user: AdminUser?
    private(set) var savedProgress: [AdminUserProgress]?
    private(set) var statistics: ListeningStatistics?
    private(set) var history: AdminPlaybackSessionPage?
    private(set) var isProgressLoading = false
    private(set) var isStatisticsLoading = false
    private(set) var isHistoryLoading = false
    private(set) var progressError: String?
    private(set) var statisticsError: String?
    private(set) var historyError: String?
    private var source: ServerUserDetailSource?
    private var loadedHistoryPage: Int?
    @ObservationIgnored private var progressGeneration = UUID()
    @ObservationIgnored private var statisticsGeneration = UUID()
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var progressTask: Task<AdminUser, Error>?
    @ObservationIgnored private var statisticsTask: Task<ListeningStatistics, Error>?
    @ObservationIgnored private var historyTask: Task<AdminPlaybackSessionPage, Error>?

    func isBound(to store: AppStore, source expected: ServerUserDetailSource) -> Bool { source == expected && expected.isCurrent(store: store) }
    func isHistoryBound(to store: AppStore, source expected: ServerUserDetailSource) -> Bool { isBound(to: store, source: expected) && loadedHistoryPage == historyPage }
    func cancel() {
        progressGeneration = UUID(); statisticsGeneration = UUID(); historyGeneration = UUID()
        progressTask?.cancel(); statisticsTask?.cancel(); historyTask?.cancel()
        progressTask = nil; statisticsTask = nil; historyTask = nil; source = nil
        user = nil; savedProgress = nil; statistics = nil; history = nil; loadedHistoryPage = nil
        progressError = nil; statisticsError = nil; historyError = nil
        isProgressLoading = false; isStatisticsLoading = false; isHistoryLoading = false
    }
    @discardableResult func bind(store: AppStore, source expected: ServerUserDetailSource) -> Bool {
        guard !Task.isCancelled, expected.isCurrent(store: store) else { return false }
        if source != expected { cancel(); source = expected; historyPage = 0 }
        return true
    }
    func loadProgress(store: AppStore, source expected: ServerUserDetailSource) async {
        guard bind(store: store, source: expected) else { return }
        let operation = UUID(); progressGeneration = operation; progressTask?.cancel()
        isProgressLoading = true; progressError = nil
        let task = Task { try Task.checkCancellation(); return try await expected.client.adminUser(id: expected.userID) }; progressTask = task
        defer { task.cancel(); if progressGeneration == operation { progressTask = nil; isProgressLoading = false } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, progressGeneration, operation) else { return }
            guard value.id == expected.userID,
                  value.mediaProgress?.allSatisfy({ $0.userId == nil || $0.userId == expected.userID }) != false else { throw ABSError.invalidResponse }
            let rows = await Task.detached(priority: .userInitiated) {
                value.mediaProgress?.sorted {
                    let left = $0.lastUpdate ?? 0, right = $1.lastUpdate ?? 0
                    return left == right ? $0.id < $1.id : left > right
                }
            }.value
            guard current(store, expected, progressGeneration, operation) else { return }
            user = value; savedProgress = rows
        } catch { if current(store, expected, progressGeneration, operation), !Self.cancelled(error) { progressError = L10n.error(error) } }
    }
    func loadStatistics(store: AppStore, source expected: ServerUserDetailSource) async {
        guard bind(store: store, source: expected) else { return }
        let operation = UUID(); statisticsGeneration = operation; statisticsTask?.cancel()
        isStatisticsLoading = true; statisticsError = nil
        let task = Task { try Task.checkCancellation(); return try await expected.client.userListeningStats(id: expected.userID) }; statisticsTask = task
        defer { task.cancel(); if statisticsGeneration == operation { statisticsTask = nil; isStatisticsLoading = false } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, statisticsGeneration, operation) else { return }; statistics = value
        } catch { if current(store, expected, statisticsGeneration, operation), !Self.cancelled(error) { statisticsError = L10n.error(error) } }
    }
    func loadHistory(store: AppStore, source expected: ServerUserDetailSource, page: Int) async {
        guard !Task.isCancelled, expected.isCurrent(store: store), historyPage == page, page >= 0,
              bind(store: store, source: expected), historyPage == page else { return }
        let operation = UUID(); historyGeneration = operation; historyTask?.cancel()
        if loadedHistoryPage != page { history = nil }
        loadedHistoryPage = page; isHistoryLoading = true; historyError = nil
        let task = Task { try Task.checkCancellation(); return try await expected.client.userListeningHistory(id: expected.userID, page: page, limit: 20) }; historyTask = task
        defer { task.cancel(); if historyGeneration == operation { historyTask = nil; isHistoryLoading = false } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current(store, expected, historyGeneration, operation), historyPage == page else { return }
            guard value.page == page, value.sessions.allSatisfy({ ($0.userId == nil || $0.userId == expected.userID) && ($0.user?.id == nil || $0.user?.id == expected.userID) }) else { throw ABSError.invalidResponse }
            history = value
        } catch { if current(store, expected, historyGeneration, operation), historyPage == page, !Self.cancelled(error) { historyError = L10n.error(error) } }
    }
    private func current(_ store: AppStore, _ expected: ServerUserDetailSource, _ generation: UUID, _ operation: UUID) -> Bool {
        !Task.isCancelled && generation == operation && isBound(to: store, source: expected)
    }
    private static func cancelled(_ error: Error) -> Bool { error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled }
}
