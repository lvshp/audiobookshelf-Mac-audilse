import Foundation
import ShelfCore

@MainActor final class PodcastAccountSession {
    weak var store: AppStore?
    private(set) var client: ABSClient?
    private(set) var partition: AccountPartition?
    private var generation = UUID()
    private var operations: [UUID: () -> Void] = [:]
    func bind(_ store: AppStore) { operations.values.forEach { $0() }; operations = [:]; self.store = store; client = store.client; partition = store.partition; generation = UUID() }
    func cancel() { operations.values.forEach { $0() }; operations = [:]; generation = UUID(); client = nil; partition = nil }
    func run<T: Sendable>(_ expected: UUID, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try validate(expected)
        let task = Task { try Task.checkCancellation(); return try await operation() }
        let operationID = UUID()
        operations[operationID] = { task.cancel() }
        defer { task.cancel(); operations.removeValue(forKey: operationID) }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try validate(expected)
        return value
    }
    func snapshot(admin: Bool = false, requiring actions: [AdminAction] = []) throws -> (ABSClient, UUID) {
        guard let store, let client, let partition, store.partition == partition, store.client === client, !store.isOffline else { throw PodcastUIError.unavailable }
        guard let user = store.user, user.isActive, (!admin || AdminPolicy.allows(.manageServer, user: user)), actions.allSatisfy({ AdminPolicy.allows($0, user: user) }) else { throw PodcastUIError.permission }
        try Task.checkCancellation()
        return (client, generation)
    }
    func validate(_ expected: UUID) throws {
        guard isCurrent(expected) else { throw ABSError.sessionChanged }
        try Task.checkCancellation()
    }
    func isCurrent(_ expected: UUID) -> Bool {
        guard expected == generation, let store, let partition else { return false }
        return store.partition == partition && store.client === client
    }
}

enum PodcastUIError: Error, LocalizedError {
    case unavailable, permission, invalidPath, missingFeed, oversizedOPML, feedUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.tr("请连接服务器后管理播客。")
        case .permission: L10n.tr("此账户没有执行该操作的权限。")
        case .invalidPath: L10n.tr("请选择目标文件夹，并填写该文件夹内的服务器保存路径。")
        case .missingFeed: L10n.tr("请先解析有效的 RSS 地址。")
        case .oversizedOPML: L10n.tr("OPML 文件超出 10 MB 限制。")
        case .feedUnavailable: L10n.tr("服务器未能获取或解析此 RSS（HTTP 404）。请检查 RSS 地址和服务器网络连接，或稍后重试。")
        }
    }
}
