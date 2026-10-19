import Foundation

public struct FeaturePage<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var results: [Element]
    public var total: Int
    public var limit: Int
    public var page: Int
    public var hasMore: Bool { limit > 0 && (page + 1) * limit < total }
    public init(results: [Element], total: Int, limit: Int, page: Int) { self.results = results; self.total = total; self.limit = limit; self.page = page }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([Element].self, forKey: .results)
        total = c.value(.total, default: results.count)
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? Int(c.value(.limit, default: "")) ?? results.count
        page = (try? c.decode(Int.self, forKey: .page)) ?? Int(c.value(.page, default: "")) ?? 0
    }
}

public struct Author: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var libraryId: String?
    public var description: String?
    public var imagePath: String?
    public var asin: String?
    public var updatedAt: Double?
    public var numBooks: Int
    public var libraryItems: [LibraryItem]
    public var series: [AuthorSeries]
    public init(id: String, name: String, libraryId: String? = nil, description: String? = nil, imagePath: String? = nil, asin: String? = nil, numBooks: Int = 0, libraryItems: [LibraryItem] = [], series: [AuthorSeries] = [], updatedAt: Double? = nil) { self.updatedAt = updatedAt; self.id = id; self.name = name; self.libraryId = libraryId; self.description = description; self.imagePath = imagePath; self.asin = asin; self.numBooks = numBooks; self.libraryItems = libraryItems; self.series = series }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = c.value(.name, default: "")
        libraryId = try? c.decodeIfPresent(String.self, forKey: .libraryId); description = try? c.decodeIfPresent(String.self, forKey: .description); imagePath = try? c.decodeIfPresent(String.self, forKey: .imagePath); asin = try? c.decodeIfPresent(String.self, forKey: .asin)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        numBooks = c.value(.numBooks, default: 0); libraryItems = c.value(.libraryItems, default: []); series = c.value(.series, default: [])
    }
}
/// PATCH may merge into a different author ID; callers must adopt the returned author.
public struct AuthorMutationResult: Codable, Hashable, Sendable {
    public var author: Author
    public var updated: Bool?
    public var merged: Bool?
    public init(author: Author, updated: Bool? = nil, merged: Bool? = nil) {
        self.author = author; self.updated = updated; self.merged = merged
    }
}
public struct AuthorManagementPolicy {
    /// 2.26's rename collision query is global; fixed 2.36.1 scopes it to the library.
    public static func allowsRename(serverVersion: String?) -> Bool {
        serverVersion.map { ServerVersion($0) >= ServerVersion("2.36.1") } ?? false
    }
}
public struct AuthorSeries: Codable, Hashable, Identifiable, Sendable { public var id: String; public var name: String; public var items: [LibraryItem] }
public struct AuthorUpdate: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var asin: String?
    public init(name: String? = nil, description: String? = nil, asin: String? = nil) { self.name = name; self.description = description; self.asin = asin }
}
public struct AuthorMatch: Codable, Hashable, Sendable {
    public var q: String?
    public var asin: String?
    public var region: String
    public init(query: String? = nil, asin: String? = nil, region: String = "us") { self.q = query; self.asin = asin; self.region = region }
}
public struct SeriesUpdate: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public init(name: String? = nil, description: String? = nil) { self.name = name; self.description = description }
}
public struct LibraryFolder: Codable, Hashable, Identifiable, Sendable { public var id: String; public var fullPath: String }
public struct LibraryDetails: Codable, Hashable, Identifiable, Sendable {
    public struct Settings: Codable, Hashable, Sendable {
        /// The Web directory search passes this library default as `country`.
        public var podcastSearchRegion: String?
        public init(podcastSearchRegion: String? = nil) { self.podcastSearchRegion = podcastSearchRegion }
    }
    public var id: String
    public var name: String
    public var mediaType: String
    public var folders: [LibraryFolder]
    public var settings: Settings?
    public var provider: String?
    public init(id: String, name: String, mediaType: String, folders: [LibraryFolder], settings: Settings? = nil, provider: String? = nil) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.folders = folders; self.settings = settings; self.provider = provider
    }
}

public struct BookSeries: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var libraryId: String?
    public var description: String?
    public var books: [LibraryItem]
    public var progress: SeriesProgress?
    public var rssFeed: RSSFeed?
    public var numBooks: Int { books.count }
    public init(id: String, name: String, libraryId: String? = nil, description: String? = nil, books: [LibraryItem] = [], progress: SeriesProgress? = nil, rssFeed: RSSFeed? = nil) { self.id = id; self.name = name; self.libraryId = libraryId; self.description = description; self.books = books; self.progress = progress; self.rssFeed = rssFeed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = c.value(.name, default: ""); libraryId = try? c.decodeIfPresent(String.self, forKey: .libraryId); description = try? c.decodeIfPresent(String.self, forKey: .description); books = c.value(.books, default: []); progress = try? c.decodeIfPresent(SeriesProgress.self, forKey: .progress); rssFeed = try? c.decodeIfPresent(RSSFeed.self, forKey: .rssFeed)
    }
}
public struct SeriesProgress: Codable, Hashable, Sendable { public var libraryItemIds: [String]; public var libraryItemIdsFinished: [String]; public var isFinished: Bool }

public struct BookCollection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var libraryId: String
    public var name: String
    public var description: String?
    public var books: [LibraryItem]
    public var rssFeed: RSSFeed?
    public init(id: String, libraryId: String, name: String, description: String? = nil, books: [LibraryItem] = [], rssFeed: RSSFeed? = nil) { self.id = id; self.libraryId = libraryId; self.name = name; self.description = description; self.books = books; self.rssFeed = rssFeed }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(String.self, forKey: .id); libraryId = c.value(.libraryId, default: ""); name = c.value(.name, default: ""); description = try? c.decodeIfPresent(String.self, forKey: .description); books = c.value(.books, default: []); rssFeed = try? c.decodeIfPresent(RSSFeed.self, forKey: .rssFeed) }
}
public struct CollectionDraft: Codable, Hashable, Sendable {
    public var libraryId: String
    public var name: String
    public var description: String?
    /// ABS accepts library item IDs here, not internal book IDs.
    public var books: [String]
    public init(libraryId: String, name: String, description: String? = nil, books: [String]) { self.libraryId = libraryId; self.name = name; self.description = description; self.books = books }
}
public struct CollectionUpdate: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var books: [String]?
    public init(name: String? = nil, description: String? = nil, books: [String]? = nil) { self.name = name; self.description = description; self.books = books }
}

public struct PlaylistEntry: Codable, Hashable, Identifiable, Sendable {
    public var libraryItemId: String
    public var episodeId: String?
    public var libraryItem: LibraryItem?
    public var episode: PodcastEpisode?
    public var id: String { libraryItemId + (episodeId.map { ":" + $0 } ?? "") }
    public init(libraryItemId: String, episodeId: String? = nil, libraryItem: LibraryItem? = nil, episode: PodcastEpisode? = nil) { self.libraryItemId = libraryItemId; self.episodeId = episodeId; self.libraryItem = libraryItem; self.episode = episode }
}
public struct PlaylistItemReference: Codable, Hashable, Identifiable, Sendable {
    public var libraryItemId: String
    public var episodeId: String?
    public var id: String { libraryItemId + (episodeId.map { ":" + $0 } ?? "") }
    public init(libraryItemId: String, episodeId: String? = nil) { self.libraryItemId = libraryItemId; self.episodeId = episodeId }
}
public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var libraryId: String
    public var userId: String?
    public var name: String
    public var description: String?
    public var items: [PlaylistEntry]
    public init(id: String, libraryId: String, userId: String? = nil, name: String, description: String? = nil, items: [PlaylistEntry] = []) { self.id = id; self.libraryId = libraryId; self.userId = userId; self.name = name; self.description = description; self.items = items }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(String.self, forKey: .id); libraryId = c.value(.libraryId, default: ""); userId = try? c.decodeIfPresent(String.self, forKey: .userId); name = c.value(.name, default: ""); description = try? c.decodeIfPresent(String.self, forKey: .description); items = c.value(.items, default: []) }
}
public struct PlaylistDraft: Codable, Hashable, Sendable {
    public var libraryId: String
    public var name: String
    public var description: String?
    public var items: [PlaylistItemReference]
    public init(libraryId: String, name: String, description: String? = nil, items: [PlaylistItemReference] = []) { self.libraryId = libraryId; self.name = name; self.description = description; self.items = items }
}
public struct PlaylistUpdate: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var items: [PlaylistItemReference]?
    public init(name: String? = nil, description: String? = nil, items: [PlaylistItemReference]? = nil) { self.name = name; self.description = description; self.items = items }
}

public struct ListeningHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var libraryItemId: String?
    public var episodeId: String?
    public var displayTitle: String
    public var displayAuthor: String
    public var mediaType: String
    public var mediaMetadata: ItemMetadata?
    public var currentTime: Double
    public var duration: Double
    public var timeListening: Double
    public var startedAt: Double?
    public var updatedAt: Double?
    public var date: String?
    public var dayOfWeek: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); libraryItemId = try? c.decodeIfPresent(String.self, forKey: .libraryItemId); episodeId = try? c.decodeIfPresent(String.self, forKey: .episodeId); displayTitle = c.value(.displayTitle, default: ""); displayAuthor = c.value(.displayAuthor, default: ""); mediaType = c.value(.mediaType, default: "book"); mediaMetadata = try? c.decodeIfPresent(ItemMetadata.self, forKey: .mediaMetadata); currentTime = c.numeric(.currentTime); duration = c.numeric(.duration); timeListening = c.numeric(.timeListening); startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt); updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt); date = try? c.decodeIfPresent(String.self, forKey: .date); dayOfWeek = try? c.decodeIfPresent(String.self, forKey: .dayOfWeek)
    }
}
public struct ListeningHistoryPage: Codable, Hashable, Sendable {
    public var total: Int
    public var numPages: Int
    public var page: Int
    public var itemsPerPage: Int
    public var sessions: [ListeningHistoryEntry]
    public var hasMore: Bool { page + 1 < numPages }
}
public struct ListeningItemStatistics: Codable, Hashable, Sendable { public var id: String?; public var timeListening: Double; public var mediaMetadata: ItemMetadata?; public var lastUpdate: Double? }
public struct ListeningStatistics: Codable, Hashable, Sendable {
    public var totalTime: Double
    public var today: Double
    public var items: [String: ListeningItemStatistics]
    public var days: [String: Double]
    public var dayOfWeek: [String: Double]
    public var recentSessions: [ListeningHistoryEntry]
}
/// Annual author/narrator ranks use `name`; genre ranks use `genre`. Time is in seconds.
public struct StatisticsRank: Codable, Hashable, Sendable {
    public var name: String?; public var genre: String?; public var id: String?; public var time: Double
    public init(name: String? = nil, genre: String? = nil, id: String? = nil, time: Double) {
        self.name = name; self.genre = genre; self.id = id; self.time = time
    }
}
public struct StatisticsMonth: Codable, Hashable, Sendable {
    /// JavaScript calendar month: January is 0 and December is 11.
    public var month: Int
    /// Listening time in seconds.
    public var time: Double
    public init(month: Int, time: Double) { self.month = month; self.time = time }
}
public struct FinishedAudiobook: Codable, Hashable, Sendable {
    /// Internal book ID, unlike the library-item IDs in annual cover arrays.
    public var id: String
    public var title: String
    public var duration: Double
    public var finishedAt: String?
    public init(id: String, title: String, duration: Double, finishedAt: String? = nil) {
        self.id = id; self.title = title; self.duration = duration; self.finishedAt = finishedAt
    }
}
/// Personal annual statistics from `/api/me/stats/year/:year`. All durations are seconds.
public struct YearlyStatistics: Codable, Hashable, Sendable {
    public var totalListeningSessions: Int
    public var totalListeningTime: Double
    public var totalBookListeningTime: Double
    public var totalPodcastListeningTime: Double
    public var topAuthors: [StatisticsRank]
    public var topGenres: [StatisticsRank]
    public var mostListenedNarrator: StatisticsRank?
    public var mostListenedMonth: StatisticsMonth?
    public var numBooksFinished: Int
    public var numBooksListened: Int
    public var longestAudiobookFinished: FinishedAudiobook?
    public var booksWithCovers: [String]
    public var finishedBooksWithCovers: [String]
    public init(totalListeningSessions: Int, totalListeningTime: Double, totalBookListeningTime: Double,
                totalPodcastListeningTime: Double, topAuthors: [StatisticsRank], topGenres: [StatisticsRank],
                mostListenedNarrator: StatisticsRank? = nil, mostListenedMonth: StatisticsMonth? = nil,
                numBooksFinished: Int, numBooksListened: Int, longestAudiobookFinished: FinishedAudiobook? = nil,
                booksWithCovers: [String], finishedBooksWithCovers: [String]) {
        self.totalListeningSessions = totalListeningSessions; self.totalListeningTime = totalListeningTime
        self.totalBookListeningTime = totalBookListeningTime; self.totalPodcastListeningTime = totalPodcastListeningTime
        self.topAuthors = topAuthors; self.topGenres = topGenres; self.mostListenedNarrator = mostListenedNarrator
        self.mostListenedMonth = mostListenedMonth; self.numBooksFinished = numBooksFinished
        self.numBooksListened = numBooksListened; self.longestAudiobookFinished = longestAudiobookFinished
        self.booksWithCovers = booksWithCovers; self.finishedBooksWithCovers = finishedBooksWithCovers
    }
}

public enum RSSEntity: String, Codable, Sendable { case item, collection, series }
public struct RSSFeed: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var entityType: String?
    public var entityId: String?
    public var feedUrl: String
    public var meta: RSSFeedMetadata?
    /// Absent in minified/older responses; nil must not imply an empty feed.
    public var episodes: [RSSFeedEpisode]?
    /// ABS timestamps use milliseconds since the Unix epoch.
    public var updatedAt: Double?
}
public struct RSSFeedEpisode: Codable, Hashable, Sendable {
    public var id: String?
    public var title: String?
    public var pubDate: String?
}
public struct RSSFeedMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var description: String?
    public var preventIndexing: Bool?
    public var ownerName: String?
    public var ownerEmail: String?
}
public struct RSSFeedOptions: Codable, Hashable, Sendable {
    public var serverAddress: String
    public var slug: String
    public var metadataDetails: RSSFeedOwnerOptions
    public init(serverAddress: String, slug: String, preventIndexing: Bool = true, ownerName: String? = nil, ownerEmail: String? = nil) { self.serverAddress = serverAddress; self.slug = slug; self.metadataDetails = .init(preventIndexing: preventIndexing, ownerName: ownerName, ownerEmail: ownerEmail) }
}
public struct RSSFeedOwnerOptions: Codable, Hashable, Sendable {
    public var preventIndexing: Bool
    public var ownerName: String?
    public var ownerEmail: String?
}
public enum SharedMediaType: String, Codable, Sendable { case book; case podcastEpisode }
public struct MediaShare: Codable, Hashable, Identifiable, Sendable { public var id: String; public var mediaItemId: String; public var mediaItemType: String; public var slug: String; public var expiresAt: String?; public var isDownloadable: Bool }
public struct MediaShareDraft: Codable, Hashable, Sendable {
    public var mediaItemId: String
    public var mediaItemType: SharedMediaType
    public var slug: String
    /// Epoch milliseconds; 0 means no expiry. ABS does not accept null.
    public var expiresAt: Double
    public var isDownloadable: Bool
    public init(mediaItemId: String, mediaItemType: SharedMediaType, slug: String, expiresAt: Double = 0, isDownloadable: Bool = false) { self.mediaItemId = mediaItemId; self.mediaItemType = mediaItemType; self.slug = slug; self.expiresAt = expiresAt; self.isDownloadable = isDownloadable }
}
public struct EReaderDevice: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var email: String
    public var availabilityOption: String
    public var users: [String]
    public var id: String { name }
    public init(name: String, email: String, userID: String) { self.name = name; self.email = email; self.availabilityOption = "specificUsers"; self.users = [userID] }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); name = try c.decode(String.self, forKey: .name); email = c.value(.email, default: ""); availabilityOption = c.value(.availabilityOption, default: "all"); users = c.value(.users, default: []) }
}

/// These settings are device preferences in the ABS Web client, not server API fields.
public struct ClientPreferences: Codable, Hashable, Sendable {
    public var playbackRate: Double = 1
    public var playbackRateIncrementDecrement: Double = 0.1
    public var jumpForwardAmount: Int = 30
    public var jumpBackwardAmount: Int = 15
    public var orderBy: String = "media.metadata.title"
    public var orderDesc: Bool = false
    public var coverSize: Double = 160
    public var collapseSeries: Bool = false
    public var showSubtitles: Bool = false
    public var useChapterTrack: Bool = false
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playbackRate = values.value(.playbackRate, default: 1)
        playbackRateIncrementDecrement = values.value(.playbackRateIncrementDecrement, default: 0.1)
        jumpForwardAmount = values.value(.jumpForwardAmount, default: 30); jumpBackwardAmount = values.value(.jumpBackwardAmount, default: 15)
        orderBy = values.value(.orderBy, default: "media.metadata.title"); orderDesc = values.value(.orderDesc, default: false)
        coverSize = values.value(.coverSize, default: 160); collapseSeries = values.value(.collapseSeries, default: false)
        showSubtitles = values.value(.showSubtitles, default: false); useChapterTrack = values.value(.useChapterTrack, default: false)
    }
}

extension KeyedDecodingContainer {
    func numeric(_ key: Key, default fallback: Double = 0) -> Double { (try? decode(Double.self, forKey: key)) ?? Double(value(key, default: "")) ?? fallback }
}

public enum PasswordChangeResult: Sendable { case authenticated, requiresSignIn }
