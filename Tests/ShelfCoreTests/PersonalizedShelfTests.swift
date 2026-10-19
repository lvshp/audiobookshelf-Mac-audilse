import Foundation
import Testing
@testable import ShelfCore

struct PersonalizedShelfTests {
    private func decode(_ wire: String) throws -> [PersonalizedLibraryShelf] {
        try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: Data(wire.utf8))
    }

    @Test func fixedReleaseShelfIDsAndEntityTypesPreserveServerOrder() throws {
        let book = #"{"id":"book","libraryId":"library","mediaType":"book","media":{"numTracks":1,"metadata":{"title":"Book"}}}"#
        let ebook = #"{"id":"ebook","libraryId":"library","mediaType":"book","media":{"numTracks":0,"ebookFormat":"epub","metadata":{"title":"Ebook"}}}"#
        let bookWire = """
        [{"id":"continue-listening","label":"Continue Listening","type":"book","entities":[\(book)],"total":3},
        {"id":"continue-reading","label":"Continue Reading","type":"book","entities":[\(ebook)],"total":3},
        {"id":"continue-series","label":"Continue Series","type":"book","entities":[\(book)],"total":1},
        {"id":"recently-added","label":"Recently Added","type":"book","entities":[\(book)],"total":1},
        {"id":"recent-series","label":"Recent Series","type":"series","entities":[{"id":"series","name":"Series","books":[\(book)]}],"total":8},
        {"id":"discover","label":"Discover","type":"book","entities":[\(book)],"total":1},
        {"id":"listen-again","label":"Listen Again","type":"book","entities":[\(book)],"total":2},
        {"id":"read-again","label":"Read Again","type":"book","entities":[\(ebook)],"total":2},
        {"id":"newest-authors","label":"Newest Authors","type":"authors","entities":[{"id":"author","name":"Author","numBooks":9}],"total":1}]
        """
        let shelves = try decode(bookWire)
        #expect(shelves.compactMap(\.kind) == [.continueListening, .continueReading, .continueSeries, .recentlyAdded, .recentSeries, .discover, .listenAgain, .readAgain, .newestAuthors])
        #expect(shelves[0].total == 3 && shelves[0].entities.count == 1)
        #expect(shelves[1].total == 3 && shelves[1].entities.count == 1)
        guard case .item(let reading) = shelves[1].entities.first else { Issue.record("Reading shelf is a minified book"); return }
        #expect(reading.item.media.numTracks == 0 && reading.mediaSummary?.ebookFormat == "epub")
        guard case .series(let series) = shelves[4].entities.first else { Issue.record("Series shelf type"); return }
        #expect(series.books.first?.id == "book" && series.books.first?.media.metadata.authors.isEmpty == true)
        guard case .author(let author) = shelves[8].entities.first else { Issue.record("Authors shelf type"); return }
        #expect(author.numBooks == 9)
        #expect(try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: JSONEncoder().encode(shelves)) == shelves)
    }

    @Test func podcastShelvesKeepEpisodeMetadataAndIdentityThroughCacheRoundTrip() throws {
        let podcast = ##"{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"Show"}},"recentEpisode":{"id":"episode-3","title":"Episode title","episode":"#3","season":"2","publishedAt":1234,"audioFile":{"ino":"file","duration":60}}}"##
        let next = podcast.replacingOccurrences(of: "episode-3", with: "episode-4").replacingOccurrences(of: "#3", with: "#4")
        let plain = #"{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"Show"},"numEpisodes":2},"numEpisodesIncomplete":1}"#
        let shelves = try decode("""
        [{"id":"continue-listening","label":"Continue Listening","type":"episode","entities":[\(podcast)],"total":1},
        {"id":"newest-episodes","label":"Newest Episodes","type":"episode","entities":[\(podcast),\(next)],"total":2},
        {"id":"recently-added","label":"Recently Added","type":"podcast","entities":[\(plain)],"total":1},
        {"id":"listen-again","label":"Listen Again","type":"episode","entities":[\(podcast)],"total":1}]
        """)
        #expect(shelves.compactMap(\.kind) == [.continueListening, .newestEpisodes, .recentlyAdded, .listenAgain])
        guard case .item(let entry) = shelves[1].entities.first else { Issue.record("Episode is nested in a parent item"); return }
        #expect(entry.item.title == "Show" && entry.recentEpisode?.title == "Episode title")
        #expect(entry.recentEpisode?.episode == "#3" && entry.recentEpisode?.season == "2")
        #expect(entry.recentEpisode?.audioFile?.duration == 60)
        #expect(shelves[1].entityIdentifier(for: shelves[1].entities[0]) != shelves[1].entityIdentifier(for: shelves[1].entities[1]))
        let restored = try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: JSONEncoder().encode(shelves))
        #expect(restored == shelves)
        #expect(restored[1].entities.map { restored[1].entityIdentifier(for: $0) } == shelves[1].entities.map { shelves[1].entityIdentifier(for: $0) })
        #expect(PodcastEpisode(id: "old-cache", title: "Old").episode == nil)
    }

    @Test func theSameNextBookInTwoSeriesRetainsDistinctRecommendationContext() throws {
        let shelves = try decode(#"[{"id":"continue-series","label":"Continue Series","type":"book","entities":[{"id":"next-book","libraryId":"library","mediaType":"book","media":{"metadata":{"title":"Next","series":{"id":"series-A","name":"A","sequence":"2"}}}},{"id":"next-book","libraryId":"library","mediaType":"book","media":{"metadata":{"title":"Next","series":{"id":"series-B","name":"B","sequence":"3"}}}}],"total":2}]"#)
        let shelf = try #require(shelves.first)
        let identities = shelf.entities.map { shelf.entityIdentifier(for: $0) }
        #expect(Set(identities).count == 2)
        guard case .item(let first) = shelf.entities[0], case .item(let second) = shelf.entities[1] else { Issue.record("Next-book payload"); return }
        #expect(first.id == second.id)
        #expect(first.item.media.metadata.series.first?.sequence == "2")
        let restored = try JSONDecoder().decode(PersonalizedLibraryShelf.self, from: JSONEncoder().encode(shelf))
        #expect(restored.entities.map { restored.entityIdentifier(for: $0) } == identities)
    }

    @Test func emptyAndFutureShelvesRemainDecodableWithoutInventingKnownRoutes() throws {
        #expect(try decode("[]").isEmpty)
        let empty = PersonalizedLibraryShelf(id: "discover", label: "Discover", type: "book")
        #expect(empty.kind == .discover && empty.entities.isEmpty && empty.total == 0)
        #expect(try JSONDecoder().decode(PersonalizedLibraryShelf.self, from: JSONEncoder().encode(empty)) == empty)
        let shelves = try decode(#"[{"id":"future-shelf","label":"Future","type":"future","entities":[{"extra":true,"id":"future"},42,null],"total":99}]"#)
        #expect(shelves[0].kind == nil && shelves[0].entities.count == 3 && shelves[0].total == 99)
        let reordered = PersonalizedShelfEntity.unsupported(.object(["id": .string("future"), "extra": .bool(true)]))
        #expect(shelves[0].entityIdentifier(for: shelves[0].entities[0]) == shelves[0].entityIdentifier(for: reordered))
        #expect(try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: JSONEncoder().encode(shelves)) == shelves)
        #expect(throws: (any Error).self) { try decode(#"[{"label":"Missing identity","type":"book","entities":[]}]"#) }
    }
}
