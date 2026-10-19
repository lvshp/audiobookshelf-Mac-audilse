import Foundation
import Observation
import AudilseCore

struct ServerTasksSource: Hashable, Sendable {
    let partition: AccountPartition
    let profile: ServerProfile
    let client: ABSClient
    let userID: String
    let userType: String
    @MainActor init?(store: AppStore) {
        guard !store.isConnecting, !store.isOffline, !store.isDemo,
              let user = store.user, AdminPolicy.allows(.manageServer, user: user),
              let partition = store.partition, let profile = store.profile, let client = store.client,
              partition.serverID == profile.id, partition.userID == user.id else { return nil }
        self.partition = partition; self.profile = profile; self.client = client
        userID = user.id; userType = user.type
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.partition == rhs.partition && lhs.profile == rhs.profile && lhs.client === rhs.client && lhs.userID == rhs.userID && lhs.userType == rhs.userType
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(partition); hasher.combine(profile); hasher.combine(ObjectIdentifier(client)); hasher.combine(userID); hasher.combine(userType)
    }
    @MainActor func isCurrent(store: AppStore) -> Bool { Self(store: store) == self }
}

@MainActor protocol ServerTasksConnection: AnyObject {
    var isConnected: Bool { get }
    func connect(profile: ServerProfile, client: ABSClient) async throws -> AsyncStream<RealtimeEvent>
    func disconnect()
    func cancelScan(libraryID: String) throws
}
/// A page subscribes to the account's existing socket; closing it cannot drop
/// background completion events or disconnect other realtime consumers.
@MainActor final class SharedServerTasksConnection: ServerTasksConnection {
    private weak var store: AppStore?
    private let subscriptionID = UUID()
    init(store: AppStore) { self.store = store }
    var isConnected: Bool { store?.serverTaskActivity.isAuthenticated == true }
    func connect(profile: ServerProfile, client: ABSClient) async throws -> AsyncStream<RealtimeEvent> {
        guard let store else { throw ABSError.sessionChanged }
        return try store.subscribeServerTaskActivity(profile: profile, client: client, id: subscriptionID)
    }
    func disconnect() { store?.unsubscribeServerTaskActivity(id: subscriptionID) }
    func cancelScan(libraryID: String) throws {
        guard let store else { throw ABSError.sessionChanged }
        try store.cancelServerActivityScan(libraryID: libraryID)
    }
}

struct ServerScanCancellation: Identifiable, Sendable {
    let id: String
    let libraryID: String
    let libraryName: String
    let source: ServerTasksSource
}

@MainActor @Observable final class ServerTasksModel {
    enum ConnectionStatus: Equatable { case connecting, connected, disconnected, failed }
    private(set) var state = ServerTasksState()
    private(set) var source: ServerTasksSource?
    private(set) var connectionStatus: ConnectionStatus = .disconnected
    private(set) var isRefreshing = false
    private(set) var snapshotError: String?
    private(set) var connectionError: String?
    private(set) var eventError: String?
    private(set) var cancellationError: String?
    private(set) var updatedAt: Date?
    private(set) var cancellationRequested: Set<String> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var snapshotGeneration = UUID()
    @ObservationIgnored private var journal = ServerTaskEventJournal()
    @ObservationIgnored private var connection: (any ServerTasksConnection)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<ServerTaskListing, Error>?
    @ObservationIgnored private let makeConnection: (@MainActor () -> any ServerTasksConnection)?
    @ObservationIgnored private let fetchSnapshot: @Sendable (ABSClient) async throws -> ServerTaskListing

    init(makeConnection: (@MainActor () -> any ServerTasksConnection)? = nil,
         fetchSnapshot: @escaping @Sendable (ABSClient) async throws -> ServerTaskListing = { try await $0.serverTasks() }) {
        self.makeConnection = makeConnection; self.fetchSnapshot = fetchSnapshot
    }
    func isBound(to store: AppStore) -> Bool { source?.isCurrent(store: store) == true }
    private func current(_ expected: ServerTasksSource, generation: UUID, store: AppStore) -> Bool {
        self.generation == generation && source == expected && expected.isCurrent(store: store)
    }
    func cancel() {
        generation = UUID(); snapshotGeneration = UUID()
        eventTask?.cancel(); eventTask = nil; automaticRefreshTask?.cancel(); automaticRefreshTask = nil
        snapshotTask?.cancel(); snapshotTask = nil
        connection?.disconnect(); connection = nil
        source = nil; state = .init(); journal = .init(); updatedAt = nil
        isRefreshing = false; connectionStatus = .disconnected
        snapshotError = nil; connectionError = nil; eventError = nil; cancellationError = nil; cancellationRequested = []
    }

    func start(store: AppStore, source expected: ServerTasksSource?) async {
        // A cancelled/obsolete SwiftUI task must never tear down a newer context.
        guard !Task.isCancelled, ServerTasksSource(store: store) == expected else { return }
        guard let expected else { cancel(); return }
        let retained = source == expected ? state : ServerTasksState()
        cancel(); source = expected; state = retained
        let attempt = generation
        let socket: any ServerTasksConnection = makeConnection?() ?? SharedServerTasksConnection(store: store)
        connection = socket; connectionStatus = .connecting
        eventTask = Task { [weak self] in
            defer { socket.disconnect() }
            do {
                try Task.checkCancellation()
                let events = try await socket.connect(profile: expected.profile, client: expected.client)
                guard !Task.isCancelled, self?.current(expected, generation: attempt, store: store) == true else { return }
                for await raw in events {
                    guard !Task.isCancelled, let self, self.current(expected, generation: attempt, store: store) else { return }
                    self.consume(raw, socket: socket, store: store, source: expected, generation: attempt)
                }
                if self?.current(expected, generation: attempt, store: store) == true, self?.connectionStatus != .failed {
                    self?.connectionStatus = .disconnected
                }
            } catch {
                guard !Task.isCancelled, let self, self.current(expected, generation: attempt, store: store), !Self.isCancellation(error) else { return }
                self.connectionStatus = .failed; self.connectionError = L10n.error(error)
            }
        }
        // HTTP remains usable even if the realtime channel fails to connect.
        await withTaskCancellationHandler(operation: {
            await refresh(store: store, source: expected)
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard self?.generation == attempt else { return }
                self?.cancel()
            }
        })
    }

    func refresh(store: AppStore, source expected: ServerTasksSource?) async {
        guard !Task.isCancelled, let expected, source == expected, expected.isCurrent(store: store) else { return }
        let attempt = generation, request = UUID()
        snapshotGeneration = request; snapshotTask?.cancel()
        journal = .init(); isRefreshing = true; snapshotError = nil; eventError = nil
        let fetch = fetchSnapshot
        let worker = Task { try Task.checkCancellation(); return try await fetch(expected.client) }
        snapshotTask = worker
        defer {
            worker.cancel()
            if snapshotGeneration == request { isRefreshing = false; snapshotTask = nil; journal = .init() }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, current(expected, generation: attempt, store: store), snapshotGeneration == request else { return }
            state.replaceSnapshot(result, replaying: journal)
            updatedAt = Date(); trimCancellationRequests()
        } catch {
            guard !Task.isCancelled, current(expected, generation: attempt, store: store), snapshotGeneration == request, !Self.isCancellation(error) else { return }
            snapshotError = L10n.error(error)
        }
    }

    private func consume(_ raw: RealtimeEvent, socket: any ServerTasksConnection, store: AppStore, source expected: ServerTasksSource, generation: UUID) {
        do {
            guard let event = try ServerTaskEvent.decode(raw) else { return }
            switch event {
            case .initialized(let identity):
                guard identity.userId == expected.userID else {
                    connectionStatus = .failed; connectionError = L10n.tr("任务连接返回了不同的账户身份。")
                    socket.disconnect(); return
                }
                connectionStatus = .connected; connectionError = nil; cancellationRequested = []
                // init/re-init has no task data. Refresh without blocking the
                // event consumer, so events during HTTP can be journalled.
                automaticRefreshTask?.cancel()
                automaticRefreshTask = Task { [weak self] in
                    guard !Task.isCancelled, let self, self.current(expected, generation: generation, store: store) else { return }
                    await self.refresh(store: store, source: expected)
                }
            case .disconnected:
                connectionStatus = .disconnected; cancellationRequested = []
            case .authenticationFailed:
                connectionStatus = .failed; connectionError = L10n.tr("任务实时连接认证失败，请重新连接。")
                socket.disconnect()
            default:
                if isRefreshing { journal.append(event) }
                state.apply(event); trimCancellationRequests()
            }
        } catch {
            eventError = L10n.tr("收到无法解析的任务消息，请刷新任务列表。")
        }
    }

    func cancellationTarget(taskID: String, source expected: ServerTasksSource?, store: AppStore) -> ServerScanCancellation? {
        guard let expected, source == expected, expected.isCurrent(store: store),
              connectionStatus == .connected, connection?.isConnected == true,
              !cancellationRequested.contains(taskID), let task = state.task(id: taskID), let libraryID = state.scanLibraryID(for: task) else { return nil }
        let name: String
        if case .string(let value) = task.data?["libraryName"], !value.isEmpty { name = value }
        else { name = store.libraries.first { $0.id == libraryID }?.name ?? libraryID }
        return .init(id: taskID, libraryID: libraryID, libraryName: name, source: expected)
    }
    @discardableResult func requestCancellation(_ target: ServerScanCancellation, store: AppStore) -> Bool {
        // The confirmation captures task, library and account. Revalidate all
        // three synchronously immediately before this no-ack Socket.IO emit.
        guard let current = cancellationTarget(taskID: target.id, source: target.source, store: store), current.libraryID == target.libraryID,
              let connection else { return false }
        cancellationError = nil
        do { try connection.cancelScan(libraryID: target.libraryID); cancellationRequested.insert(target.id); return true }
        catch { cancellationError = L10n.error(error); return false }
    }
    private func trimCancellationRequests() {
        cancellationRequested = cancellationRequested.filter { state.task(id: $0)?.isFinished == false }
    }
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled
    }
}
