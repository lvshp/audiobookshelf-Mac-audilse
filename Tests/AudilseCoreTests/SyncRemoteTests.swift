import Foundation
import Testing
@testable import AudilseCore

private final class SyncRemoteHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var closeStatuses: [String: Int] = [:]
    private var requests: [String: [URLRequest]] = [:]
    func install(host: String, closeStatus: Int) { lock.lock(); defer { lock.unlock() }; closeStatuses[host] = closeStatus }
    func respond(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        let host = request.url!.host!
        requests[host, default: []].append(request)
        return request.url!.path.hasSuffix("/close") ? closeStatuses[host] ?? 500 : 200
    }
    func recorded(host: String) -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests[host] ?? [] }
}

private final class SyncRemoteHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = SyncRemoteHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("OK".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func syncRemoteFixture(closeStatus: Int) async -> (ABSOfflineSyncRemote, String) {
    let host = "test-" + UUID().uuidString.lowercased() + ".example"
    SyncRemoteHTTPProtocol.state.install(host: host, closeStatus: closeStatus)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncRemoteHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: ServerProfile(name: "Test", baseURL: URL(string: "https://" + host)!), session: URLSession(configuration: config), tokenStore: store)
    await store.save(AuthTokens(accessToken: "fixture-token"), account: await client.tokenAccount)
    return (ABSOfflineSyncRemote(client: client), host)
}

private func syncRemoteSnapshot() throws -> OfflinePlaybackSession {
    let session = LocalPlaybackSession(id: "original-id", libraryItemId: "book", duration: 600, currentTime: 100, startedAt: 1000, updatedAt: 2000, timeListening: 50)
    return OfflinePlaybackSession(id: session.id, itemID: session.libraryItemId, startedAt: session.startedAt, updatedAt: session.updatedAt, currentTime: session.currentTime, timeListening: session.timeListening, duration: session.duration, sessionPayload: try JSONEncoder().encode(session))
}

@Test func syncRemoteClosesOpenSessionBeforeReplacingCumulativeHistory() async throws {
    let (remote, host) = await syncRemoteFixture(closeStatus: 200)
    try await remote.upload(syncRemoteSnapshot())
    #expect(SyncRemoteHTTPProtocol.state.recorded(host: host).map { $0.url!.path } == ["/api/session/original-id/close", "/api/session/local"])
}

@Test func syncRemotePureOfflineSession404StillUploadsHistory() async throws {
    let (remote, host) = await syncRemoteFixture(closeStatus: 404)
    try await remote.upload(syncRemoteSnapshot())
    #expect(SyncRemoteHTTPProtocol.state.recorded(host: host).count == 2)
}

@Test func syncRemoteCloseFailureRetainsJournalWithoutUploadingHistory() async throws {
    let (remote, host) = await syncRemoteFixture(closeStatus: 503)
    await #expect(throws: ABSError.self) { try await remote.upload(syncRemoteSnapshot()) }
    #expect(SyncRemoteHTTPProtocol.state.recorded(host: host).map { $0.url!.path } == ["/api/session/original-id/close"])
}
