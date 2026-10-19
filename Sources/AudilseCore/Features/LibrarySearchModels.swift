import Foundation

/// ABS searches each category independently. The response has no total or page.
public struct LibrarySearchResponse: Codable, Hashable, Sendable {
    public var books: [LibrarySearchItemMatch]
    public var podcasts: [LibrarySearchItemMatch]
    public var episodes: [LibrarySearchItemMatch]
    public var authors: [Author]
    public var series: [LibrarySearchSeriesMatch]
    public var tags: [LibrarySearchNamedCount]
    public var genres: [LibrarySearchNamedCount]
    public var narrators: [LibrarySearchNarrator]

    public init(books: [LibrarySearchItemMatch] = [], podcasts: [LibrarySearchItemMatch] = [],
                episodes: [LibrarySearchItemMatch] = [], authors: [Author] = [],
                series: [LibrarySearchSeriesMatch] = [], tags: [LibrarySearchNamedCount] = [],
                genres: [LibrarySearchNamedCount] = [], narrators: [LibrarySearchNarrator] = []) {
        self.books = books; self.podcasts = podcasts; self.episodes = episodes; self.authors = authors
        self.series = series; self.tags = tags; self.genres = genres; self.narrators = narrators
    }

    private enum CodingKeys: String, CodingKey {
        case books = "book", podcasts = "podcast", episodes, authors, series, tags, genres, narrators
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([LibrarySearchItemMatch].self, forKey: .books) ?? []
        podcasts = try c.decodeIfPresent([LibrarySearchItemMatch].self, forKey: .podcasts) ?? []
        episodes = try c.decodeIfPresent([LibrarySearchItemMatch].self, forKey: .episodes) ?? []
        authors = try c.decodeIfPresent([Author].self, forKey: .authors) ?? []
        series = try c.decodeIfPresent([LibrarySearchSeriesMatch].self, forKey: .series) ?? []
        tags = try c.decodeIfPresent([LibrarySearchNamedCount].self, forKey: .tags) ?? []
        genres = try c.decodeIfPresent([LibrarySearchNamedCount].self, forKey: .genres) ?? []
        narrators = try c.decodeIfPresent([LibrarySearchNarrator].self, forKey: .narrators) ?? []
    }
}

/// Episode matches contain a parent item with a top-level `recentEpisode`.
/// LibraryBrowseEntry retains that episode and gives distinct matches stable IDs.
public struct LibrarySearchItemMatch: Codable, Hashable, Identifiable, Sendable {
    public var libraryItem: LibraryBrowseEntry
    public var id: String { libraryItem.id }
    public init(libraryItem: LibraryBrowseEntry) { self.libraryItem = libraryItem }
}

/// Search books are a preview, not a complete expanded series-detail response.
public struct LibrarySearchSeriesMatch: Codable, Hashable, Identifiable, Sendable {
    public var series: BookSeries
    public var books: [LibraryItem]
    public var id: String { series.id }
    public init(series: BookSeries, books: [LibraryItem] = []) { self.series = series; self.books = books }
}

public struct LibrarySearchNamedCount: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    /// Server catalog count; search does not return a filtered-result total.
    public var numItems: Int
    public var id: String { name }
    public init(name: String, numItems: Int = 0) { self.name = name; self.numItems = numItems }
    private enum CodingKeys: String, CodingKey { case name, numItems }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        numItems = try c.decodeIfPresent(Int.self, forKey: .numItems) ?? 0
    }
}

public struct LibrarySearchNarrator: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var numBooks: Int
    public var id: String { name }
    public init(name: String, numBooks: Int = 0) { self.name = name; self.numBooks = numBooks }
    private enum CodingKeys: String, CodingKey { case name, numBooks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        numBooks = try c.decodeIfPresent(Int.self, forKey: .numBooks) ?? 0
    }
}
