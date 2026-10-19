import Foundation
import Observation
import ShelfCore

/// The administrator statistics cover the whole server, independent of the
/// selected library. The fixed official API permits active admin and root users.
struct ServerStatisticsSource: Hashable, Sendable {
    let partition: AccountPartition
    let profileID: UUID
    let client: ABSClient
    let userID: String
    let userType: String
    let createdAt: Double?
    let serverVersion: String?

    @MainActor init?(store: AppStore) {
        guard !store.isConnecting, !store.isOffline, !store.isDemo,
              let user = store.user, AdminPolicy.allows(.manageServer, user: user),
              let partition = store.partition, let profile = store.profile, let client = store.client,
              partition.serverID == profile.id, partition.userID == user.id else { return nil }
        self.partition = partition; profileID = profile.id; self.client = client
        userID = user.id; userType = user.type; serverVersion = profile.serverVersion
        createdAt = user.createdAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.partition == rhs.partition && lhs.profileID == rhs.profileID && lhs.client === rhs.client &&
        lhs.userID == rhs.userID && lhs.userType == rhs.userType && lhs.createdAt == rhs.createdAt && lhs.serverVersion == rhs.serverVersion
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(partition); hasher.combine(profileID); hasher.combine(ObjectIdentifier(client))
        hasher.combine(userID); hasher.combine(userType); hasher.combine(createdAt); hasher.combine(serverVersion)
    }
    @MainActor func isCurrent(store: AppStore) -> Bool { Self(store: store) == self }
}

@MainActor @Observable final class ServerStatisticsModel {
    var selectedYear = Calendar(identifier: .gregorian).component(.year, from: Date())
    private(set) var availableYears: [Int] = []
    private(set) var yearly: AdminYearlyStatistics?
    private(set) var storage: ServerStorageStatistics?
    private(set) var isYearLoading = false
    private(set) var isStorageLoading = false
    private(set) var yearError: String?
    private(set) var storageError: String?
    private(set) var yearUpdatedAt: Date?
    private(set) var storageUpdatedAt: Date?
    private var source: ServerStatisticsSource?
    private var boundYear: Int?
    @ObservationIgnored private var yearGeneration = UUID()
    @ObservationIgnored private var storageGeneration = UUID()
    @ObservationIgnored private var yearTask: Task<AdminYearlyStatistics, Error>?
    @ObservationIgnored private var storageTask: Task<ServerStorageStatistics, Error>?

    func isBound(to store: AppStore) -> Bool { source?.isCurrent(store: store) == true }
    func isYearBound(to store: AppStore) -> Bool { isBound(to: store) && boundYear == selectedYear }

    func cancel() {
        yearGeneration = UUID(); storageGeneration = UUID()
        yearTask?.cancel(); yearTask = nil; storageTask?.cancel(); storageTask = nil
        source = nil; boundYear = nil; yearly = nil; storage = nil; availableYears = []
        yearError = nil; storageError = nil; yearUpdatedAt = nil; storageUpdatedAt = nil
        isYearLoading = false; isStorageLoading = false
    }

    /// Binding is synchronous so the two independent SwiftUI loading tasks can
    /// share a context without cancelling one another. An old task cannot bind
    /// a different, newer live account on entry.
    @discardableResult func bind(store: AppStore, source expected: ServerStatisticsSource?, now: Date = Date()) -> Bool {
        guard !Task.isCancelled, ServerStatisticsSource(store: store) == expected else { return false }
        guard let expected else { cancel(); return false }
        let changed = source != expected
        if changed { cancel(); source = expected }
        let calendar = Calendar(identifier: .gregorian)
        let current = calendar.component(.year, from: now)
        let created = expected.createdAt.map { calendar.component(.year, from: Date(timeIntervalSince1970: $0 / 1_000)) }
        let oldest = max(2000, min(current, created ?? current))
        availableYears = Array((oldest...current).reversed())
        if changed || !availableYears.contains(selectedYear) {
            selectedYear = calendar.component(.month, from: now) < 12 && availableYears.contains(current - 1) ? current - 1 : current
        }
        return true
    }

    func loadYear(store: AppStore, source expected: ServerStatisticsSource?, year: Int) async {
        guard bind(store: store, source: expected), let expected,
              selectedYear == year, availableYears.contains(year) else { return }
        let operation = UUID(); yearGeneration = operation
        yearTask?.cancel(); yearTask = nil
        if boundYear != year { yearly = nil; yearUpdatedAt = nil }
        boundYear = year; yearError = nil; isYearLoading = true
        func current() -> Bool {
            yearGeneration == operation && source == expected && expected.isCurrent(store: store) &&
            selectedYear == year && boundYear == year && !Task.isCancelled
        }
        defer { if yearGeneration == operation { isYearLoading = false; yearTask = nil } }
        let task = Task {
            try Task.checkCancellation()
            return try await expected.client.adminYearlyStatistics(year: year)
        }
        yearTask = task
        defer { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard current() else { return }
            yearly = result; yearUpdatedAt = Date()
        } catch {
            guard current(), !Self.isCancellation(error) else { return }
            if case ABSError.http(status: 404, message: _) = error { yearError = L10n.tr("此服务器未提供服务器年度回顾。") }
            else { yearError = L10n.error(error) }
        }
    }

    func loadStorage(store: AppStore, source expected: ServerStatisticsSource?) async {
        guard bind(store: store, source: expected), let expected else { return }
        let operation = UUID(); storageGeneration = operation
        storageTask?.cancel(); storageTask = nil
        storageError = nil; isStorageLoading = true
        func current() -> Bool {
            storageGeneration == operation && source == expected && expected.isCurrent(store: store) && !Task.isCancelled
        }
        defer { if storageGeneration == operation { isStorageLoading = false; storageTask = nil } }
        let task = Task {
            try Task.checkCancellation()
            return try await expected.client.serverStorageStatistics()
        }
        storageTask = task
        defer { task.cancel() }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard current() else { return }
            storage = result; storageUpdatedAt = Date()
        } catch {
            guard current(), !Self.isCancellation(error) else { return }
            if case ABSError.http(status: 404, message: _) = error { storageError = L10n.tr("此服务器未提供存储统计。") }
            else { storageError = L10n.error(error) }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled
    }
}
