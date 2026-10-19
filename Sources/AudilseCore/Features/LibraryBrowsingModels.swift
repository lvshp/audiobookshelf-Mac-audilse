import Foundation

public struct LibraryBrowsingCapabilities: Hashable, Sendable {
    public let version: ServerVersion
    public init(serverVersion: String?) { version = ServerVersion(serverVersion ?? "2.26.0") }
    /// Verified supported in 2.36.1/2.37.1 and absent from 2.26.0.
    public var hasProgressDateSorting: Bool { version >= ServerVersion("2.36.1") }
    /// Older servers silently replace progress sorting with title unless a progress filter supplies the join.
    public func supportsProgressSorting(filter: LibraryBrowseFilter) -> Bool {
        if case .progress = filter { return true }
        return version >= ServerVersion("2.36.1")
    }
}

public enum LibraryBrowseSort: String, Codable, CaseIterable, Sendable {
    case title = "media.metadata.title"
    case authorFirstLast = "media.metadata.authorName"
    case authorLastFirst = "media.metadata.authorNameLF"
    case podcastAuthor = "media.metadata.author"
    case publishedYear = "media.metadata.publishedYear"
    case addedAt, size
    case duration = "media.duration"
    case fileCreated = "birthtimeMs"
    case fileModified = "mtimeMs"
    case progress
    case progressStarted = "progress.createdAt"
    case progressFinished = "progress.finishedAt"
    case random, sequence
    case episodeCount = "media.numTracks"
    public var defaultsToAscending: Bool { [.title, .authorFirstLast, .authorLastFirst, .podcastAuthor, .sequence].contains(self) }
    public static func available(mediaType: String, filter: LibraryBrowseFilter = .all, serverVersion: String? = "2.37.1") -> [Self] {
        if mediaType == "podcast" { return [.title, .podcastAuthor, .addedAt, .size, .episodeCount, .fileCreated, .fileModified, .random] }
        let capabilities = LibraryBrowsingCapabilities(serverVersion: serverVersion)
        var result: [Self] = [.title, .authorFirstLast, .authorLastFirst, .publishedYear, .addedAt, .size, .duration, .fileCreated, .fileModified]
        if capabilities.supportsProgressSorting(filter: filter) { result.append(.progress) }
        if capabilities.hasProgressDateSorting { result += [.progressStarted, .progressFinished] }
        result.append(.random)
        if case .series = filter { result.append(.sequence) }
        return result
    }
}
public enum LibraryProgressFilter: String, Codable, CaseIterable, Sendable {
    case finished, inProgress = "in-progress", notStarted = "not-started", notFinished = "not-finished"
    case audioInProgress = "audio-in-progress", ebookInProgress = "ebook-in-progress", ebookFinished = "ebook-finished"
}
public enum LibraryMissingField: String, Codable, CaseIterable, Sendable {
    case asin, isbn, authors, chapters, cover, description, genres, language, narrators, publishedYear, publisher, series, subtitle, tags
}
public enum LibraryTrackFilter: String, Codable, CaseIterable, Sendable { case none, single, multi }
public enum LibraryEbookFilter: String, Codable, CaseIterable, Sendable { case ebook, noEbook = "no-ebook", supplementary, noSupplementary = "no-supplementary" }
public enum LibraryBrowseFilter: Codable, Hashable, Sendable {
    case all, genre(String), tag(String), series(String), noSeries, author(String), narrator(String), publisher(String), publishedDecade(String), language(String)
    case progress(LibraryProgressFilter), missing(LibraryMissingField), tracks(LibraryTrackFilter), ebooks(LibraryEbookFilter)
    case abridged, issues, feedOpen, explicit, shareOpen, recent
    public var queryValue: String? {
        func encoded(_ group: String, _ value: String) -> String { group + "." + Data(value.utf8).base64EncodedString() }
        return switch self {
        case .all: nil
        case .genre(let v): encoded("genres", v)
        case .tag(let v): encoded("tags", v)
        case .series(let v): encoded("series", v)
        case .noSeries: encoded("series", "no-series")
        case .author(let v): encoded("authors", v)
        case .narrator(let v): encoded("narrators", v)
        case .publisher(let v): encoded("publishers", v)
        case .publishedDecade(let v): encoded("publishedDecades", v)
        case .language(let v): encoded("languages", v)
        case .progress(let v): encoded("progress", v.rawValue)
        case .missing(let v): encoded("missing", v.rawValue)
        case .tracks(let v): encoded("tracks", v.rawValue)
        case .ebooks(let v): encoded("ebooks", v.rawValue)
        case .abridged: "abridged"
        case .issues: "issues"
        case .feedOpen: "feed-open"
        case .explicit: "explicit"
        case .shareOpen: "share-open"
        case .recent: "recent"
        }
    }
    public func isAvailable(mediaType: String, user: UserAccount? = nil) -> Bool {
        if let user, !user.isActive { return false }
        if case .explicit = self, let user, !user.permissions.accessExplicitContent { return false }
        if case .shareOpen = self, let user, !user.isAdmin { return false }
        if mediaType == "podcast" {
            return switch self { case .all, .genre, .tag, .language, .issues, .feedOpen, .explicit, .recent: true; default: false }
        }
        return true
    }
}
public enum LibraryBrowseInclude: String, Codable, CaseIterable, Sendable { case rssFeed = "rssfeed", share, numEpisodesIncomplete = "numepisodesincomplete" }
public struct LibraryBrowseOptions: Codable, Hashable, Sendable {
    public var page: Int
    public var limit: Int
    public var sort: LibraryBrowseSort
    public var descending: Bool
    public var filter: LibraryBrowseFilter
    public var collapseSeries: Bool
    public var includes: [LibraryBrowseInclude]
    public var minified: Bool
    public init(page: Int = 0, limit: Int = 60, sort: LibraryBrowseSort = .title, descending: Bool = false,
                filter: LibraryBrowseFilter = .all, collapseSeries: Bool = false,
                includes: [LibraryBrowseInclude] = [.rssFeed, .share, .numEpisodesIncomplete], minified: Bool = true) {
        self.page = page; self.limit = limit; self.sort = sort; self.descending = descending; self.filter = filter
        self.collapseSeries = collapseSeries; self.includes = includes; self.minified = minified
    }
}

public struct CollapsedLibrarySeries: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var nameIgnorePrefix: String?
    public var sequence: String?
    public var numBooks: Int
    public var libraryItemIds: [String]
    /// ABS formats ranges as a display string, e.g. "1-3, 5".
    public var seriesSequenceList: String?
    public init(id: String, name: String, nameIgnorePrefix: String? = nil, sequence: String? = nil, numBooks: Int = 0, libraryItemIds: [String] = [], seriesSequenceList: String? = nil) {
        self.id = id; self.name = name; self.nameIgnorePrefix = nameIgnorePrefix; self.sequence = sequence; self.numBooks = numBooks; self.libraryItemIds = libraryItemIds; self.seriesSequenceList = seriesSequenceList
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = c.value(.name, default: "")
        nameIgnorePrefix = try c.decodeIfPresent(String.self, forKey: .nameIgnorePrefix)
        sequence = (try? c.decodeIfPresent(String.self, forKey: .sequence)) ?? (try? c.decodeIfPresent(Double.self, forKey: .sequence)).map { String($0) }
        numBooks = c.value(.numBooks, default: 0); libraryItemIds = c.value(.libraryItemIds, default: [])
        seriesSequenceList = (try? c.decodeIfPresent(String.self, forKey: .seriesSequenceList)) ?? (try? c.decodeIfPresent([String].self, forKey: .seriesSequenceList))?.joined(separator: ", ")
    }
}
public struct LibraryBrowseMediaSummary: Codable, Hashable, Sendable {
    public var size: Int64?
    public var numAudioFiles: Int?
    public var numChapters: Int?
    public var numEpisodes: Int?
    public var ebookFormat: String?
    public init(size: Int64? = nil, numAudioFiles: Int? = nil, numChapters: Int? = nil, numEpisodes: Int? = nil, ebookFormat: String? = nil) {
        self.size = size; self.numAudioFiles = numAudioFiles; self.numChapters = numChapters; self.numEpisodes = numEpisodes; self.ebookFormat = ebookFormat
    }
}
/// Decodes the flattened item wire shape without changing existing LibraryItem consumers.
public struct LibraryBrowseEntry: Codable, Hashable, Identifiable, Sendable {
    public var item: LibraryItem
    public var collapsedSeries: CollapsedLibrarySeries?
    public var rssFeed: RSSFeed?
    public var mediaItemShare: MediaShare?
    public var recentEpisode: PodcastEpisode?
    public var numEpisodesIncomplete: Int?
    public var mediaSummary: LibraryBrowseMediaSummary?
    public var addedAt: Double?
    public var fileCreatedAt: Double?
    public var fileModifiedAt: Double?
    public var id: String {
        if let collapsedSeries { return "series:" + collapsedSeries.id }
        if let recentEpisode { return "episode:\(item.id.utf8.count):\(item.id)\(recentEpisode.id.utf8.count):\(recentEpisode.id)" }
        return "item:" + item.id
    }
    public init(item: LibraryItem, collapsedSeries: CollapsedLibrarySeries? = nil, rssFeed: RSSFeed? = nil, mediaItemShare: MediaShare? = nil,
                recentEpisode: PodcastEpisode? = nil, numEpisodesIncomplete: Int? = nil, mediaSummary: LibraryBrowseMediaSummary? = nil,
                addedAt: Double? = nil, fileCreatedAt: Double? = nil, fileModifiedAt: Double? = nil) {
        self.item = item; self.collapsedSeries = collapsedSeries; self.rssFeed = rssFeed; self.mediaItemShare = mediaItemShare
        self.recentEpisode = recentEpisode; self.numEpisodesIncomplete = numEpisodesIncomplete; self.mediaSummary = mediaSummary
        self.addedAt = addedAt; self.fileCreatedAt = fileCreatedAt; self.fileModifiedAt = fileModifiedAt
    }
    private enum CodingKeys: String, CodingKey { case collapsedSeries, rssFeed, mediaItemShare, recentEpisode, numEpisodesIncomplete, media, addedAt, birthtimeMs, mtimeMs }
    public init(from decoder: Decoder) throws {
        item = try LibraryItem(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsedSeries = try c.decodeIfPresent(CollapsedLibrarySeries.self, forKey: .collapsedSeries)
        rssFeed = try c.decodeIfPresent(RSSFeed.self, forKey: .rssFeed); mediaItemShare = try c.decodeIfPresent(MediaShare.self, forKey: .mediaItemShare)
        recentEpisode = try c.decodeIfPresent(PodcastEpisode.self, forKey: .recentEpisode)
        numEpisodesIncomplete = try c.decodeIfPresent(Int.self, forKey: .numEpisodesIncomplete)
        mediaSummary = try c.decodeIfPresent(LibraryBrowseMediaSummary.self, forKey: .media)
        addedAt = try c.decodeIfPresent(Double.self, forKey: .addedAt); fileCreatedAt = try c.decodeIfPresent(Double.self, forKey: .birthtimeMs); fileModifiedAt = try c.decodeIfPresent(Double.self, forKey: .mtimeMs)
    }
    public func encode(to encoder: Encoder) throws {
        try item.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(collapsedSeries, forKey: .collapsedSeries); try c.encodeIfPresent(rssFeed, forKey: .rssFeed)
        try c.encodeIfPresent(mediaItemShare, forKey: .mediaItemShare); try c.encodeIfPresent(recentEpisode, forKey: .recentEpisode)
        try c.encodeIfPresent(numEpisodesIncomplete, forKey: .numEpisodesIncomplete)
        try c.encodeIfPresent(addedAt, forKey: .addedAt); try c.encodeIfPresent(fileCreatedAt, forKey: .birthtimeMs); try c.encodeIfPresent(fileModifiedAt, forKey: .mtimeMs)
        if let mediaSummary { try c.encode(LibraryBrowseMergedMedia(media: item.media, summary: mediaSummary), forKey: .media) }
    }
}

private struct LibraryBrowseMergedMedia: Encodable {
    let media: ItemMedia
    let summary: LibraryBrowseMediaSummary
    func encode(to encoder: Encoder) throws { try media.encode(to: encoder); try summary.encode(to: encoder) }
}

public struct LibraryBrowsePage: Codable, Hashable, Sendable {
    public var results: [LibraryBrowseEntry]
    public var total: Int?
    public var page: Int
    public var limit: Int
    public var hasMore: Bool { limit > 0 && (total.map { $0 > 0 && page >= 0 && page < ($0 - 1) / limit } ?? (results.count >= limit)) }
    public init(results: [LibraryBrowseEntry], total: Int? = nil, page: Int, limit: Int) { self.results = results; self.total = total; self.page = page; self.limit = limit }
    private enum CodingKeys: String, CodingKey { case results, total, page, limit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([LibraryBrowseEntry].self, forKey: .results)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        page = (try? c.decode(Int.self, forKey: .page)) ?? Int(c.value(.page, default: "0")) ?? 0
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? Int(c.value(.limit, default: "0")) ?? 0
    }
}
public struct LibraryFilterEntity: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct LibraryFilterMetadata: Codable, Hashable, Sendable {
    public var authors: [LibraryFilterEntity]
    public var series: [LibraryFilterEntity]
    public var genres: [String]
    public var tags: [String]
    public var narrators: [String]
    public var languages: [String]
    public var publishers: [String]
    public var publishedDecades: [String]
    public var bookCount: Int
    public var authorCount: Int
    public var seriesCount: Int
    public var podcastCount: Int
    public var numIssues: Int
    public var loadedAt: Double?
    public init(authors: [LibraryFilterEntity] = [], series: [LibraryFilterEntity] = [], genres: [String] = [], tags: [String] = [], narrators: [String] = [], languages: [String] = [], publishers: [String] = [], publishedDecades: [String] = [], bookCount: Int = 0, authorCount: Int = 0, seriesCount: Int = 0, podcastCount: Int = 0, numIssues: Int = 0, loadedAt: Double? = nil) {
        self.authors = authors; self.series = series; self.genres = genres; self.tags = tags; self.narrators = narrators
        self.languages = languages; self.publishers = publishers; self.publishedDecades = publishedDecades; self.bookCount = bookCount
        self.authorCount = authorCount; self.seriesCount = seriesCount; self.podcastCount = podcastCount; self.numIssues = numIssues; self.loadedAt = loadedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authors = c.value(.authors, default: []); series = c.value(.series, default: [])
        genres = c.value(.genres, default: []); tags = c.value(.tags, default: []); narrators = c.value(.narrators, default: [])
        languages = c.value(.languages, default: []); publishers = c.value(.publishers, default: [])
        publishedDecades = c.value(.publishedDecades, default: [])
        bookCount = c.value(.bookCount, default: 0); authorCount = c.value(.authorCount, default: 0); seriesCount = c.value(.seriesCount, default: 0)
        podcastCount = c.value(.podcastCount, default: 0); numIssues = c.value(.numIssues, default: 0); loadedAt = try c.decodeIfPresent(Double.self, forKey: .loadedAt)
    }
}

public enum PersonalizedShelfEntity: Hashable, Sendable {
    case item(LibraryBrowseEntry), series(BookSeries), author(Author), unsupported(ABSDiagnosticValue)
}
public struct PersonalizedLibraryShelf: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var labelStringKey: String?
    public var type: String
    public var entities: [PersonalizedShelfEntity]
    public var total: Int
    public init(id: String, label: String, labelStringKey: String? = nil, type: String, entities: [PersonalizedShelfEntity] = [], total: Int = 0) {
        self.id = id; self.label = label; self.labelStringKey = labelStringKey; self.type = type; self.entities = entities; self.total = total
    }
    private enum CodingKeys: String, CodingKey { case id, label, labelStringKey, type, entities, total }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); label = c.value(.label, default: ""); labelStringKey = try c.decodeIfPresent(String.self, forKey: .labelStringKey)
        type = try c.decode(String.self, forKey: .type); total = c.value(.total, default: 0)
        switch type {
        case "book", "podcast", "episode": entities = try c.decode([LibraryBrowseEntry].self, forKey: .entities).map(PersonalizedShelfEntity.item)
        case "series": entities = try c.decode([BookSeries].self, forKey: .entities).map(PersonalizedShelfEntity.series)
        case "authors": entities = try c.decode([Author].self, forKey: .entities).map(PersonalizedShelfEntity.author)
        default: entities = try c.decode([ABSDiagnosticValue].self, forKey: .entities).map(PersonalizedShelfEntity.unsupported)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label); try c.encodeIfPresent(labelStringKey, forKey: .labelStringKey)
        try c.encode(type, forKey: .type); try c.encode(total, forKey: .total)
        var rows = c.nestedUnkeyedContainer(forKey: .entities)
        for entity in entities {
            switch entity { case .item(let v): try rows.encode(v); case .series(let v): try rows.encode(v); case .author(let v): try rows.encode(v); case .unsupported(let v): try rows.encode(v) }
        }
    }
}
