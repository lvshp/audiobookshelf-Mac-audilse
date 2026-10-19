import Foundation
import Testing
@testable import AudilseCore

private let playbackUserID = "11111111-1111-4111-8111-111111111111"
private let playbackSessionID = "22222222-2222-4222-8222-222222222222"
private let playbackOtherID = "33333333-3333-4333-8333-333333333333"
private final class PlaybackAdminHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var requests: [URLRequest] = []
    func install(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.withLock { handler = value; requests = [] } }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let action = lock.withLock { requests.append(request); return handler! }
        return try action(request)
    }
    func all() -> [URLRequest] { lock.withLock { requests } }
}
private final class PlaybackAdminHTTP: URLProtocol, @unchecked Sendable {
    static let state = PlaybackAdminHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func playbackAdminClient(_ version: String = "2.37.1") async -> ABSClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlaybackAdminHTTP.self]
    let tokens = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Synthetic playback administrator", baseURL: URL(string: "https://playback-admin.fixture/abs")!, userID: playbackUserID, serverVersion: version), session: URLSession(configuration: config), tokenStore: tokens)
    await tokens.save(.init(accessToken: "synthetic-playback", refreshToken: "synthetic-refresh", userID: playbackUserID), account: client.tokenAccount)
    return client
}
private func playbackBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
private func playbackSession(player: String? = nil, owner: String? = playbackUserID) throws -> AdminPlaybackSession {
    var json: [String: Any] = ["id": playbackSessionID]
    if let player { json["mediaPlayer"] = player }; if let owner { json["userId"] = owner }
    return try JSONDecoder().decode(AdminPlaybackSession.self, from: JSONSerialization.data(withJSONObject: json))
}
private let emptyPlaybackPage = Data(#"{"total":0,"numPages":0,"page":0,"itemsPerPage":10,"sessions":[]}"#.utf8)

@Suite(.serialized) struct AdminPlaybackSessionTests {
    @Test(arguments: AdminPlaybackSessionSort.allCases)
    func sortDirectionUserAndPaginationUseOfficialNames(sort: AdminPlaybackSessionSort) async throws {
        PlaybackAdminHTTP.state.install { request in
            #expect(request.httpMethod == "GET"); #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-playback")
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            #expect(parts.path == "/abs/api/sessions")
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query == ["page": "2", "itemsPerPage": "25", "sort": sort.rawValue, "desc": "0", "user": playbackUserID])
            return (200, emptyPlaybackPage)
        }
        _ = try await playbackAdminClient().adminPlaybackSessions(page: 2, limit: 25, userID: playbackUserID, sort: sort, descending: false)
    }
    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func defaultSignatureStillUsesUpdatedAtDescending(version: String) async throws {
        PlaybackAdminHTTP.state.install { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            #expect(parts.path == "/abs/api/sessions")
            #expect(Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }) == ["page": "0", "itemsPerPage": "30", "sort": "updatedAt", "desc": "1"])
            return (200, emptyPlaybackPage)
        }
        _ = try await playbackAdminClient(version).adminPlaybackSessions()
    }
    @Test(arguments: ["", "target", "../user", " 11111111-1111-4111-8111-111111111111", "11111111-1111-6111-8111-111111111111", "11111111-1111-4111-0111-111111111111", "11111111-1111-4111-8111-111111111111&user=other"])
    func invalidFilterNeverBroadensToAllUsers(id: String) async throws {
        PlaybackAdminHTTP.state.install { _ in Issue.record("Invalid filter reached HTTP"); return (200, emptyPlaybackPage) }
        await #expect(throws: AdminPlaybackSessionInputError.invalidUserID) { try await playbackAdminClient().adminPlaybackSessions(userID: id) }
        #expect(PlaybackAdminHTTP.state.all().isEmpty)
    }
    @Test func boundedPagesAndBothUUIDCasesUseUnambiguousQuery() async throws {
        PlaybackAdminHTTP.state.install { request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["page"] == "0"); #expect(query["itemsPerPage"] == "500"); #expect(query["desc"] == "1")
            return (200, emptyPlaybackPage)
        }
        #expect(AdminPlaybackSessionPolicy.isValidIdentifier("AABBCCDD-AABB-4CCD-8AAB-AABBCCDDEEFF"))
        #expect(AdminPlaybackSessionPolicy.isValidIdentifier("00000000-0000-0000-0000-000000000000"))
        _ = try await playbackAdminClient().adminPlaybackSessions(page: -4, limit: 999)
    }
    @Test func richHistoryAndTypedShareRetainDetailFields() async throws {
        let row = #"{"id":"22222222-2222-4222-8222-222222222222","libraryId":"library","libraryItemId":"item","episodeId":"episode","userId":null,"mediaType":"podcast","mediaPlayer":"web-share","startTime":7.5,"currentTime":15,"timeListening":9,"duration":300,"playMethod":1,"startedAt":1000,"updatedAt":2000,"createdAt":900,"serverVersion":"2.37.1","deviceInfo":{"clientName":"Synthetic","clientVersion":"1","ipAddress":"192.0.2.2","osName":"macOS","deviceName":"Fixture","sdkVersion":"33","deviceType":"mobile"}}"#
        PlaybackAdminHTTP.state.install { request in
            #expect(request.url?.path == "/abs/api/sessions/open" && request.url?.query == nil)
            return (200, Data("{\"sessions\":[],\"shareSessions\":[\(row)]}".utf8))
        }
        let client = await playbackAdminClient(), snapshot = try await client.adminPlaybackSessionSnapshot()
        let share = try #require(snapshot.shareSessions.first)
        #expect(snapshot.sessions.isEmpty); #expect(share.mediaPlayer == "web-share" && share.libraryId == "library" && share.mediaType == "podcast")
        #expect(share.startTime == 7.5 && share.createdAt == 900 && share.serverVersion == "2.37.1")
        #expect(share.deviceInfo?.ipAddress == "192.0.2.2" && share.deviceInfo?.sdkVersion == "33" && share.deviceInfo?.deviceName == "Fixture")
        #expect(try await client.adminOpenPlaybackSessions().shareSessions.count == 1)
        let page = try JSONDecoder().decode(AdminPlaybackSessionPage.self, from: Data("{\"total\":1,\"numPages\":1,\"page\":0,\"itemsPerPage\":10,\"userId\":\"\(playbackUserID)\",\"sessions\":[\(row)]}".utf8))
        #expect(page.userId == playbackUserID)
    }
    @Test func missingNullAndMalformedSnapshotsRemainDistinct() throws {
        let minimal = try JSONDecoder().decode(AdminPlaybackSession.self, from: Data(#"{"id":"legacy","deviceInfo":null,"libraryItemId":null,"user":null}"#.utf8))
        #expect(minimal.user == nil && minimal.libraryId == nil && minimal.mediaPlayer == nil && minimal.startTime == nil && minimal.deviceInfo == nil)
        #expect(try JSONDecoder().decode(AdminPlaybackSessionSnapshot.self, from: Data(#"{"sessions":[],"shareSessions":[]}"#.utf8)).shareSessions.isEmpty)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdminPlaybackSessionSnapshot.self, from: Data(#"{"sessions":[],"shareSessions":null}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AdminPlaybackSession.self, from: Data(#"{"id":"x","startTime":"ten"}"#.utf8)) }
    }
    @Test(arguments: ["close", "delete", "batch"])
    func mutationsUseDistinctRoutesAndCloseDoesNotSync(operation: String) async throws {
        PlaybackAdminHTTP.state.install { request in
            switch operation {
            case "close": #expect(request.httpMethod == "POST" && request.url?.path == "/abs/api/session/" + playbackSessionID + "/close"); #expect(playbackBody(request).isEmpty)
            case "delete": #expect(request.httpMethod == "DELETE" && request.url?.path == "/abs/api/sessions/" + playbackSessionID); #expect(playbackBody(request).isEmpty)
            default:
                #expect(request.httpMethod == "POST" && request.url?.path == "/abs/api/sessions/batch/delete")
                let body = try JSONDecoder().decode([String: [String]].self, from: playbackBody(request))
                #expect(body == ["sessions": [playbackSessionID, playbackOtherID]])
            }
            return (200, Data())
        }
        let client = await playbackAdminClient()
        switch operation { case "close": try await client.closeAdminPlaybackSession(id: playbackSessionID); case "delete": try await client.deletePlaybackSession(id: playbackSessionID); default: try await client.deletePlaybackSessions(ids: [playbackSessionID, playbackOtherID]) }
        #expect(PlaybackAdminHTTP.state.all().count == 1)
    }
    @Test func invalidMutationsDoNotReachHTTP() async throws {
        PlaybackAdminHTTP.state.install { _ in Issue.record("Invalid mutation reached HTTP"); return (200, Data()) }
        let client = await playbackAdminClient()
        await #expect(throws: AdminPlaybackSessionInputError.invalidSessionIDs) { try await client.closeAdminPlaybackSession(id: "") }
        await #expect(throws: AdminPlaybackSessionInputError.invalidSessionIDs) { try await client.deletePlaybackSession(id: "not-a-uuid") }
        await #expect(throws: AdminPlaybackSessionInputError.invalidSessionIDs) { try await client.deletePlaybackSessions(ids: []) }
        await #expect(throws: AdminPlaybackSessionInputError.invalidSessionIDs) { try await client.deletePlaybackSessions(ids: [playbackSessionID, "bad"]) }
        #expect(PlaybackAdminHTTP.state.all().isEmpty)
    }
    @Test(arguments: ["close", "delete", "batch"])
    func writesAreNeverReplayedAfterRefresh(operation: String) async throws {
        PlaybackAdminHTTP.state.install { request in
            if request.url?.path == "/abs/auth/refresh" { return (200, Data("{\"user\":{\"id\":\"\(playbackUserID)\",\"username\":\"Synthetic\",\"isActive\":true,\"accessToken\":\"fresh-synthetic\",\"refreshToken\":\"fresh-refresh\"}}".utf8)) }
            return (401, Data("synthetic failure".utf8))
        }
        let client = await playbackAdminClient()
        do {
            switch operation { case "close": try await client.closeAdminPlaybackSession(id: playbackSessionID); case "delete": try await client.deletePlaybackSession(id: playbackSessionID); default: try await client.deletePlaybackSessions(ids: [playbackSessionID]) }
            Issue.record("Expected unsafe write failure")
        } catch { #expect((error as? ABSError).map { if case .http(status: 401, message: _) = $0 { true } else { false } } == true) }
        #expect(PlaybackAdminHTTP.state.all().filter { $0.url?.path != "/abs/auth/refresh" }.count == 1)
        #expect(PlaybackAdminHTTP.state.all().filter { $0.url?.path == "/abs/auth/refresh" }.count == 1)
    }
    @Test func singleAndBatchDeleteUseDifferentPermissionsAndRejectShares() throws {
        let session = try playbackSession(), share = try playbackSession(player: "web-share")
        let admin = UserAccount(id: playbackUserID, username: "Admin", type: "admin", permissions: .init(delete: false))
        let deleter = UserAccount(id: playbackUserID, username: "User", permissions: .init(delete: true))
        #expect(!AdminPlaybackSessionPolicy.canDelete(session, kind: .history, actor: admin))
        #expect(AdminPlaybackSessionPolicy.canBatchDelete([session], actor: admin))
        #expect(AdminPlaybackSessionPolicy.canDelete(session, kind: .history, actor: deleter))
        #expect(!AdminPlaybackSessionPolicy.canBatchDelete([session], actor: deleter))
        #expect(!AdminPlaybackSessionPolicy.canDelete(session, kind: .open, actor: deleter))
        #expect(!AdminPlaybackSessionPolicy.canDelete(share, kind: .history, actor: deleter))
        #expect(!AdminPlaybackSessionPolicy.canBatchDelete([share], actor: admin))
        #expect(!AdminPlaybackSessionPolicy.canBatchDelete([], actor: admin))
        var inactive = admin; inactive.isActive = false
        #expect(!AdminPlaybackSessionPolicy.canBatchDelete([session], actor: inactive))
        inactive.permissions.delete = true
        #expect(!AdminPlaybackSessionPolicy.canDelete(session, kind: .history, actor: inactive))
    }
    @Test(arguments: ["2.36.1", "2.37.1", "v2.37.1", "2.37.1+build.1"])
    func verifiedAdminCloseAllowsOtherOwners(version: String) throws {
        let actor = UserAccount(id: playbackUserID, username: "Admin", type: "admin")
        #expect(AdminPlaybackSessionPolicy.canClose(try playbackSession(owner: playbackOtherID), kind: .open, actor: actor, serverVersion: version))
    }
    @Test(arguments: [nil, "", "unknown", "2.26.0", "2.36.0", "2.37", "2.37.1-beta.1", "2.37.1 invalid"] as [String?])
    func oldOrUnknownVersionsOnlyCloseOwnActivity(version: String?) throws {
        let actor = UserAccount(id: playbackUserID, username: "Admin", type: "admin")
        #expect(!AdminPlaybackSessionPolicy.canClose(try playbackSession(owner: playbackOtherID), kind: .open, actor: actor, serverVersion: version))
        #expect(AdminPlaybackSessionPolicy.canClose(try playbackSession(), kind: .open, actor: actor, serverVersion: version))
    }
    @Test func closeOwnershipShareAndLifecycleBoundariesAreIndependent() throws {
        let session = try playbackSession(), share = try playbackSession(player: "web-share")
        let owner = UserAccount(id: playbackUserID, username: "Owner")
        #expect(AdminPlaybackSessionPolicy.canClose(session, kind: .open, actor: owner, serverVersion: "2.26.0"))
        #expect(!AdminPlaybackSessionPolicy.canClose(try playbackSession(owner: playbackOtherID), kind: .open, actor: owner, serverVersion: "2.37.1"))
        for kind in [AdminPlaybackSessionKind.history, .share] { #expect(!AdminPlaybackSessionPolicy.canClose(session, kind: kind, actor: owner, serverVersion: "2.37.1")) }
        #expect(!AdminPlaybackSessionPolicy.canClose(share, kind: .open, actor: owner, serverVersion: "2.37.1"))
        var inactive = owner; inactive.isActive = false
        #expect(!AdminPlaybackSessionPolicy.canClose(session, kind: .open, actor: inactive, serverVersion: "2.37.1"))
    }
}
