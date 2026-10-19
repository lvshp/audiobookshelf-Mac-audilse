import Foundation
import Testing
@testable import ShelfCore

private final class SearchHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var requests = 0
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = 0
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); let handler = handler; requests += 1; lock.unlock()
        return try handler!(request)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class SearchHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = SearchHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func searchData(_ value: String) -> Data { Data(value.utf8) }
private func searchClient(version: String = "2.37.1") async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SearchHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Search fixture", baseURL: URL(string: "https://search.fixture.test/abs/root")!, username: "reader", serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture-search-access", userID: "reader"), account: client.tokenAccount)
    return client
}

// Mirrors the three releases' book search: wrapped expanded items, direct
// expanded authors, nested series plus separate preview books, and named counts.
private let bookSearchWire = #"""
{
  "book":[{"libraryItem":{"id":"book","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"Book 10","authors":[{"id":"author","name":"作者"}],"series":[{"id":"series","name":"系列","sequence":"2"}]},"numTracks":2,"duration":600,"audioFiles":[{"ino":"audio","metadata":{"filename":"book.m4b"},"duration":600}],"chapters":[{"id":0,"title":"第一章","start":0,"end":600}]}}}],
  "authors":[{"id":"author","libraryId":"books","name":"作者","numBooks":4,"description":"简介"}],
  "series":[{"series":{"id":"series","name":"系列","description":"系列简介"},"books":[{"id":"preview","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"Preview","authors":[],"series":[]},"numTracks":1}}]}],
  "tags":[{"name":"标签","numItems":7}],
  "genres":[{"name":"类型","numItems":9}],
  "narrators":[{"name":"朗读者","numBooks":3}]
}
"""#
private let podcastSearchWire = #"""
{
  "podcast":[{"libraryItem":{"id":"show","libraryId":"podcasts","mediaType":"podcast","media":{"metadata":{"title":"节目","author":"主持人"},"episodes":[]}}}],
  "episodes":[
    {"libraryItem":{"id":"show","libraryId":"podcasts","mediaType":"podcast","media":{"metadata":{"title":"节目"},"episodes":[]},"recentEpisode":{"id":"e1","title":"单集一","publishedAt":1000,"audioFile":{"ino":"f1","metadata":{"filename":"one.mp3"},"duration":30}}}},
    {"libraryItem":{"id":"show","libraryId":"podcasts","mediaType":"podcast","media":{"metadata":{"title":"节目"},"episodes":[]},"recentEpisode":{"id":"e2","title":"单集二","publishedAt":2000,"audioFile":{"ino":"f2","metadata":{"filename":"two.mp3"},"duration":40}}}}
  ],
  "tags":[{"name":"节目标签","numItems":2}],
  "genres":[{"name":"News","numItems":1}]
}
"""#

@Suite(.serialized) struct LibrarySearchTests {
    @Test func bookCategoriesKeepExpandedMediaAndNestedSeriesPreview() throws {
        let result = try JSONDecoder().decode(LibrarySearchResponse.self, from: searchData(bookSearchWire))
        let entry = try #require(result.books.first?.libraryItem)
        #expect(entry.item.id == "book"); #expect(entry.item.media.audioFiles.first?.metadata.filename == "book.m4b")
        #expect(entry.item.media.chapters.first?.title == "第一章"); #expect(entry.item.media.metadata.authors.first?.id == "author")
        #expect(result.authors.first?.numBooks == 4); #expect(result.authors.first?.libraryId == "books")
        #expect(result.series.first?.series.id == "series"); #expect(result.series.first?.books.first?.id == "preview")
        #expect(result.series.first?.series.books.isEmpty == true)
        #expect(result.tags.first?.numItems == 7); #expect(result.genres.first?.name == "类型")
        #expect(result.narrators.first?.numBooks == 3); #expect(result.podcasts.isEmpty); #expect(result.episodes.isEmpty)
    }

    @Test func twoEpisodeMatchesRetainParentAndDistinctEpisodeIdentity() throws {
        let result = try JSONDecoder().decode(LibrarySearchResponse.self, from: searchData(podcastSearchWire))
        #expect(result.podcasts.first?.libraryItem.item.authorName == "主持人")
        #expect(result.episodes.map { $0.libraryItem.item.id } == ["show", "show"])
        #expect(result.episodes.map { $0.libraryItem.recentEpisode?.id } == ["e1", "e2"])
        #expect(result.episodes.map { $0.libraryItem.recentEpisode?.title } == ["单集一", "单集二"])
        #expect(Set(result.episodes.map(\.id)).count == 2)
        #expect(result.episodes.allSatisfy { $0.libraryItem.item.media.episodes.isEmpty })
        #expect(result.books.isEmpty && result.authors.isEmpty && result.series.isEmpty && result.narrators.isEmpty)
        #expect(result.tags.first?.numItems == 2); #expect(result.genres.first?.name == "News")
    }

    @Test(arguments: [bookSearchWire, podcastSearchWire])
    func responseCacheRoundTripPreservesOfficialCategoryKeys(wire: String) throws {
        let result = try JSONDecoder().decode(LibrarySearchResponse.self, from: searchData(wire))
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(LibrarySearchResponse.self, from: encoded) == result)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == Set(["book", "podcast", "episodes", "authors", "series", "tags", "genres", "narrators"]))
        #expect(object["page"] == nil && object["total"] == nil)
    }

    @Test(arguments: [#"{}"#, #"{"book":null,"podcast":null,"episodes":null,"authors":null,"series":null,"tags":null,"genres":null,"narrators":null,"futureCategory":[]}"#])
    func omittedAndNullCategoriesAreEmpty(wire: String) throws {
        #expect(try JSONDecoder().decode(LibrarySearchResponse.self, from: searchData(wire)) == .init())
    }

    @Test(arguments: [#"{"book":{}}"#, #"{"episodes":[{"libraryItem":{"mediaType":"podcast"}}]}"#])
    func malformedKnownPayloadIsNotReportedAsNoMatches(wire: String) {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LibrarySearchResponse.self, from: searchData(wire)) }
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func requestUsesLibraryScopeAndOnlyOfficialQueryParameters(version: String) async throws {
        SearchHTTPProtocol.state.install { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            #expect(request.httpMethod == "GET"); #expect(components.host == "search.fixture.test")
            #expect(components.path == "/abs/root/api/libraries/library id/search")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-search-access")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query == ["q": "中文 C++ / ? & #", "limit": "12"])
            #expect(request.url!.absoluteString.contains("C%2B%2B"))
            return (200, searchData(bookSearchWire))
        }
        let result = try await searchClient(version: version).searchLibrary(libraryID: "library id", query: "  中文 C++ / ? & #\n")
        #expect(result.books.count == 1); #expect(result.authors.count == 1); #expect(SearchHTTPProtocol.state.count == 1)
    }

    @Test(arguments: [(-4, 1), (900, 500)])
    func perCategoryLimitIsBounded(requested: Int, expected: Int) async throws {
        SearchHTTPProtocol.state.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "limit" })?.value == String(expected))
            #expect(query?.count == 2)
            return (200, searchData(#"{}"#))
        }
        _ = try await searchClient().searchLibrary(libraryID: "library", query: "query", limit: requested)
    }

    @Test func emptyQueryClearsResultsWithoutSendingHTTP() async throws {
        SearchHTTPProtocol.state.install { _ in Issue.record("An empty search must not send HTTP"); return (500, Data()) }
        let result = try await searchClient().searchLibrary(libraryID: "library", query: " \n\t ")
        #expect(result == .init()); #expect(SearchHTTPProtocol.state.count == 0)
    }

    @Test func serverFailureDoesNotTurnIntoAnEmptySearch() async throws {
        SearchHTTPProtocol.state.install { _ in (503, searchData("Search unavailable")) }
        do {
            _ = try await searchClient().searchLibrary(libraryID: "library", query: "query")
            Issue.record("Expected a server failure")
        } catch let error as ABSError {
            guard case .http(let status, _) = error else { throw error }
            #expect(status == 503)
        }
    }
}
