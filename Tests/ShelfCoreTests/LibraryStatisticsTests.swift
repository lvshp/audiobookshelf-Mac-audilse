import Foundation
import Testing
@testable import ShelfCore

private let catalogStatisticsJSON = #"{"totalItems":12,"totalAuthors":7,"totalGenres":2,"totalDuration":12001.5,"totalSize":8589934593,"numAudioTracks":31,"authorsWithCount":[{"id":"author-item","name":"Author","count":6}],"genresWithCount":[{"genre":"Fiction","count":8},{"genre":"History","count":6}],"longestItems":[{"id":"library-item-long","title":"Long","duration":7200.25}],"largestItems":[{"id":"library-item-large","title":"Large","size":4294967297}]}"#
private let podcastStatisticsJSON = #"{"totalItems":2,"totalGenres":0,"totalDuration":0,"totalSize":0,"numAudioTracks":0,"genresWithCount":[],"longestItems":[{"id":"library-item-podcast","title":"No episodes","duration":null}],"largestItems":[]}"#

private final class LibraryStatisticsHTTP: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var response: @Sendable (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.unsupportedURL) }
        func install(_ response: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.response = response }
        func reply(_ request: URLRequest) throws -> (Int, Data) { lock.lock(); let response = response; lock.unlock(); return try response(request) }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.reply(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func libraryStatisticsClient(version: String) async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [LibraryStatisticsHTTP.self]
    let tokenStore = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Catalog fixture", baseURL: URL(string: "https://catalog.fixture.test/compat")!, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: tokenStore)
    await tokenStore.save(.init(accessToken: "synthetic-access", userID: "fixture-admin"), account: client.tokenAccount)
    return client
}

@Suite(.serialized) struct LibraryStatisticsTests {
    @Test func bookFieldsKeepCatalogCountsBytesSecondsAndItemIDs() throws {
        let statistics = try JSONDecoder().decode(LibraryStatistics.self, from: Data(catalogStatisticsJSON.utf8))
        #expect(statistics.totalItems == 12 && statistics.totalAuthors == 7 && statistics.totalGenres == 2)
        #expect(statistics.totalDuration == 12001.5 && statistics.totalSize == 8589934593 && statistics.numAudioTracks == 31)
        #expect(statistics.authorsWithCount == [.init(id: "author-item", name: "Author", count: 6)])
        #expect(statistics.genresWithCount == [.init(genre: "Fiction", count: 8), .init(genre: "History", count: 6)])
        #expect(statistics.longestItems == [.init(id: "library-item-long", title: "Long", duration: 7200.25)])
        #expect(statistics.largestItems == [.init(id: "library-item-large", title: "Large", size: 4294967297)])
        #expect(try JSONDecoder().decode(LibraryStatistics.self, from: JSONEncoder().encode(statistics)) == statistics)
    }

    @Test func podcastsOmitAuthorFieldsAndPreserveNullEpisodeDuration() throws {
        let statistics = try JSONDecoder().decode(LibraryStatistics.self, from: Data(podcastStatisticsJSON.utf8))
        #expect(statistics.totalItems == 2 && statistics.totalAuthors == nil && statistics.authorsWithCount == nil)
        #expect(statistics.longestItems.first?.id == "library-item-podcast" && statistics.longestItems.first?.duration == nil)
        #expect(statistics.totalDuration == 0 && statistics.numAudioTracks == 0 && statistics.genresWithCount.isEmpty)
        #expect(try JSONDecoder().decode(LibraryStatistics.self, from: JSONEncoder().encode(statistics)) == statistics)
    }

    @Test func emptyLibraryIsARealLoadedSnapshot() throws {
        let statistics = try JSONDecoder().decode(LibraryStatistics.self, from: Data(#"{"totalItems":0,"totalAuthors":0,"totalGenres":0,"totalDuration":0,"totalSize":0,"numAudioTracks":0,"authorsWithCount":[],"genresWithCount":[],"longestItems":[],"largestItems":[]}"#.utf8))
        #expect(statistics == .init(totalItems: 0, totalAuthors: 0, totalGenres: 0, totalDuration: 0, totalSize: 0, numAudioTracks: 0, authorsWithCount: [], genresWithCount: [], longestItems: [], largestItems: []))
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func fixedVersionsUseTheSameReadOnlyEndpoint(version: String) async throws {
        LibraryStatisticsHTTP.state.install { request in
            #expect(request.httpMethod == "GET" && request.httpBody == nil)
            #expect(request.url?.host == "catalog.fixture.test")
            #expect(request.url?.path == "/compat/api/libraries/library id/stats" && request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            return (200, Data(catalogStatisticsJSON.utf8))
        }
        let result = try await libraryStatisticsClient(version: version).libraryStatistics(libraryID: "library id")
        #expect(result.totalItems == 12)
    }

    @Test(arguments: ["{}", #"{"totalItems":"12"}"#, catalogStatisticsJSON.replacingOccurrences(of: #""genresWithCount":["#, with: #""genresWithCount":false,"invalid":["#), catalogStatisticsJSON.replacingOccurrences(of: #""count":6"#, with: #""count":"6""#)])
    func malformedKnownDataDoesNotBecomeAnEmptySuccessfulSnapshot(json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryStatistics.self, from: Data(json.utf8)) }
    }

    @Test(arguments: [403, 404, 503])
    func HTTPFailurePropagatesInsteadOfReportingZeroStatistics(status: Int) async throws {
        LibraryStatisticsHTTP.state.install { _ in (status, Data("synthetic failure".utf8)) }
        do { _ = try await libraryStatisticsClient(version: "2.26.0").libraryStatistics(libraryID: "library"); Issue.record("Expected HTTP error") }
        catch let error as ABSError { if case .http(let code, _) = error { #expect(code == status) } else { Issue.record("Expected HTTP status") } }
    }

    @Test func emptyLibraryIDFailsBeforeSendingARequest() async throws {
        LibraryStatisticsHTTP.state.install { _ in Issue.record("Empty ID must not issue HTTP"); return (200, Data(catalogStatisticsJSON.utf8)) }
        do { _ = try await libraryStatisticsClient(version: "2.37.1").libraryStatistics(libraryID: ""); Issue.record("Expected invalid path") }
        catch let error as ABSError { #expect(error == .invalidResourcePath) }
    }
}
