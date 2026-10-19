import Foundation
import Observation
import AudilseCore

struct LibraryStatisticsSource: Hashable, Sendable {
    let partition: AccountPartition
    let baseURL: URL
    let client: ABSClient
    let library: Library
    let userType: String
    let version: String?
    let revision: UUID

    @MainActor init?(store: AppStore, library: Library) {
        guard !store.isDemo, !store.isOffline, !store.isConnecting, !store.recoveryBusy,
              let user = store.user, user.isActive, user.isAdmin,
              let partition = store.partition, let profile = store.profile, let client = store.client,
              partition.serverID == profile.id, partition.userID == user.id,
              store.currentLibrary?.id == library.id,
              store.libraries.contains(where: { $0.id == library.id && $0.mediaType == library.mediaType }) else { return nil }
        self.partition = partition; baseURL = profile.baseURL; self.client = client; self.library = library
        userType = user.type; version = profile.serverVersion; revision = store.libraryRevision
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.partition == rhs.partition && lhs.baseURL == rhs.baseURL && lhs.client === rhs.client && lhs.library == rhs.library &&
        lhs.userType == rhs.userType && lhs.version == rhs.version && lhs.revision == rhs.revision
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(partition); hasher.combine(baseURL); hasher.combine(ObjectIdentifier(client)); hasher.combine(library)
        hasher.combine(userType); hasher.combine(version); hasher.combine(revision)
    }
    @MainActor func isCurrent(_ store: AppStore) -> Bool { Self(store: store, library: library) == self }
}

@MainActor @Observable final class LibraryStatisticsModel {
    private(set) var statistics: LibraryStatistics?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var updatedAt: Date?
    private(set) var source: LibraryStatisticsSource?
    private(set) var isOpeningItem = false
    private(set) var itemError: String?
    var openedItem: AudilseCore.LibraryItem?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var requestTask: Task<LibraryStatistics, Error>?
    @ObservationIgnored private var itemGeneration = UUID()
    @ObservationIgnored private var itemTask: Task<Void, Never>?

    func isBound(to store: AppStore, library: Library) -> Bool {
        source == LibraryStatisticsSource(store: store, library: library) && source != nil
    }
    func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil
        itemGeneration = UUID(); itemTask?.cancel(); itemTask = nil
        source = nil; statistics = nil; error = nil; updatedAt = nil; isLoading = false
        openedItem = nil; itemError = nil; isOpeningItem = false
    }

    func load(store: AppStore, library: Library, expected: LibraryStatisticsSource?) async {
        // A cancelled, late SwiftUI task cannot clear a newer screen's state.
        guard !Task.isCancelled else { return }
        guard expected == LibraryStatisticsSource(store: store, library: library) else { return }
        guard let expected else { cancel(); return }
        let retain = source == expected
        requestTask?.cancel()
        let attempt = UUID(); generation = attempt
        if !retain { cancelItem(); statistics = nil; updatedAt = nil }
        source = expected; error = nil; isLoading = true
        let worker = Task { try Task.checkCancellation(); return try await expected.client.libraryStatistics(libraryID: library.id) }
        requestTask = worker
        defer {
            worker.cancel()
            if generation == attempt { requestTask = nil; isLoading = false }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard generation == attempt, source == expected, expected.isCurrent(store) else { return }
            statistics = result; updatedAt = Date()
        } catch {
            guard !Task.isCancelled, generation == attempt, source == expected, expected.isCurrent(store), !Self.isCancellation(error) else { return }
            self.error = L10n.error(error)
        }
    }

    func openItem(id: String, store: AppStore, library: Library) {
        guard let expected = source, isBound(to: store, library: library), !id.isEmpty else { return }
        cancelItem()
        let attempt = UUID(); itemGeneration = attempt; isOpeningItem = true
        itemTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.itemGeneration == attempt { self.itemTask = nil; self.isOpeningItem = false } }
            do {
                try Task.checkCancellation()
                guard self.itemGeneration == attempt, self.source == expected, expected.isCurrent(store) else { return }
                let item = try await expected.client.item(id: id)
                try Task.checkCancellation()
                guard self.itemGeneration == attempt, self.source == expected, expected.isCurrent(store) else { return }
                guard item.id == id, item.libraryId == library.id else { throw ABSError.invalidResponse }
                self.openedItem = item
            } catch {
                guard !Task.isCancelled, self.itemGeneration == attempt, self.source == expected, expected.isCurrent(store), !Self.isCancellation(error) else { return }
                self.itemError = L10n.error(error)
            }
        }
    }
    private func cancelItem() {
        itemGeneration = UUID(); itemTask?.cancel(); itemTask = nil
        openedItem = nil; itemError = nil; isOpeningItem = false
    }
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ABSError) == .sessionChanged || (error as? URLError)?.code == .cancelled
    }
}
