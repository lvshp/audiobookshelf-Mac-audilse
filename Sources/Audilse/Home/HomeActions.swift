import Foundation
import Observation
import AudilseCore
import AudilsePlayback

/// A rendered card carries this identity into its Task, so a delayed click cannot
/// operate on a replacement account, library, player, or connectivity state.
struct HomeSource: Hashable {
    let coverSource: CoverSource
    let partition: AccountPartition?
    let client: ObjectIdentifier?
    let database: ObjectIdentifier?
    let player: ObjectIdentifier?
    let libraryID: String
    private(set) var revision: UUID
    let accountOperationID: UUID
    let userID: String?
    let username: String?
    let userType: String?
    let permissions: UserPermissions?
    let accessibleLibraries: Set<String>
    let selectedTags: Set<String>
    let offline: Bool
    let connecting: Bool
    let active: Bool

    @MainActor init(store: AppStore, libraryID: String) {
        coverSource = CoverSource(store: store)
        partition = store.partition; client = store.client.map(ObjectIdentifier.init)
        database = store.database.map(ObjectIdentifier.init); player = store.player.map(ObjectIdentifier.init)
        self.libraryID = libraryID; revision = store.libraryRevision
        accountOperationID = store.accountOperationID
        userID = store.user?.id; username = store.user?.username; userType = store.user?.type
        permissions = store.user?.permissions
        accessibleLibraries = Set(store.user?.librariesAccessible ?? [])
        selectedTags = Set(store.user?.itemTagsSelected ?? [])
        offline = store.isOffline; connecting = store.isConnecting; active = store.user?.isActive == true
    }
    func isRevisionRefresh(of previous: Self) -> Bool {
        guard revision != previous.revision, partition != nil, active, !connecting else { return false }
        var normalized = self
        normalized.revision = previous.revision
        return normalized == previous
    }
    @MainActor func isCurrent(_ store: AppStore) -> Bool {
        partition != nil && !connecting && active && store.currentLibrary?.id == libraryID &&
        store.route == .home && store.search.isEmpty && self == HomeSource(store: store, libraryID: libraryID)
    }
}

struct HomeDestination: Identifiable {
    enum Content { case reader(AudilseCore.LibraryItem), group(FeatureKind, FeatureGroup) }
    let id = UUID()
    let content: Content
}

enum HomeCommand {
    case open(LibraryBrowseEntry)
    case play(LibraryBrowseEntry)
    case enqueue(LibraryBrowseEntry)
    case read(LibraryBrowseEntry)
    case series(BookSeries)
    case author(Author)
    case continueSeries(LibraryBrowseEntry)
}

@MainActor @Observable final class HomeActions {
    var destination: HomeDestination?
    var error: String?
    private(set) var isWorking = false
    private var source: HomeSource?
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func bind(_ source: HomeSource) {
        guard self.source != source else { return }
        let keepReader: Bool
        if let previous = self.source, let destination, case .reader = destination.content {
            keepReader = source.isRevisionRefresh(of: previous)
        } else { keepReader = false }
        // A progress refresh invalidates old cards, but must not dismiss their
        // already-open reader. Account/access and other source changes still do.
        generation = UUID(); task?.cancel(); task = nil
        self.source = source; error = nil; isWorking = false
        if !keepReader { destination = nil }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        source = nil; destination = nil; error = nil; isWorking = false
    }
    func start(_ command: HomeCommand, store: AppStore, source: HomeSource) {
        guard self.source == source, source.isCurrent(store) else { return }
        task?.cancel()
        let operation = UUID(); generation = operation; isWorking = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == operation { self.isWorking = false; self.task = nil } }
            do {
                try self.check(store, source, operation)
                switch command {
                case .open(let entry):
                    await store.open(entry.item)
                case .read(let entry):
                    let full = try await self.fullItem(entry.item, store: store, source: source, operation: operation)
                    guard full.media.ebookFile != nil else { throw ReadingError.noEbook }
                    try self.check(store, source, operation)
                    self.destination = .init(content: .reader(full))
                case .play(let entry), .enqueue(let entry):
                    let enqueue: Bool
                    if case .enqueue = command { enqueue = true } else { enqueue = false }
                    guard !entry.item.isMissing, !entry.item.isInvalid else { throw PlaybackFailure.noTracks }
                    if let recent = entry.recentEpisode {
                        // Never use the parent show's progress/ID for an episode.
                        let full = try await self.fullItem(entry.item, store: store, source: source, operation: operation)
                        guard full.mediaType == "podcast", let episode = full.media.episodes.first(where: { $0.id == recent.id }),
                              Self.isPlayable(episode) else { throw PlaybackFailure.noTracks }
                        try self.check(store, source, operation)
                        if enqueue { store.player?.enqueue(store.playbackMedia(full, episode: episode)) }
                        else {
                            let progress = try await self.playbackProgress(in: full, after: episode.id, store: store, source: source, operation: operation)
                            try self.check(store, source, operation)
                            let following = Self.followingEpisodes(in: full, after: episode.id, progress: progress)
                                .map { store.playbackMedia(full, episode: $0) }
                            await store.play(full, episode: episode, following: following)
                        }
                    } else {
                        guard entry.item.mediaType == "book", Self.hasAudio(entry) else { throw PlaybackFailure.noTracks }
                        if enqueue { store.player?.enqueue(store.playbackMedia(entry.item)) }
                        else { await store.play(entry.item) }
                    }
                case .series(let series):
                    let group = FeatureGroup(id: series.id, title: series.name, summary: series.description?.shelfPlainText ?? "",
                                             count: series.books.count, books: series.books, libraryID: source.libraryID)
                    try await self.showGroup(group, kind: .series, store: store, source: source, operation: operation)
                case .author(let author):
                    let group = FeatureGroup(id: author.id, title: author.name, summary: author.description?.shelfPlainText ?? "",
                                             count: author.numBooks, books: author.libraryItems, libraryID: source.libraryID)
                    try await self.showGroup(group, kind: .authors, store: store, source: source, operation: operation)
                case .continueSeries(let entry):
                    guard let series = entry.item.media.metadata.series.first, !series.id.isEmpty else { throw ABSError.invalidResponse }
                    let group = FeatureGroup(id: series.id, title: series.name, summary: "", count: 1,
                                             books: [entry.item], libraryID: source.libraryID)
                    try await self.showGroup(group, kind: .series, store: store, source: source, operation: operation)
                }
            } catch is CancellationError {} catch ABSError.sessionChanged {}
            catch let failure as URLError where failure.code == .cancelled {}
            catch {
                guard self.generation == operation, self.source == source, source.isCurrent(store), !Task.isCancelled else { return }
                self.error = L10n.error(error)
            }
        }
    }
    private func check(_ store: AppStore, _ source: HomeSource, _ operation: UUID) throws {
        guard !Task.isCancelled, generation == operation, self.source == source, source.isCurrent(store) else { throw CancellationError() }
    }
    private func fullItem(_ item: AudilseCore.LibraryItem, store: AppStore, source: HomeSource, operation: UUID) async throws -> AudilseCore.LibraryItem {
        try check(store, source, operation)
        if !source.offline, let client = store.client {
            let full = try await client.item(id: item.id)
            try check(store, source, operation)
            return full
        }
        if let database = store.database, let partition = source.partition {
            let cached = try await database.load(AudilseCore.LibraryItem.self, key: "item.\(item.id)", partition: partition)
            try check(store, source, operation)
            if let cached { return cached }
        }
        return item
    }
    private func playbackProgress(in item: AudilseCore.LibraryItem, after episodeID: String, store: AppStore, source: HomeSource, operation: UUID) async throws -> [String: MediaProgress] {
        var progress = store.progressByItem
        guard source.offline, let database = store.database, let partition = source.partition else { return progress }
        // The home snapshot only restores episodes currently on a shelf. Future
        // queue members can have local checkpoints outside that snapshot.
        for episode in Self.followingEpisodes(in: item, after: episodeID, progress: [:]) {
            let saved = try await database.loadResume(itemID: item.id, episodeID: episode.id, partition: partition)
            try check(store, source, operation)
            let key = item.id + ":" + episode.id
            progress[key] = Self.latestProgress(local: saved, current: store.progressByItem[key])
        }
        return progress
    }
    private func showGroup(_ initial: FeatureGroup, kind: FeatureKind, store: AppStore, source: HomeSource, operation: UUID) async throws {
        var group = initial
        if source.offline {
            if let database = store.database, let partition = source.partition {
                let cached = try await database.load([FeatureGroup].self, key: "feature.\(source.libraryID).\(kind.rawValue)", partition: partition)
                try check(store, source, operation)
                if let complete = cached?.first(where: { $0.id == initial.id }) { group = complete }
                else {
                    guard !initial.books.isEmpty else { throw HomeActionFailure.uncachedGroup }
                    group.summary = L10n.tr("离线显示首页中缓存的内容，联网后可载入完整列表。") + (initial.summary.isEmpty ? "" : "\n" + initial.summary)
                }
            } else { throw HomeActionFailure.uncachedGroup }
        }
        try check(store, source, operation)
        destination = .init(content: .group(kind, group))
    }
    static func latestProgress(local: MediaProgress?, current: MediaProgress?) -> MediaProgress? {
        guard let local else { return current }
        guard let current else { return local }
        let localStamp = local.lastUpdate.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let currentStamp = current.lastUpdate.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return localStamp > currentStamp ? local : current
    }
    static func hasAudio(_ entry: LibraryBrowseEntry) -> Bool {
        !entry.item.media.tracks.isEmpty || (entry.item.media.numTracks ?? 0) > 0 ||
        !entry.item.media.audioFiles.isEmpty || (entry.mediaSummary?.numAudioFiles ?? 0) > 0
    }
    static func isPlayable(_ episode: PodcastEpisode) -> Bool {
        guard let file = episode.audioFile else { return false }
        return !file.exclude && !file.isInvalid
    }
    /// A completed episode explicitly clicked in Listen again still starts; only
    /// subsequent episodes are filtered. ABS Web queues least recent first.
    static func followingEpisodes(in item: AudilseCore.LibraryItem, after episodeID: String, progress: [String: MediaProgress]) -> [PodcastEpisode] {
        let sorted = item.media.episodes.enumerated().sorted { lhs, rhs in
            let left = lhs.element.publishedAt ?? 0, right = rhs.element.publishedAt ?? 0
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard let selected = sorted.firstIndex(where: { $0.id == episodeID }) else { return [] }
        return sorted.dropFirst(selected + 1).filter {
            isPlayable($0) && progress[item.id + ":" + $0.id]?.isFinished != true
        }
    }
}

private enum HomeActionFailure: ClientLocalizedError {
    case uncachedGroup
    var clientErrorDescription: String { L10n.tr("本机尚未缓存此作者或系列的内容，请联网后重试。") }
}
