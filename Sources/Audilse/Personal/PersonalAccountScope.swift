import Foundation
import Observation
import AudilseCore

struct PersonalAccountContext: Sendable {
    let client: ABSClient
    let partition: AccountPartition
    let profile: ServerProfile
    let user: UserAccount
    let generation: UUID
}

struct PersonalConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var destructive = false
    let action: @MainActor () async -> Void
}

@MainActor @Observable final class PersonalAccountScope {
    let store: AppStore
    var isWorking = false
    var error: String?
    var notice: String?
    var confirmation: PersonalConfirmation?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var boundClient: ABSClient?
    @ObservationIgnored private var boundPartition: AccountPartition?
    @ObservationIgnored private var cancelOperation: (() -> Void)?
    init(store: AppStore) { self.store = store; bind() }
    var identity: String {
        (store.profile?.id.uuidString ?? "") + ":" + (store.user?.id ?? "") + ":" + (store.client.map { String(describing: ObjectIdentifier($0)) } ?? "")
    }
    var canUseAccount: Bool { store.user?.isActive == true && !store.isDemo && store.partition != nil }
    var canUseBoundAccount: Bool { canUseAccount && boundPartition == store.partition && boundClient === store.client }
    var canUseServer: Bool { canUseAccount && !store.isOffline && store.client != nil }
    var capabilities: PersonalCapabilities? { store.user.map { .init(user: $0, version: store.profile?.serverVersion) } }
    func bind() { cancelOperation?(); cancelOperation = nil; generation = UUID(); boundClient = store.client; boundPartition = store.partition; isWorking = false; error = nil; notice = nil; confirmation = nil }
    func cancel() { cancelOperation?(); cancelOperation = nil; generation = UUID(); boundClient = nil; boundPartition = nil; isWorking = false; confirmation = nil }
    func context() -> PersonalAccountContext? {
        guard canUseServer, capabilities?.isSupported == true,
              let client = boundClient, client === store.client, let partition = boundPartition, partition == store.partition,
              let profile = store.profile, let user = store.user else { return nil }
        return .init(client: client, partition: partition, profile: profile, user: user, generation: generation)
    }
    func isCurrent(_ context: PersonalAccountContext) -> Bool {
        context.generation == generation && store.partition == context.partition && store.client === context.client && canUseServer
    }
    @discardableResult func run<T: Sendable>(_ context: PersonalAccountContext, operation: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async -> Bool {
        guard !isWorking, isCurrent(context) else { return false }
        isWorking = true; error = nil; notice = nil
        let task = Task { try Task.checkCancellation(); return try await operation(context.client) }
        cancelOperation = { task.cancel() }
        defer { task.cancel(); if context.generation == generation { isWorking = false; cancelOperation = nil } }
        do {
            try Task.checkCancellation()
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(context) else { return false }
            try Task.checkCancellation()
            apply(result)
            return true
        } catch is CancellationError {
        } catch ABSError.sessionChanged {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch { if isCurrent(context) { self.error = L10n.error(error) } }
        return false
    }
    func confirm(_ confirmation: PersonalConfirmation) { guard !isWorking else { return }; self.confirmation = confirmation }
}
