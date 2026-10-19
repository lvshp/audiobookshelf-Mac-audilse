import Foundation

public struct PodcastDirectoryResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String?
    public var artistId: String?
    public var description: String?
    public var language: String?
    public var feedUrl: String?
    public var cover: String?
    public var pageUrl: String?
    public var releaseDate: String?
    public var genres: [String]
    public var trackCount: Int
    public var explicit: Bool
    public var type: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? String(c.value(.id, default: 0))
        title = c.value(.title, default: ""); artistName = try c.decodeIfPresent(String.self, forKey: .artistName)
        artistId = (try? c.decodeIfPresent(String.self, forKey: .artistId)) ?? (try? c.decodeIfPresent(Int64.self, forKey: .artistId)).map(String.init)
        description = try c.decodeIfPresent(String.self, forKey: .description); language = try c.decodeIfPresent(String.self, forKey: .language)
        feedUrl = try c.decodeIfPresent(String.self, forKey: .feedUrl); cover = try c.decodeIfPresent(String.self, forKey: .cover)
        pageUrl = try c.decodeIfPresent(String.self, forKey: .pageUrl); releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        genres = c.value(.genres, default: []); trackCount = c.value(.trackCount, default: 0); explicit = c.value(.explicit, default: false)
        type = try c.decodeIfPresent(String.self, forKey: .type)
    }
}

public struct ExistingPodcastTitle: Decodable, Hashable, Identifiable, Sendable {
    public var title: String
    public var itunesId: String?
    public var libraryItemId: String
    public var libraryId: String
    public var id: String { libraryItemId }
}

/// Complete episode metadata returned by GET episode, without expanding the base model contract.
public struct PodcastEpisodeDetails: Decodable, Hashable, Identifiable, Sendable {
    public var base: PodcastEpisode
    public var season: String?
    public var episodeNumber: String?
    public var episodeType: String?
    public var pubDate: String?
    public var enclosure: PodcastEnclosure?
    public var chapters: [Chapter]
    public var id: String { base.id }
    private enum CodingKeys: String, CodingKey { case season, episode, episodeType, pubDate, enclosure, chapters }
    public init(from decoder: Decoder) throws {
        base = try PodcastEpisode(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = try c.decodeIfPresent(String.self, forKey: .season); episodeNumber = try c.decodeIfPresent(String.self, forKey: .episode)
        episodeType = try c.decodeIfPresent(String.self, forKey: .episodeType); pubDate = try c.decodeIfPresent(String.self, forKey: .pubDate)
        enclosure = try c.decodeIfPresent(PodcastEnclosure.self, forKey: .enclosure); chapters = c.value(.chapters, default: [])
    }
}

public struct RecentPodcastEpisode: Decodable, Hashable, Identifiable, Sendable {
    public var details: PodcastEpisodeDetails
    public var libraryItemId: String
    public var libraryId: String
    public var podcast: ItemMedia
    public var id: String { details.id }
    public var episode: PodcastEpisode { details.base }
    private enum CodingKeys: String, CodingKey { case libraryItemId, libraryId, podcast }
    public init(from decoder: Decoder) throws {
        details = try PodcastEpisodeDetails(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try c.decode(String.self, forKey: .libraryItemId); libraryId = try c.decode(String.self, forKey: .libraryId)
        podcast = try c.decode(ItemMedia.self, forKey: .podcast)
    }
}

public struct RecentPodcastEpisodesPage: Decodable, Sendable {
    public var episodes: [RecentPodcastEpisode]
    public var limit: Int
    public var page: Int
    public var hasMore: Bool { limit > 0 && episodes.count >= limit }
    private enum CodingKeys: String, CodingKey { case episodes, limit, page }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try c.decode([RecentPodcastEpisode].self, forKey: .episodes)
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? Int(c.value(.limit, default: "0")) ?? 0
        page = (try? c.decode(Int.self, forKey: .page)) ?? Int(c.value(.page, default: "0")) ?? 0
    }
}

public struct PodcastLibraryDownloadQueue: Decodable, Sendable {
    public var currentDownload: PodcastServerDownload?
    public var queue: [PodcastServerDownload]
}

extension PodcastEpisodeUpdate {
    public init(matching episode: PodcastFeedEpisode) {
        self.init(title: episode.title, subtitle: episode.subtitle ?? "", description: episode.description ?? "",
                  pubDate: episode.pubDate ?? "", publishedAt: episode.publishedAt, episode: episode.episode ?? "",
                  season: episode.season ?? "", episodeType: episode.episodeType ?? "", enclosure: episode.enclosure)
    }
}
