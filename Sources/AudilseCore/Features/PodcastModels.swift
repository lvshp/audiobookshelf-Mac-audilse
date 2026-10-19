import Foundation

public struct PodcastFeedMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var author: String?
    public var language: String?
    public var description: String?
    public var descriptionPlain: String?
    public var feedUrl: String?
    public var image: String?
    public var imageUrl: String?
    public var categories: [String]
    public var type: String?
    public var explicit: String?
    public init(title: String, author: String? = nil, language: String? = nil, description: String? = nil, feedUrl: String? = nil, imageUrl: String? = nil, categories: [String] = [], type: String? = nil) { self.title = title; self.author = author; self.language = language; self.description = description; self.feedUrl = feedUrl; self.imageUrl = imageUrl; self.categories = categories; self.type = type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, default: ""); author = try? c.decodeIfPresent(String.self, forKey: .author); language = try? c.decodeIfPresent(String.self, forKey: .language); description = try? c.decodeIfPresent(String.self, forKey: .description); descriptionPlain = try? c.decodeIfPresent(String.self, forKey: .descriptionPlain); feedUrl = try? c.decodeIfPresent(String.self, forKey: .feedUrl); image = try? c.decodeIfPresent(String.self, forKey: .image); imageUrl = try? c.decodeIfPresent(String.self, forKey: .imageUrl); categories = c.value(.categories, default: []); type = try? c.decodeIfPresent(String.self, forKey: .type); explicit = try? c.decodeIfPresent(String.self, forKey: .explicit)
    }
}
public struct PodcastEnclosure: Codable, Hashable, Sendable {
    public var url: String
    public var type: String?
    public var length: String?
    public init(url: String, type: String? = nil, length: String? = nil) { self.url = url; self.type = type; self.length = length }
    public init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); url = try c.decode(String.self, forKey: .url); type = try? c.decodeIfPresent(String.self, forKey: .type); length = (try? c.decodeIfPresent(String.self, forKey: .length)) ?? (try? c.decodeIfPresent(Int64.self, forKey: .length)).map(String.init) }
}
/// RSS episodes can be requested from the server before they have local ABS episode IDs.
public struct PodcastFeedEpisode: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var subtitle: String?
    public var description: String?
    public var pubDate: String?
    public var publishedAt: Double?
    public var episode: String?
    public var season: String?
    public var episodeType: String?
    public var guid: String?
    public var duration: String?
    public var durationSeconds: Double?
    public var enclosure: PodcastEnclosure
    public var chapters: [Chapter]?
    public var id: String { guid ?? enclosure.url }
    public init(title: String, enclosure: PodcastEnclosure, publishedAt: Double? = nil, guid: String? = nil) { self.title = title; self.enclosure = enclosure; self.publishedAt = publishedAt; self.guid = guid }
}
public struct PodcastFeed: Codable, Hashable, Sendable {
    public var metadata: PodcastFeedMetadata
    public var episodes: [PodcastFeedEpisode]
    public var numEpisodes: Int
    public init(metadata: PodcastFeedMetadata, episodes: [PodcastFeedEpisode], numEpisodes: Int? = nil) { self.metadata = metadata; self.episodes = episodes; self.numEpisodes = numEpisodes ?? episodes.count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decode(PodcastFeedMetadata.self, forKey: .metadata)
        episodes = c.value(.episodes, default: [])
        numEpisodes = c.value(.numEpisodes, default: episodes.count)
    }
}
public struct OPMLFeed: Codable, Hashable, Identifiable, Sendable {
    public var title: String
    public var feedUrl: String
    public var id: String { feedUrl }
}
public struct PodcastSubscriptionDraft: Codable, Hashable, Sendable {
    public var libraryId: String
    public var folderId: String
    public var path: String
    public var media: PodcastSubscriptionMedia
    public init(libraryId: String, folderId: String, path: String, metadata: PodcastFeedMetadata, autoDownloadEpisodes: Bool = false, autoDownloadSchedule: String? = nil, directoryResult: PodcastDirectoryResult? = nil, typeOverride: String? = nil) {
        self.libraryId = libraryId; self.folderId = folderId; self.path = path
        var metadata = metadata
        var directoryResult = directoryResult
        // An explicit choice takes precedence over both metadata sources.
        if let typeOverride { metadata.type = typeOverride; directoryResult?.type = typeOverride }
        // The feed parser returns image, while the subscription controller downloads imageUrl.
        metadata.imageUrl = metadata.imageUrl ?? metadata.image
        self.media = .init(metadata: metadata, autoDownloadEpisodes: autoDownloadEpisodes, autoDownloadSchedule: autoDownloadSchedule, directoryResult: directoryResult)
    }
}
public struct PodcastSubscriptionMedia: Codable, Hashable, Sendable {
    public var metadata: PodcastFeedMetadata
    public var autoDownloadEpisodes: Bool
    public var autoDownloadSchedule: String?
    public var directoryResult: PodcastDirectoryResult? = nil
    enum CodingKeys: String, CodingKey { case metadata, autoDownloadEpisodes, autoDownloadSchedule }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PodcastSubscriptionMetadata(feed: metadata, directory: directoryResult), forKey: .metadata)
        try c.encode(autoDownloadEpisodes, forKey: .autoDownloadEpisodes)
        try c.encodeIfPresent(autoDownloadSchedule, forKey: .autoDownloadSchedule)
    }
}

/// The create endpoint expects genres and a boolean, unlike RSS parser metadata.
private struct PodcastSubscriptionMetadata: Encodable {
    let title: String; let author: String?; let description: String?; let language: String?
    let feedUrl: String?; let imageUrl: String?; let genres: [String]; let explicit: Bool; let type: String
    let releaseDate: String?; let itunesId: String?; let itunesArtistId: String?; let itunesPageUrl: String?
    init(feed: PodcastFeedMetadata, directory: PodcastDirectoryResult?) {
        func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        title = nonempty(directory?.title) ?? feed.title; author = nonempty(directory?.artistName) ?? feed.author
        description = nonempty(directory?.description) ?? feed.descriptionPlain ?? feed.description
        language = nonempty(directory?.language) ?? feed.language; feedUrl = feed.feedUrl ?? directory?.feedUrl
        imageUrl = nonempty(directory?.cover) ?? feed.imageUrl ?? feed.image; genres = directory?.genres ?? feed.categories
        explicit = directory?.explicit == true || ["yes", "true"].contains(feed.explicit?.lowercased() ?? "")
        type = directory?.type ?? feed.type ?? "episodic"
        releaseDate = directory?.releaseDate; itunesId = directory?.id; itunesArtistId = directory?.artistId; itunesPageUrl = directory?.pageUrl
    }
}
public struct PodcastSettingsUpdate: Codable, Hashable, Sendable {
    public var autoDownloadEpisodes: Bool?
    public var autoDownloadSchedule: String?
    public var maxEpisodesToKeep: Int?
    public var maxNewEpisodesToDownload: Int?
    public var lastEpisodeCheck: Double?
    public init(autoDownloadEpisodes: Bool? = nil, autoDownloadSchedule: String? = nil, maxEpisodesToKeep: Int? = nil, maxNewEpisodesToDownload: Int? = nil, lastEpisodeCheck: Double? = nil) { self.lastEpisodeCheck = lastEpisodeCheck; self.autoDownloadEpisodes = autoDownloadEpisodes; self.autoDownloadSchedule = autoDownloadSchedule; self.maxEpisodesToKeep = maxEpisodesToKeep; self.maxNewEpisodesToDownload = maxNewEpisodesToDownload }
}
public struct PodcastEpisodeUpdate: Codable, Hashable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var description: String?
    public var pubDate: String?
    public var publishedAt: Double?
    public var episode: String?
    public var season: String?
    public var episodeType: String?
    public var enclosure: PodcastEnclosure?
    public var chapters: [Chapter]?
    public init(title: String? = nil, subtitle: String? = nil, description: String? = nil, pubDate: String? = nil, publishedAt: Double? = nil, episode: String? = nil, season: String? = nil, episodeType: String? = nil, enclosure: PodcastEnclosure? = nil, chapters: [Chapter]? = nil) { self.title = title; self.subtitle = subtitle; self.description = description; self.pubDate = pubDate; self.publishedAt = publishedAt; self.episode = episode; self.season = season; self.episodeType = episodeType; self.enclosure = enclosure; self.chapters = chapters }
}
public struct PodcastServerDownload: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var episodeDisplayTitle: String?
    public var libraryItemId: String?
    public var podcastTitle: String?
    public var isFinished: Bool
    public var failed: Bool
    public var startedAt: Double?
    public var createdAt: Double?
    public var finishedAt: Double?
}
public struct PersonalAccountDetails: Decodable, Sendable {
    public var user: UserAccount
    public var userDefaultLibraryId: String?
    public var ereaderDevices: [EReaderDevice]
}
