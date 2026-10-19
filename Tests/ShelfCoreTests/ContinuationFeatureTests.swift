import Foundation
import Testing
@testable import ShelfCore

private final class ContinuationHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var paths: [String] = []
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler; paths = [] }
    func respond(_ request: URLRequest) throws -> (Int, Data) { lock.lock(); paths.append(request.url!.path); let handler = handler; lock.unlock(); return try handler!(request) }
    func count(_ suffix: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0.hasSuffix(suffix) }.count }
}
private final class ContinuationHTTP: URLProtocol, @unchecked Sendable {
    static let state = ContinuationHTTPState()
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
private func continuationClient(version: String) async -> ABSClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ContinuationHTTP.self]
    let tokens = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Synthetic", baseURL: URL(string: "https://continuation.fixture/abs")!, serverVersion: version), session: URLSession(configuration: config), tokenStore: tokens)
    await tokens.save(.init(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: "u"), account: client.tokenAccount)
    return client
}
@Suite(.serialized) struct ContinuationFeatureTests {
    @Test func serverUUIDNeverReplacesLocalItemEpisodeIdentity() throws {
        let progress = try JSONDecoder().decode(MediaProgress.self, from: Data(#"{"id":"progress-uuid","libraryItemId":"show","episodeId":"episode-2","hideFromContinueListening":true,"currentTime":15,"duration":60,"progress":0.25,"ebookLocation":"cfi","ebookProgress":0.4}"#.utf8))
        #expect(progress.serverID == "progress-uuid")
        #expect(progress.id == "show:episode-2" && progress.hideFromContinueListening)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any])
        #expect(wire["id"] as? String == "progress-uuid" && wire["serverID"] == nil)
        #expect(try JSONDecoder().decode(MediaProgress.self, from: JSONEncoder().encode(progress)) == progress)
        let legacy = try JSONDecoder().decode(MediaProgress.self, from: Data(#"{"libraryItemId":"book","currentTime":15}"#.utf8))
        #expect(legacy.id == "book" && legacy.serverID == nil && !legacy.hideFromContinueListening)
    }
    @Test func currentUserHiddenSeriesAndLegacyCacheRoundTrip() throws {
        let user = try JSONDecoder().decode(UserAccount.self, from: Data(#"{"id":"u","username":"reader","seriesHideFromContinueListening":["s1","s2"],"mediaProgress":[{"id":"p1","libraryItemId":"b","hideFromContinueListening":true}]}"#.utf8))
        #expect(user.seriesHideFromContinueListening == ["s1", "s2"])
        #expect(user.mediaProgress.first?.serverID == "p1")
        #expect(try JSONDecoder().decode(UserAccount.self, from: JSONEncoder().encode(user)) == user)
        #expect(try JSONDecoder().decode(UserAccount.self, from: Data(#"{"id":"legacy"}"#.utf8)).seriesHideFromContinueListening.isEmpty)
    }
    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"]) func hiddenActionsUseRawUUIDAndReturnFullUser(version: String) async throws {
        ContinuationHTTP.state.install { request in
            #expect(request.httpMethod == "GET")
            if request.url!.path.contains("/progress/") { #expect(request.url!.path == "/abs/api/me/progress/uuid with space/remove-from-continue-listening") }
            else { #expect(request.url!.path == "/abs/api/me/series/s1/readd-to-continue-listening") }
            return (200, Data(#"{"id":"u","username":"reader","seriesHideFromContinueListening":[],"mediaProgress":[{"id":"uuid with space","libraryItemId":"show","episodeId":"e2","hideFromContinueListening":true}]}"#.utf8))
        }
        let client = await continuationClient(version: version)
        let hidden = try await client.hideProgressFromContinueListening(progressID: "uuid with space")
        #expect(hidden.mediaProgress.first?.id == "show:e2")
        let restored = try await client.setSeriesHiddenFromContinueListeningResult(id: "s1", hidden: false)
        #expect(restored.seriesHideFromContinueListening.isEmpty)
    }
    @Test(arguments: [false, true]) func mutatingGETNeverReplaysAfter401(series: Bool) async throws {
        ContinuationHTTP.state.install { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return (200, Data(#"{"user":{"id":"u"},"accessToken":"replacement","refreshToken":"replacement-refresh"}"#.utf8)) }
            return (401, Data("expired".utf8))
        }
        let client = await continuationClient(version: "2.37.1")
        await #expect(throws: (any Error).self) {
            if series { _ = try await client.setSeriesHiddenFromContinueListeningResult(id: "s", hidden: true) }
            else { _ = try await client.hideProgressFromContinueListening(progressID: "uuid") }
        }
        #expect(ContinuationHTTP.state.count("remove-from-continue-listening") == 1)
    }
    @Test func missingProgressResponseIsAnErrorNotFalseSuccess() async throws {
        ContinuationHTTP.state.install { _ in (404, Data("not found".utf8)) }
        let client = await continuationClient(version: "2.26.0")
        do { _ = try await client.hideProgressFromContinueListening(progressID: "absent"); Issue.record("Missing progress unexpectedly succeeded") }
        catch let ABSError.http(status, _) { #expect(status == 404) }
    }
}
