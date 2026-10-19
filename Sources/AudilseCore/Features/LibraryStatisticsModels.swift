import Foundation

/// The library-wide catalog snapshot returned by ABS 2.26–2.37.
/// This endpoint counts the library, not the current user's listening activity.
public struct LibraryStatistics: Codable, Hashable, Sendable {
    public var totalItems: Int
    public var totalAuthors: Int?
    public var totalGenres: Int
    public var totalDuration: Double
    public var totalSize: Double
    public var numAudioTracks: Int
    public var authorsWithCount: [LibraryStatisticsAuthor]?
    public var genresWithCount: [LibraryStatisticsGenre]
    public var longestItems: [LibraryStatisticsDurationItem]
    public var largestItems: [LibraryStatisticsSizeItem]

    public init(totalItems: Int, totalAuthors: Int? = nil, totalGenres: Int, totalDuration: Double,
                totalSize: Double, numAudioTracks: Int, authorsWithCount: [LibraryStatisticsAuthor]? = nil,
                genresWithCount: [LibraryStatisticsGenre], longestItems: [LibraryStatisticsDurationItem],
                largestItems: [LibraryStatisticsSizeItem]) {
        self.totalItems = totalItems; self.totalAuthors = totalAuthors; self.totalGenres = totalGenres
        self.totalDuration = totalDuration; self.totalSize = totalSize; self.numAudioTracks = numAudioTracks
        self.authorsWithCount = authorsWithCount; self.genresWithCount = genresWithCount
        self.longestItems = longestItems; self.largestItems = largestItems
    }
}

public struct LibraryStatisticsAuthor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var count: Int
    public init(id: String, name: String, count: Int) { self.id = id; self.name = name; self.count = count }
}

public struct LibraryStatisticsGenre: Codable, Hashable, Sendable {
    public var genre: String
    public var count: Int
    public init(genre: String, count: Int) { self.genre = genre; self.count = count }
}

public struct LibraryStatisticsDurationItem: Codable, Hashable, Identifiable, Sendable {
    /// A library-item ID, not the internal Book/Podcast model ID.
    public var id: String
    public var title: String
    /// Podcasts with no downloaded episodes may have a null SQL SUM(duration).
    public var duration: Double?
    public init(id: String, title: String, duration: Double?) { self.id = id; self.title = title; self.duration = duration }
}

public struct LibraryStatisticsSizeItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var size: Double
    public init(id: String, title: String, size: Double) { self.id = id; self.title = title; self.size = size }
}
