import Foundation
import Testing
@testable import AudilseCore

private final class BrowseHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> Data) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    func respond(_ request: URLRequest) throws -> Data { lock.lock(); let handler = handler; lock.unlock(); return try handler!(request) }
}
private final class BrowseHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = BrowseHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func browseData(_ value: String) -> Data { Data(value.utf8) }
private func browseClient(version: String? = "2.37.1") async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BrowseHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Browsing fixture", baseURL: URL(string: "https://fixture.test/abs")!, username: "reader", serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture-access", userID: "reader"), account: client.tokenAccount)
    return client
}
private let browsingBook = #"{"id":"book","libraryId":"library","mediaType":"book","media":{"metadata":{"title":"一本书","series":{"id":"parent","name":"主系列","sequence":"2"}},"numTracks":2,"duration":600,"size":123456,"numChapters":8,"numAudioFiles":2,"ebookFormat":"epub"}}"#

@Suite(.serialized) struct LibraryBrowsingTests {
    @Test func completeOptionsEncodeOfficialQueryAndKeepProxyPrefix() async throws {
        BrowseHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "GET"); #expect(request.url?.path == "/abs/api/libraries/library id/items")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["sort"] == "media.metadata.authorNameLF"); #expect(query["desc"] == "1")
            #expect(query["page"] == "0"); #expect(query["limit"] == "500")
            #expect(query["filter"] == "genres." + Data("中文/C++".utf8).base64EncodedString())
            #expect(query["collapseseries"] == "1"); #expect(query["minified"] == "0")
            #expect(query["include"] == "numepisodesincomplete,rssfeed,share"); #expect(query["q"] == nil)
            return browseData(#"{"results":[],"total":0,"page":"0","limit":"500"}"#)
        }
        let options = LibraryBrowseOptions(page: -3, limit: 900, sort: .authorLastFirst, descending: true, filter: .genre("中文/C++"), collapseSeries: true, includes: [.share, .rssFeed, .share, .numEpisodesIncomplete], minified: false)
        let page = try await browseClient().browseLibrary(libraryID: "library id", options: options)
        #expect(page.results.isEmpty); #expect(!page.hasMore)
    }

    @Test func filtersCoverEveryFixedWebGroupAndEncodeUnicodeOnce() {
        let filters: [(LibraryBrowseFilter, String, String)] = [
            (.genre("艺术"), "genres", "艺术"), (.tag("家"), "tags", "家"), (.series("s"), "series", "s"),
            (.noSeries, "series", "no-series"), (.author("a"), "authors", "a"), (.narrator("n"), "narrators", "n"),
            (.publisher("p"), "publishers", "p"), (.publishedDecade("1990"), "publishedDecades", "1990"), (.language("zh"), "languages", "zh"),
            (.progress(.notStarted), "progress", "not-started"), (.missing(.publishedYear), "missing", "publishedYear"),
            (.tracks(.multi), "tracks", "multi"), (.ebooks(.noSupplementary), "ebooks", "no-supplementary")
        ]
        for (filter, group, value) in filters {
            let parts = filter.queryValue!.split(separator: ".", maxSplits: 1)
            #expect(String(parts[0]) == group)
            #expect(Data(base64Encoded: String(parts[1])).flatMap { String(data: $0, encoding: .utf8) } == value)
        }
        #expect(LibraryBrowseFilter.all.queryValue == nil)
        #expect([LibraryBrowseFilter.abridged, .issues, .feedOpen, .explicit, .shareOpen, .recent].compactMap(\.queryValue) == ["abridged", "issues", "feed-open", "explicit", "share-open", "recent"])
        #expect(LibraryMissingField.allCases.count == 14)
        #expect(LibraryTrackFilter.allCases.map(\.rawValue) == ["none", "single", "multi"])
        #expect(LibraryEbookFilter.allCases.map(\.rawValue) == ["ebook", "no-ebook", "supplementary", "no-supplementary"])
    }

    @Test func optionsPersistWithoutLosingAssociatedFilters() throws {
        let options = LibraryBrowseOptions(page: 3, limit: 80, sort: .sequence, descending: true, filter: .series("series/ID"), collapseSeries: true)
        #expect(try JSONDecoder().decode(LibraryBrowseOptions.self, from: JSONEncoder().encode(options)) == options)
    }

    @Test func sortAvailabilityMatchesWebAndVersionDifferences() {
        let books = LibraryBrowseSort.available(mediaType: "book")
        #expect(books.count == 13); #expect(books.contains(.progressStarted)); #expect(!books.contains(.episodeCount))
        #expect(!books.contains(.sequence)); #expect(LibraryBrowseSort.available(mediaType: "book", filter: .series("id")).last == .sequence)
        #expect(LibraryBrowseSort.available(mediaType: "podcast") == [.title, .podcastAuthor, .addedAt, .size, .episodeCount, .fileCreated, .fileModified, .random])
        #expect(!LibraryBrowseSort.available(mediaType: "book", serverVersion: "2.26.0").contains(.progressStarted))
        #expect(!LibraryBrowseSort.available(mediaType: "book", serverVersion: "2.26.0").contains(.progress))
        #expect(LibraryBrowseSort.available(mediaType: "book", filter: .progress(.inProgress), serverVersion: "2.26.0").contains(.progress))
        #expect(!LibraryBrowseSort.available(mediaType: "book", serverVersion: nil).contains(.progressFinished))
        #expect(LibraryBrowseSort.available(mediaType: "book", serverVersion: "2.36.1").contains(.progressFinished))
        #expect(LibraryBrowseSort.title.defaultsToAscending); #expect(!LibraryBrowseSort.addedAt.defaultsToAscending)
    }

    @Test func legacyProgressSortRequiresProgressFilterInsteadOfSilentlySortingByTitle() async throws {
        BrowseHTTPProtocol.state.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "sort" })?.value == "progress")
            #expect(query?.first(where: { $0.name == "filter" })?.value == LibraryBrowseFilter.progress(.inProgress).queryValue)
            return browseData(#"{"results":[],"total":0,"page":"0","limit":"60"}"#)
        }
        let client = await browseClient(version: "2.26.0")
        do { _ = try await client.browseLibrary(libraryID: "library", options: .init(sort: .progress)); Issue.record("Expected unsupported combination") }
        catch let error as LibraryBrowsingError { #expect(error == .unsupportedSort(.progress, serverVersion: "2.26.0")) }
        let page = try await client.browseLibrary(libraryID: "library", options: .init(sort: .progress, filter: .progress(.inProgress)))
        #expect(page.results.isEmpty)
    }

    @Test(arguments: ["2.26.0", "2.35.0"])
    func unsupportedDateSortingDoesNotSendMisleadingRequest(version: String) async throws {
        BrowseHTTPProtocol.state.install { _ in Issue.record("Unsupported date sorting must fail before HTTP"); return browseData(#"{"results":[]}"#) }
        let client = await browseClient(version: version)
        do { _ = try await client.browseLibrary(libraryID: "library", options: .init(sort: .progressStarted)); Issue.record("Expected version error") }
        catch let error as LibraryBrowsingError { #expect(error == .unsupportedSort(.progressStarted, serverVersion: version)) }
    }

    @Test func collapsedSubseriesAndMediaSummarySurviveCacheRoundTrip() throws {
        let wire = String(browsingBook.dropLast()) + #", "collapsedSeries":{"id":"subseries","name":"子系列","sequence":2.5,"numBooks":3,"libraryItemIds":["book","book2","book3"],"seriesSequenceList":"1-3, 5"},"rssFeed":{"id":"feed","feedUrl":"https://fixture.test/abs/feed/slug"},"mediaItemShare":{"id":"share","mediaItemId":"internal-book","mediaItemType":"book","slug":"slug","isDownloadable":false},"addedAt":1234,"birthtimeMs":1000,"mtimeMs":2000}"#
        let entry = try JSONDecoder().decode(LibraryBrowseEntry.self, from: browseData(wire))
        #expect(entry.id == "series:subseries"); #expect(entry.collapsedSeries?.numBooks == 3)
        #expect(entry.collapsedSeries?.seriesSequenceList == "1-3, 5"); #expect(entry.collapsedSeries?.sequence == "2.5")
        #expect(entry.item.media.metadata.series.first?.sequence == "2"); #expect(entry.rssFeed?.id == "feed")
        #expect(entry.mediaSummary?.ebookFormat == "epub"); #expect(entry.mediaSummary?.size == 123456)
        let restored = try JSONDecoder().decode(LibraryBrowseEntry.self, from: JSONEncoder().encode(entry))
        #expect(restored == entry); #expect(restored.item.title == "一本书"); #expect(restored.item.media.numTracks == 2)
    }

    @Test func paginationHandlesMissingTotalAndUntrustedLargePageWithoutOverflow() throws {
        let full = try JSONDecoder().decode(LibraryBrowsePage.self, from: browseData("{\"results\":[\(browsingBook)],\"page\":\"0\",\"limit\":\"1\"}"))
        #expect(full.total == nil); #expect(full.hasMore)
        let empty = LibraryBrowsePage(results: [], page: 1, limit: 1)
        #expect(!empty.hasMore)
        #expect(!LibraryBrowsePage(results: [], total: Int.max, page: Int.max, limit: 500).hasMore)
        #expect(LibraryBrowsePage(results: [], total: 101, page: 1, limit: 50).hasMore)
        #expect(!LibraryBrowsePage(results: [], total: 100, page: 1, limit: 50).hasMore)
    }

    @Test func filterMetadataIncludesAllBookAndPodcastFields() async throws {
        BrowseHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/libraries/library/filterdata")
            return browseData(#"{"authors":[{"id":"author","name":"作者"}],"series":[{"id":"series","name":"系列"}],"genres":["艺术"],"tags":["标签"],"narrators":["朗读"],"languages":["zh"],"publishers":["出版社"],"publishedDecades":["1990"],"bookCount":12,"authorCount":1,"seriesCount":1,"podcastCount":0,"numIssues":2,"loadedAt":123456}"#)
        }
        let metadata = try await browseClient(version: "2.26.0").libraryFilterMetadata(libraryID: "library")
        #expect(metadata.authors.first?.id == "author"); #expect(metadata.series.first?.name == "系列")
        #expect(metadata.publishedDecades == ["1990"]); #expect(metadata.narrators == ["朗读"])
        #expect(metadata.bookCount == 12); #expect(metadata.numIssues == 2)
        #expect(try JSONDecoder().decode(LibraryFilterMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
        #expect(try JSONDecoder().decode(LibraryFilterMetadata.self, from: browseData(#"{"genres":["News"],"podcastCount":3}"#)).authors.isEmpty)
    }

    @Test func personalizedShelvesDecodeBooksEpisodesSeriesAuthorsAndFutureTypes() async throws {
        let episodeItem = #"{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"节目"}},"recentEpisode":{"id":"episode","title":"新单集","publishedAt":1234}}"#
        let payload = """
        [{"id":"continue-listening","label":"Continue Listening","type":"book","entities":[\(browsingBook)],"total":1},
        {"id":"newest-episodes","label":"Newest Episodes","type":"episode","entities":[\(episodeItem)],"total":1},
        {"id":"recent-series","label":"Recent Series","type":"series","entities":[{"id":"series","name":"系列","books":[\(browsingBook)]}],"total":1},
        {"id":"newest-authors","label":"Newest Authors","type":"authors","entities":[{"id":"author","name":"作者","numBooks":2}],"total":1},
        {"id":"future","label":"Future","type":"future-type","entities":[{"id":"future-entity","extra":true}],"total":1}]
        """
        BrowseHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/libraries/library/personalized")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "limit" })?.value == "20")
            return browseData(payload)
        }
        let shelves = try await browseClient().personalizedShelves(libraryID: "library", limit: 20)
        #expect(shelves.count == 5)
        guard case .item(let episode) = shelves[1].entities.first else { Issue.record("Episode shelf entity"); return }
        #expect(episode.recentEpisode?.id == "episode"); #expect(episode.item.mediaType == "podcast")
        guard case .series(let series) = shelves[2].entities.first else { Issue.record("Series shelf entity"); return }
        #expect(series.books.first?.id == "book")
        guard case .author(let author) = shelves[3].entities.first else { Issue.record("Author shelf entity"); return }
        #expect(author.numBooks == 2)
        #expect(try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: JSONEncoder().encode(shelves)) == shelves)
    }

    @Test func personalizedEpisodesFromTheSamePodcastKeepDistinctStableIdentity() throws {
        let payload = #"[{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"节目"}},"recentEpisode":{"id":"episode1","title":"第一集"}},{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"节目"}},"recentEpisode":{"id":"episode2","title":"第二集"}}]"#
        let episodes = try JSONDecoder().decode([LibraryBrowseEntry].self, from: browseData(payload))
        #expect(episodes[0].item.id == episodes[1].item.id)
        #expect(episodes[0].id != episodes[1].id)
        let restored = try JSONDecoder().decode([LibraryBrowseEntry].self, from: JSONEncoder().encode(episodes))
        #expect(restored.map(\.id) == episodes.map(\.id))
    }

    @Test func filterAvailabilityKeepsPodcastAndPermissionBoundaries() {
        #expect(!LibraryBrowseFilter.author("id").isAvailable(mediaType: "podcast"))
        #expect(LibraryBrowseFilter.language("zh").isAvailable(mediaType: "podcast"))
        let restricted = UserAccount(id: "reader", username: "reader")
        #expect(!LibraryBrowseFilter.explicit.isAvailable(mediaType: "book", user: restricted))
        #expect(!LibraryBrowseFilter.shareOpen.isAvailable(mediaType: "book", user: restricted))
        let administrator = UserAccount(id: "admin", username: "admin", type: "admin")
        #expect(LibraryBrowseFilter.shareOpen.isAvailable(mediaType: "book", user: administrator))
    }
}
