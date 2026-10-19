import Foundation
import Observation
import AudilseCore

private struct CachedHomeShelves: Codable, Sendable {
    let shelves: [PersonalizedLibraryShelf]
    let updatedAt: Date
}

/// Keeps the server's shelf and entity order, including unfamiliar shelf types.
/// Playback progress belongs to AppStore and is only overlaid by the view.
@MainActor @Observable final class HomeModel {
    private(set) var shelves: [PersonalizedLibraryShelf] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var cacheError: String?
    private(set) var usesCache = false
    private(set) var updatedAt: Date?
    private(set) var localResumeByID: [String: MediaProgress] = [:]

    private var generation = UUID()
    private var boundPartition: AccountPartition?
    private var boundClient: ABSClient?
    private var boundLibraryID: String?
    private var boundLimit: Int?
    private var boundOffline = false
    private var boundRevision: UUID?
    @ObservationIgnored private var requestTask: Task<[PersonalizedLibraryShelf], Error>?

    func isBound(to store: AppStore, libraryID: String) -> Bool {
        boundPartition != nil && boundPartition == store.partition && boundClient === store.client &&
        boundLibraryID == libraryID && store.currentLibrary?.id == libraryID &&
        boundOffline == store.isOffline && boundRevision == store.libraryRevision && store.user?.isActive == true && !store.isConnecting
    }

    func cancel() {
        generation = UUID()
        requestTask?.cancel(); requestTask = nil
        boundPartition = nil; boundClient = nil; boundLibraryID = nil; boundLimit = nil; boundRevision = nil
        shelves = []; localResumeByID = [:]; error = nil; cacheError = nil; updatedAt = nil; usesCache = false; isLoading = false
    }

    func load(store: AppStore, library: Library, limit: Int = 10) async {
        // A cancelled SwiftUI task must not replace a newer task's generation.
        guard !Task.isCancelled, !store.isConnecting, store.currentLibrary?.id == library.id, store.user?.isActive == true else { return }
        let operation = UUID()
        generation = operation
        requestTask?.cancel(); requestTask = nil
        let partition = store.partition, client = store.client, database = store.database
        let offline = store.isOffline, revision = store.libraryRevision
        let requestedLimit = min(500, max(1, limit))
        let sameSource = boundPartition == partition && boundClient === client && boundLibraryID == library.id && boundLimit == requestedLimit
        boundPartition = partition; boundClient = client; boundLibraryID = library.id; boundLimit = requestedLimit
        boundOffline = offline; boundRevision = revision
        if !sameSource { shelves = []; updatedAt = nil; usesCache = false }
        error = nil; cacheError = nil; localResumeByID = [:]; isLoading = true
        defer { if generation == operation { isLoading = false; requestTask = nil } }
        guard let partition else { error = L10n.tr("请先连接服务器。"); return }
        func current() -> Bool {
            generation == operation && !Task.isCancelled && store.partition == partition && store.client === client &&
            store.currentLibrary?.id == library.id && store.isOffline == offline && store.libraryRevision == revision &&
            store.database === database && store.user?.isActive == true && !store.isConnecting
        }

        // Length-prefix the opaque library ID so no ID/limit pair shares a key.
        let key = "home.v1.\(library.id.utf8.count):\(library.id).\(requestedLimit)"
        var cached: CachedHomeShelves?
        if let database {
            do {
                cached = try await database.load(CachedHomeShelves.self, key: key, partition: partition)
                guard current() else { return }
                if let cached, !sameSource || offline || shelves.isEmpty {
                    shelves = cached.shelves; updatedAt = cached.updatedAt; usesCache = true
                }
            } catch {
                guard current() else { return }
                cacheError = L10n.tr("无法读取首页缓存：") + L10n.error(error)
            }
        }
        guard current() else { return }
        if offline {
            if cached == nil, !sameSource || updatedAt == nil { error = L10n.tr("暂无此书库的离线首页缓存。联网打开首页后即可保存。") }
            else { usesCache = true }
            if let database {
                var targets: [(itemID: String, episodeID: String?)] = []
                var seen = Set<String>()
                func add(_ itemID: String, _ episodeID: String? = nil) {
                    let key = OfflinePlaybackSession.mediaKey(itemID: itemID, episodeID: episodeID)
                    if seen.insert(key).inserted { targets.append((itemID, episodeID)) }
                }
                for shelf in shelves {
                    for entity in shelf.entities {
                        switch entity {
                        case .item(let entry): add(entry.item.id, entry.recentEpisode?.id)
                        case .series(let series): for book in series.books { add(book.id) }
                        default: break
                        }
                    }
                }
                do {
                    var resumes: [String: MediaProgress] = [:]
                    for target in targets {
                        let resume = try await database.loadResume(itemID: target.itemID, episodeID: target.episodeID, partition: partition)
                        guard current() else { return }
                        if let resume { resumes[resume.id] = resume }
                    }
                    localResumeByID = resumes
                } catch { if current() { cacheError = L10n.tr("无法读取本地续播位置：") + L10n.error(error) } }
            }
            return
        }
        guard let client else { error = L10n.tr("请先连接服务器。"); return }

        let request = Task {
            try Task.checkCancellation()
            return try await client.personalizedShelves(libraryID: library.id, limit: requestedLimit)
        }
        requestTask = request
        defer { request.cancel() }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
            guard current() else { return }
            let date = Date()
            shelves = result; updatedAt = date; usesCache = false
            if let database {
                do { try await database.save(CachedHomeShelves(shelves: result, updatedAt: date), key: key, partition: partition) }
                catch { if current() { cacheError = L10n.tr("无法保存首页缓存：") + L10n.error(error) } }
                guard current() else { return }
            }
        } catch is CancellationError {} catch ABSError.sessionChanged {}
        catch let failure as URLError where failure.code == .cancelled {}
        catch {
            guard current() else { return }
            self.error = L10n.error(error)
            if let cached { shelves = cached.shelves; updatedAt = cached.updatedAt; usesCache = true }
            else if updatedAt != nil { usesCache = true }
        }
    }
}
