import Foundation
import Observation
import AudilseCore

/// Captured by the rendered management sheet and by every confirmation.
struct LibraryPersonalSource: Hashable, Sendable {
    let partition: AccountPartition?
    let clientID: ObjectIdentifier?
    let profileID: UUID?
    let libraryID: String
    let currentLibraryID: String?
    let revision: UUID
    let permissions: UserPermissions?
    let userType: String?
    let active: Bool
    let offline: Bool
    let connecting: Bool
    let demo: Bool
    let serverVersion: String?
    @MainActor init(store: AppStore, libraryID: String) {
        partition = store.partition; clientID = store.client.map(ObjectIdentifier.init)
        profileID = store.profile?.id; self.libraryID = libraryID; currentLibraryID = store.currentLibrary?.id; revision = store.libraryRevision
        permissions = store.user?.permissions; userType = store.user?.type; active = store.user?.isActive == true
        offline = store.isOffline; connecting = store.isConnecting; demo = store.isDemo
        serverVersion = store.profile?.serverVersion
    }
    @MainActor func isCurrent(_ store: AppStore) -> Bool {
        partition != nil && partition?.serverID == profileID && partition?.userID == store.user?.id && !offline && !connecting && !demo && active && clientID != nil &&
        store.libraries.contains(where: { $0.id == libraryID }) &&
        self == LibraryPersonalSource(store: store, libraryID: libraryID)
    }
}

struct LibraryPersonalConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var destructive = false
    let action: @MainActor () async -> Void
}

@MainActor @Observable final class LibraryPersonalScope {
    let store: AppStore
    let libraryID: String
    let entrySource: LibraryPersonalSource
    private(set) var source: LibraryPersonalSource?
    private(set) var generation = UUID()
    private(set) var isWorking = false
    var error: String?
    var notice: String?
    var confirmation: LibraryPersonalConfirmation?
    @ObservationIgnored private var cancelOperation: (() -> Void)?
    init(store: AppStore, libraryID: String) { self.store = store; self.libraryID = libraryID; entrySource = .init(store: store, libraryID: libraryID) }
    var identity: LibraryPersonalSource { LibraryPersonalSource(store: store, libraryID: libraryID) }
    var available: Bool { source?.isCurrent(store) == true }
    func bind() {
        cancel(); source = entrySource.isCurrent(store) ? entrySource : nil; error = nil; notice = nil
    }
    func cancel() {
        cancelOperation?(); cancelOperation = nil; generation = UUID()
        source = nil; isWorking = false; confirmation = nil
    }
    func context(requiring actions: [AdminAction] = []) throws -> (LibraryPersonalSource, ABSClient, UUID) {
        try Task.checkCancellation()
        guard let source, source.isCurrent(store), let client = store.client else { throw ABSError.sessionChanged }
        guard let user = store.user, actions.allSatisfy({ AdminPolicy.allows($0, user: user) }) else { throw AdminFeatureError.permissionDenied }
        return (source, client, generation)
    }
    func check(_ source: LibraryPersonalSource, _ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.source == source, self.generation == generation, source.isCurrent(store) else { throw ABSError.sessionChanged }
    }
    @discardableResult func run<T: Sendable>(source: LibraryPersonalSource, generation: UUID,
        operation: @escaping @MainActor () async throws -> T, apply: (T) -> Void) async -> Bool {
        guard !isWorking else { return false }
        do { try check(source, generation) } catch { return false }
        isWorking = true; error = nil; notice = nil
        let task = Task { try self.check(source, generation); return try await operation() }
        cancelOperation = { task.cancel() }
        defer {
            task.cancel()
            if self.generation == generation { isWorking = false; cancelOperation = nil }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try check(source, generation); apply(value); return true
        } catch is CancellationError {
        } catch ABSError.sessionChanged {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch { if self.generation == generation, source.isCurrent(store) { self.error = L10n.error(error) } }
        return false
    }
    func confirm(_ value: LibraryPersonalConfirmation) { guard available, !isWorking else { return }; confirmation = value }
}
