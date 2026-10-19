import Foundation
import Observation
import ShelfCore
import ShelfPlayback

/// Also freezes the player: replacing a controller invalidates rendered actions
/// even if the query and account happen to remain unchanged.
struct LibrarySearchActionSource: Hashable {
    let request: LibrarySearchSource
    let player: ObjectIdentifier?
    @MainActor init(store: AppStore, request: LibrarySearchSource) {
        self.request = request; player = store.player.map(ObjectIdentifier.init)
    }
    @MainActor func isCurrent(_ store: AppStore, model: LibrarySearchModel) -> Bool {
        request.isCurrent(store) && model.isBound(to: store, source: request) && player == store.player.map(ObjectIdentifier.init)
    }
}

enum LibrarySearchCommand {
    case open(LibraryBrowseEntry)
    case play(LibraryBrowseEntry)
    case enqueue(LibraryBrowseEntry)
    case author(Author)
    case series(LibrarySearchSeriesMatch)
    case browse(LibraryBrowseFilter)
}

struct LibrarySearchDestination: Identifiable {
    let id = UUID()
    let kind: FeatureKind
    let group: FeatureGroup
}

@MainActor @Observable final class LibrarySearchActions {
    var destination: LibrarySearchDestination?
    var error: String?
    private(set) var isWorking = false
    private var source: LibrarySearchActionSource?
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func bind(_ source: LibrarySearchActionSource) {
        guard self.source != source else { return }
        cancel(); self.source = source
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        source = nil; destination = nil; error = nil; isWorking = false
    }
    func start(_ command: LibrarySearchCommand, libraryID: String, store: AppStore,
               model: LibrarySearchModel, source: LibrarySearchActionSource) {
        guard self.source == source, source.isCurrent(store, model: model),
              let library = source.request.requestedLibraries.first(where: { $0.id == libraryID }) else { return }
        task?.cancel(); task = nil
        let operation = UUID(); generation = operation; error = nil
        // Navigation is synchronous, so a second click cannot adopt a different
        // library while an unstructured Task is waiting to enter the actor.
        if case .browse(let filter) = command {
            isWorking = false
            guard filter.isAvailable(mediaType: library.mediaType, user: store.user) else { return }
            store.browse(libraryID: libraryID, filter: filter)
            return
        }
        isWorking = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == operation { self.isWorking = false; self.task = nil } }
            do {
                try self.check(store, model, source, operation)
                switch command {
                case .open(let entry):
                    try self.requireLibrary(entry.item, libraryID: libraryID)
                    await store.open(entry.item)
                case .play(let entry), .enqueue(let entry):
                    try self.requireLibrary(entry.item, libraryID: libraryID)
                    guard !entry.item.isMissing, !entry.item.isInvalid else { throw PlaybackFailure.noTracks }
                    let enqueue: Bool
                    if case .enqueue = command { enqueue = true } else { enqueue = false }
                    if let recent = entry.recentEpisode {
                        let full = try await self.fullItem(entry.item, store: store, model: model, source: source, operation: operation)
                        try self.requireLibrary(full, libraryID: libraryID)
                        guard full.mediaType == "podcast", let episode = full.media.episodes.first(where: { $0.id == recent.id }),
                              HomeActions.isPlayable(episode) else { throw PlaybackFailure.noTracks }
                        try self.check(store, model, source, operation)
                        if enqueue { store.player?.enqueue(store.playbackMedia(full, episode: episode)) }
                        else {
                            let progress = try await self.playbackProgress(in: full, after: episode.id, store: store,
                                                                          model: model, source: source, operation: operation)
                            try self.check(store, model, source, operation)
                            let following = HomeActions.followingEpisodes(in: full, after: episode.id, progress: progress)
                                .map { store.playbackMedia(full, episode: $0) }
                            await store.play(full, episode: episode, following: following)
                        }
                    } else {
                        guard entry.item.mediaType == "book", HomeActions.hasAudio(entry) else { throw PlaybackFailure.noTracks }
                        if enqueue { store.player?.enqueue(store.playbackMedia(entry.item)) }
                        else { await store.play(entry.item) }
                    }
                case .author(let author):
                    if let id = author.libraryId, !id.isEmpty, id != libraryID { throw ABSError.invalidResponse }
                    let group = FeatureGroup(id: author.id, title: author.name, summary: author.description?.shelfPlainText ?? "",
                                             count: author.numBooks, libraryID: libraryID)
                    try await self.showGroup(group, kind: .authors, libraryID: libraryID, store: store,
                                             model: model, source: source, operation: operation)
                case .series(let match):
                    if let id = match.series.libraryId, !id.isEmpty, id != libraryID { throw ABSError.invalidResponse }
                    // Search books are a preview. The detail view performs its
                    // expanded GET before offering the full associated list.
                    let group = FeatureGroup(id: match.series.id, title: match.series.name,
                                             summary: match.series.description?.shelfPlainText ?? "", count: 0, libraryID: libraryID)
                    try await self.showGroup(group, kind: .series, libraryID: libraryID, store: store,
                                             model: model, source: source, operation: operation)
                case .browse: break
                }
            } catch is CancellationError {} catch ABSError.sessionChanged {}
            catch let failure as URLError where failure.code == .cancelled {}
            catch {
                guard self.generation == operation, self.source == source, source.isCurrent(store, model: model), !Task.isCancelled else { return }
                self.error = L10n.error(error)
            }
        }
    }
    private func check(_ store: AppStore, _ model: LibrarySearchModel, _ source: LibrarySearchActionSource, _ operation: UUID) throws {
        guard !Task.isCancelled, generation == operation, self.source == source, source.isCurrent(store, model: model) else { throw CancellationError() }
    }
    private func requireLibrary(_ item: ShelfCore.LibraryItem, libraryID: String) throws {
        guard item.libraryId == libraryID else { throw ABSError.invalidResponse }
    }
    private func fullItem(_ item: ShelfCore.LibraryItem, store: AppStore, model: LibrarySearchModel,
                          source: LibrarySearchActionSource, operation: UUID) async throws -> ShelfCore.LibraryItem {
        try check(store, model, source, operation)
        if !source.request.offline, let client = store.client {
            let full = try await client.item(id: item.id)
            try check(store, model, source, operation)
            return full
        }
        if let database = store.database, let partition = source.request.partition {
            let full = try await database.load(ShelfCore.LibraryItem.self, key: "item.\(item.id)", partition: partition)
            try check(store, model, source, operation)
            if let full { return full }
        }
        return item
    }
    private func playbackProgress(in item: ShelfCore.LibraryItem, after episodeID: String, store: AppStore,
                                  model: LibrarySearchModel, source: LibrarySearchActionSource, operation: UUID) async throws -> [String: MediaProgress] {
        var progress = store.progressByItem
        guard source.request.offline, let database = store.database, let partition = source.request.partition else { return progress }
        for episode in HomeActions.followingEpisodes(in: item, after: episodeID, progress: [:]) {
            let saved = try await database.loadResume(itemID: item.id, episodeID: episode.id, partition: partition)
            try check(store, model, source, operation)
            let key = item.id + ":" + episode.id
            progress[key] = HomeActions.latestProgress(local: saved, current: store.progressByItem[key])
        }
        return progress
    }
    private func showGroup(_ initial: FeatureGroup, kind: FeatureKind, libraryID: String, store: AppStore,
                           model: LibrarySearchModel, source: LibrarySearchActionSource, operation: UUID) async throws {
        var group = initial
        if source.request.offline {
            guard let database = store.database, let partition = source.request.partition else { throw LibrarySearchActionFailure.uncachedGroup }
            let groups = try await database.load([FeatureGroup].self, key: "feature.\(libraryID).\(kind.rawValue)", partition: partition)
            try check(store, model, source, operation)
            guard let cached = groups?.first(where: { $0.id == initial.id }) else { throw LibrarySearchActionFailure.uncachedGroup }
            // Author catalog caches commonly contain a count with no books.
            // They cannot serve as an offline expanded association list.
            guard cached.books.count >= cached.count,
                  cached.books.allSatisfy({ $0.libraryId == libraryID }) else { throw LibrarySearchActionFailure.uncachedGroup }
            group = cached; group.libraryID = libraryID
        }
        try check(store, model, source, operation)
        destination = .init(kind: kind, group: group)
    }
}

private enum LibrarySearchActionFailure: ClientLocalizedError {
    case uncachedGroup
    var clientErrorDescription: String { L10n.tr("本机尚未缓存此作者或系列的完整列表，请联网后打开。") }
}
