import Foundation
import Testing
@testable import AudilseCore

private let annualServerJSON = #"{"numListeningSessions":7,"numBooksAdded":2,"numAuthorsAdded":3,"totalBooksAddedSize":8589934593,"totalBooksAddedDuration":1234,"booksAddedWithCovers":["library-item-cover"],"totalBooksSize":17179869185,"totalBooksDuration":98765.25,"totalListeningTime":456.75,"numBooks":9,"topAuthors":[{"name":"Author","time":200}],"topNarrators":[{"name":"Narrator","time":150}],"topGenres":[{"genre":"Fiction","time":100}]}"#
private let annualEmptyJSON = #"{"numListeningSessions":0,"numBooksAdded":0,"numAuthorsAdded":0,"totalBooksAddedSize":0,"totalBooksAddedDuration":0,"booksAddedWithCovers":[],"totalBooksSize":0,"totalBooksDuration":0,"totalListeningTime":0,"numBooks":0,"topAuthors":[],"topNarrators":[],"topGenres":[]}"#
private let annualStorageJSON = #"{"books":{"totalSize":9000000001,"numItems":3,"numAudioFiles":17},"podcasts":{"totalSize":1000000002,"numItems":1,"numAudioFiles":8},"total":{"totalSize":10000000003,"numItems":4,"numAudioFiles":25}}"#
private let annualPersonalJSON = #"{"totalListeningSessions":7,"totalListeningTime":120,"totalBookListeningTime":100,"totalPodcastListeningTime":20,"topAuthors":[{"name":"Author","time":100}],"topGenres":[{"genre":"Fiction","time":100}],"mostListenedNarrator":{"name":"Narrator","time":100},"mostListenedMonth":{"month":0,"time":120},"numBooksFinished":1,"numBooksListened":2,"longestAudiobookFinished":{"id":"internal-book-id","title":"Finished","duration":3600,"finishedAt":"2026-01-12T10:00:00.000Z"},"booksWithCovers":["library-item-unfinished"],"finishedBooksWithCovers":["library-item-finished"]}"#

private final class AnnualHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var requests = 0
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = 0
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); let handler = handler; requests += 1; lock.unlock()
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class AnnualHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = AnnualHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func annualClient(version: String = "2.37.1") async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AnnualHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Annual fixture", baseURL: URL(string: "https://annual.fixture/abs")!, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "synthetic-access", userID: "fixture-admin"), account: client.tokenAccount)
    return client
}

@Suite(.serialized) struct AnnualStatisticsTests {
    @Test func serverAnnualFieldsRetainCountsBytesSecondsAndRankKeys() throws {
        let value = try JSONDecoder().decode(AdminYearlyStatistics.self, from: Data(annualServerJSON.utf8))
        #expect(value.numListeningSessions == 7)
        #expect(value.numBooksAdded == 2 && value.numAuthorsAdded == 3 && value.numBooks == 9)
        #expect(value.totalBooksAddedSize == 8_589_934_593 && value.totalBooksSize == 17_179_869_185)
        #expect(value.totalBooksAddedDuration == 1234 && value.totalBooksDuration == 98_765.25)
        #expect(value.totalListeningTime == 456.75)
        #expect(value.booksAddedWithCovers == ["library-item-cover"])
        #expect(value.topAuthors.first?.name == "Author" && value.topAuthors.first?.time == 200)
        #expect(value.topNarrators.first?.name == "Narrator" && value.topNarrators.first?.time == 150)
        #expect(value.topGenres.first?.genre == "Fiction" && value.topGenres.first?.name == nil)
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["numListeningSessions", "numBooksAdded", "numAuthorsAdded", "totalBooksAddedSize", "totalBooksAddedDuration", "booksAddedWithCovers", "totalBooksSize", "totalBooksDuration", "totalListeningTime", "numBooks", "topAuthors", "topNarrators", "topGenres"]))
        #expect(try JSONDecoder().decode(AdminYearlyStatistics.self, from: data) == value)
        let constructed = AdminYearlyStatistics(numListeningSessions: 7, numBooksAdded: 2, numAuthorsAdded: 3, totalBooksAddedSize: 8_589_934_593, totalBooksAddedDuration: 1234, booksAddedWithCovers: ["library-item-cover"], totalBooksSize: 17_179_869_185, totalBooksDuration: 98_765.25, totalListeningTime: 456.75, numBooks: 9, topAuthors: [.init(name: "Author", time: 200)], topNarrators: [.init(name: "Narrator", time: 150)], topGenres: [.init(genre: "Fiction", time: 100)])
        #expect(constructed == value)
    }

    @Test func storageTotalsKeepBooksPodcastsAndAudioFileCountsDistinct() throws {
        let value = try JSONDecoder().decode(ServerStorageStatistics.self, from: Data(annualStorageJSON.utf8))
        #expect(value.books == .init(totalSize: 9_000_000_001, numItems: 3, numAudioFiles: 17))
        #expect(value.podcasts == .init(totalSize: 1_000_000_002, numItems: 1, numAudioFiles: 8))
        #expect(value.total == .init(totalSize: 10_000_000_003, numItems: 4, numAudioFiles: 25))
        #expect(try JSONDecoder().decode(ServerStorageStatistics.self, from: JSONEncoder().encode(value)) == .init(books: value.books, podcasts: value.podcasts, total: value.total))
    }

    @Test func personalAnnualMonthAndFinishedBookUseTheirActualWireSemantics() throws {
        let value = try JSONDecoder().decode(YearlyStatistics.self, from: Data(annualPersonalJSON.utf8))
        #expect(value.mostListenedMonth == .init(month: 0, time: 120))
        #expect(value.longestAudiobookFinished == .init(id: "internal-book-id", title: "Finished", duration: 3600, finishedAt: "2026-01-12T10:00:00.000Z"))
        #expect(value.finishedBooksWithCovers == ["library-item-finished"])
        let constructed = YearlyStatistics(totalListeningSessions: 7, totalListeningTime: 120, totalBookListeningTime: 100, totalPodcastListeningTime: 20, topAuthors: [.init(name: "Author", time: 100)], topGenres: [.init(genre: "Fiction", time: 100)], mostListenedNarrator: .init(name: "Narrator", time: 100), mostListenedMonth: .init(month: 0, time: 120), numBooksFinished: 1, numBooksListened: 2, longestAudiobookFinished: .init(id: "internal-book-id", title: "Finished", duration: 3600, finishedAt: "2026-01-12T10:00:00.000Z"), booksWithCovers: ["library-item-unfinished"], finishedBooksWithCovers: ["library-item-finished"])
        #expect(constructed == value)
        #expect(try JSONDecoder().decode(YearlyStatistics.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func anEmptyYearIsDataButMalformedStatisticsAreNotFabricatedZeros() throws {
        let empty = try JSONDecoder().decode(AdminYearlyStatistics.self, from: Data(annualEmptyJSON.utf8))
        #expect(empty.numBooks == 0 && empty.numListeningSessions == 0 && empty.booksAddedWithCovers.isEmpty)
        #expect(empty.topAuthors.isEmpty && empty.topNarrators.isEmpty && empty.topGenres.isEmpty)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdminYearlyStatistics.self, from: Data("{}".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdminYearlyStatistics.self, from: Data(annualServerJSON.replacingOccurrences(of: "\"topGenres\":[{\"genre\":\"Fiction\",\"time\":100}]", with: "\"topGenres\":false").utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(YearlyStatistics.self, from: Data(annualServerJSON.utf8)) }
    }

    @Test func anEmptyActivityYearCanStillContainServerReportedCollectionTotals() throws {
        // Actual supported-release responses for year 2000 retain later books in
        // these aggregate fields because of the upstream quoted SQL cutoff.
        let json = annualEmptyJSON.replacingOccurrences(of: "\"numBooks\":0", with: "\"numBooks\":2")
            .replacingOccurrences(of: "\"totalBooksSize\":0", with: "\"totalBooksSize\":324348")
            .replacingOccurrences(of: "\"totalBooksDuration\":0", with: "\"totalBooksDuration\":80")
        let value = try JSONDecoder().decode(AdminYearlyStatistics.self, from: Data(json.utf8))
        #expect(value.numBooksAdded == 0 && value.numListeningSessions == 0 && value.totalListeningTime == 0)
        #expect(value.numBooks == 2 && value.totalBooksSize == 324348 && value.totalBooksDuration == 80)
        #expect(try JSONDecoder().decode(AdminYearlyStatistics.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func allSupportedReleasesUseIndependentServerAndPersonalRoutes(version: String) async throws {
        AnnualHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "GET" && request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            #expect(request.url?.query == nil)
            switch request.url?.path {
            case "/abs/api/stats/year/2026": return (200, Data(annualServerJSON.utf8))
            case "/abs/api/stats/server": return (200, Data(annualStorageJSON.utf8))
            case "/abs/api/me/stats/year/2026": return (200, Data(annualPersonalJSON.utf8))
            default: Issue.record("Unexpected annual statistics route"); return (404, Data())
            }
        }
        let client = await annualClient(version: version)
        #expect(try await client.adminYearlyStatistics(year: 2026).numBooks == 9)
        #expect(try await client.serverStorageStatistics().total.numAudioFiles == 25)
        #expect(try await client.yearlyStatistics(year: 2026).numBooksFinished == 1)
        #expect(AnnualHTTPProtocol.state.count == 3)
    }

    @Test(arguments: [2000, 9999])
    func inclusiveYearBoundariesAreSentUnchanged(year: Int) async throws {
        AnnualHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/stats/year/\(year)")
            return (200, Data(annualEmptyJSON.utf8))
        }
        #expect(try await annualClient().adminYearlyStatistics(year: year).numListeningSessions == 0)
    }

    @Test(arguments: [400, 403, 503])
    func invalidYearPermissionAndServerFailuresAreNotPresentedAsEmptyYears(status: Int) async throws {
        AnnualHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/stats/year/1999")
            return (status, Data("annual-fixture-error".utf8))
        }
        do {
            _ = try await annualClient().adminYearlyStatistics(year: 1999)
            Issue.record("An annual statistics HTTP failure became successful data")
        } catch let ABSError.http(actualStatus, message) {
            #expect(actualStatus == status)
            // The existing transport deliberately excludes arbitrary response
            // bodies from retained diagnostics, including statistics failures.
            #expect(!message.contains("annual-fixture-error"))
        }
        #expect(AnnualHTTPProtocol.state.count == 1)
    }
}
