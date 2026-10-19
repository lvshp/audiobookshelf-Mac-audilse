import Foundation
import Testing
@testable import ShelfCore

private final class UserDetailHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func install(_ value: @escaping @Sendable (URLRequest) throws -> Data) { lock.withLock { handler = value } }
    func respond(_ request: URLRequest) throws -> Data { let value = lock.withLock { handler }; return try value!(request) }
}
private final class UserDetailHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = UserDetailHTTPState()
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
private func userDetailClient(_ version: String) async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UserDetailHTTPProtocol.self]
    let tokens = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Synthetic administrator", baseURL: URL(string: "https://user-detail.fixture.test/abs")!, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: tokens)
    await tokens.save(.init(accessToken: "synthetic-user-detail", userID: "administrator"), account: client.tokenAccount)
    return client
}
private let savedProgressFixture = #"{"id":"progress","userId":"target","libraryItemId":"show","episodeId":"episode","mediaItemId":"episode","mediaItemType":"podcastEpisode","duration":100,"progress":0.4,"currentTime":40,"isFinished":false,"hideFromContinueListening":true,"ebookLocation":null,"ebookProgress":null,"lastUpdate":2000,"startedAt":1000,"finishedAt":null,"displayTitle":"Episode title","displaySubtitle":"Podcast title","coverPath":"/server/cover.jpg","mediaUpdatedAt":1500}"#

@Suite(.serialized) struct AdminUserDetailTests {
    @Test func savedProgressPreservesServerIdentityAndDisplayFields() throws {
        let row = try JSONDecoder().decode(AdminUserProgress.self, from: Data(savedProgressFixture.utf8))
        #expect(row.id == "progress"); #expect(row.libraryItemId == "show"); #expect(row.episodeId == "episode")
        #expect(row.displayTitle == "Episode title"); #expect(row.displaySubtitle == "Podcast title")
        #expect(row.currentTime == 40); #expect(row.progress == 0.4); #expect(row.hideFromContinueListening == true)
        #expect(row.lastUpdate == 2000); #expect(row.startedAt == 1000); #expect(row.finishedAt == nil); #expect(row.mediaUpdatedAt == 1500)
        #expect(try JSONDecoder().decode(AdminUserProgress.self, from: JSONEncoder().encode(row)) == row)
        let deleted = savedProgressFixture.replacingOccurrences(of: #""libraryItemId":"show""#, with: #""libraryItemId":null"#)
        let removed = try JSONDecoder().decode(AdminUserProgress.self, from: Data(deleted.utf8))
        #expect(removed.libraryItemId == nil); #expect(removed.id == "progress")
    }
    @Test func oldUserListMissingProgressDiffersFromConfirmedEmptyDetail() throws {
        let json = #"{"id":"target","username":"Target","type":"user"}"#
        #expect(try JSONDecoder().decode(AdminUser.self, from: Data(json.utf8)).mediaProgress == nil)
        let detail = String(json.dropLast()) + #","mediaProgress":[]}"#
        #expect(try JSONDecoder().decode(AdminUser.self, from: Data(detail.utf8)).mediaProgress == [])
    }
    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func userDetailHistoryAndStatisticsUseTargetUserRoutes(version: String) async throws {
        UserDetailHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "GET"); #expect(request.url?.host == "user-detail.fixture.test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-user-detail")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            switch components.path {
            case "/abs/api/users/target":
                #expect(components.queryItems == nil)
                return Data("{\"id\":\"target\",\"username\":\"Target\",\"type\":\"user\",\"mediaProgress\":[\(savedProgressFixture)]}".utf8)
            case "/abs/api/users/target/listening-stats":
                return Data(#"{"totalTime":90,"today":30,"items":{},"days":{},"dayOfWeek":{},"recentSessions":[]}"#.utf8)
            default:
                #expect(components.path == "/abs/api/users/target/listening-sessions")
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(query == ["page": "2", "itemsPerPage": "20"])
                return Data(#"{"total":41,"numPages":3,"page":2,"itemsPerPage":20,"sessions":[{"id":"session","userId":"target","displayTitle":"Title","timeListening":12,"currentTime":20,"deviceInfo":{"browserName":"Safari","osName":"macOS"}}]}"#.utf8)
            }
        }
        let client = await userDetailClient(version)
        #expect(try await client.adminUser(id: "target").mediaProgress?.first?.episodeId == "episode")
        #expect(try await client.userListeningStats(id: "target").today == 30)
        let page = try await client.userListeningHistory(id: "target", page: 2, limit: 20)
        #expect(page.page == 2); #expect(page.total == 41); #expect(page.sessions.first?.deviceInfo?.browserName == "Safari")
    }
    @Test func malformedSavedProgressDoesNotSilentlyBecomeEmpty() throws {
        let value = savedProgressFixture.replacingOccurrences(of: #""currentTime":40"#, with: #""currentTime":"forty""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdminUserProgress.self, from: Data(value.utf8)) }
    }
}
