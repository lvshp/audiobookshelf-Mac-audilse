import Foundation
import Observation
import ShelfCore

@MainActor @Observable final class ManagementOperation {
    var isBusy = false
    var error: String?
    var notice: String?
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var client: ABSClient?
    @ObservationIgnored private var partition: AccountPartition?
    @ObservationIgnored private var accountOperationID: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cancelWork: (@Sendable () -> Void)?
    func bind(_ store: AppStore) { cancelWork?(); cancelWork = nil; self.store = store; client = store.client; partition = store.partition; accountOperationID = store.accountOperationID; generation = UUID(); isBusy = false; error = nil; notice = nil }
    func cancel() { cancelWork?(); cancelWork = nil; generation = UUID(); client = nil; partition = nil; accountOperationID = nil; isBusy = false }
    var sourceID: UUID? { current(generation) ? generation : nil }
    var isCurrentSource: Bool { current(generation) }
    private func current(_ expected: UUID) -> Bool {
        guard expected == generation, let store, let client, let partition, let profile = store.profile,
              store.partition == partition, store.client === client, partition.serverID == profile.id,
              store.accountOperationID == accountOperationID, store.user?.id == partition.userID,
              store.user?.isActive == true, !store.isOffline, !store.isConnecting,
              store.serverRecovery == nil, !store.recoveryBusy else { return false }
        return true
    }
    func allows(_ action: AdminAction) -> Bool {
        guard current(generation), let user = store?.user else { return false }
        return AdminPolicy.allows(action, user: user)
    }
    func run<T: Sendable>(_ action: AdminAction? = nil, requiring additionalActions: [AdminAction] = [], expectedSource: UUID? = nil, work: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async {
        guard !isBusy else { return }
        if let expectedSource, expectedSource != generation { return }
        let attempt = generation
        guard current(attempt), let client, store?.isOffline == false else { error = L10n.tr("请连接服务器后管理内容。"); return }
        let actions = action.map { [$0] } ?? []
        guard (actions + additionalActions).allSatisfy(allows) else { error = L10n.error(AdminFeatureError.permissionDenied); return }
        isBusy = true; error = nil; notice = nil
        let worker = Task { try Task.checkCancellation(); return try await work(client) }
        cancelWork = { worker.cancel() }
        defer { worker.cancel(); if attempt == generation { isBusy = false; cancelWork = nil } }
        do {
            try Task.checkCancellation()
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard current(attempt), (actions + additionalActions).allSatisfy(allows) else { return }
            try Task.checkCancellation()
            apply(result)
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch { if current(attempt), !Task.isCancelled { self.error = L10n.error(error) } }
    }
    static func diagnostic<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? L10n.tr("无法显示诊断数据。")
    }
}

struct ManagementConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var destructive = false
    let operation: @MainActor () async -> Void
}
