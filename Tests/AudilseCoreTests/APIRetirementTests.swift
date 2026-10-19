import Foundation
import Testing
@testable import AudilseCore

private let retirementLogin = Data(#"{"user":{"id":"fixture-user","username":"reader","accessToken":"rotated-access","refreshToken":"rotated-refresh"}}"#.utf8)
private let retirementUser = Data(#"{"id":"fixture-user","username":"reader","mediaProgress":[]}"#.utf8)
private let retirementOriginal = AuthTokens(accessToken: "retained-access", refreshToken: "retained-refresh", userID: "fixture-user")

private final class RetirementHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var blockedPaths: Set<String> = []
    private var pending: [RetirementHTTPProtocol] = []
    private var stopped = 0
    private var activeIDs: Set<UUID> = []
    private var unauthorizedRead = false
    private var replacementLogin = false
    func reset(blocking paths: Set<String> = [], unauthorizedRead: Bool = false) { lock.withLock { requests = []; blockedPaths = paths; pending = []; stopped = 0; activeIDs = []; self.unauthorizedRead = unauthorizedRead; replacementLogin = false } }
    func useReplacementLogin() { lock.withLock { replacementLogin = true } }
    var loginData: Data { lock.withLock { replacementLogin ? Data(#"{"user":{"id":"fixture-user","username":"reader","accessToken":"fresh-client-access","refreshToken":"fresh-client-refresh"}}"#.utf8) : retirementLogin } }
    func shouldReject(path: String) -> Bool { lock.withLock { unauthorizedRead && path == "/abs/api/me" } }
    func start(_ protocolInstance: RetirementHTTPProtocol) -> Bool {
        lock.withLock {
            requests.append(protocolInstance.request)
            activeIDs.insert(protocolInstance.id)
            if blockedPaths.contains(protocolInstance.request.url?.path ?? "") { pending.append(protocolInstance); return false }
            return true
        }
    }
    func didStop(id: UUID) { lock.withLock { if activeIDs.contains(id) { stopped += 1 } } }
    var requestCount: Int { lock.withLock { requests.count } }
    var stopCount: Int { lock.withLock { stopped } }
    func count(path: String) -> Int { lock.withLock { requests.filter { $0.url?.path == path }.count } }
    func waitForRequest(path: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count(path: path) == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }
    func waitForStop() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while stopCount == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }
    func release() {
        let instances = lock.withLock { let result = pending; pending = []; return result }
        for instance in instances { instance.reply() }
    }
}
private final class RetirementHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = RetirementHTTPState()
    let id = UUID()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "retirement.example.test" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        if Self.state.start(self) { reply() }
    }
    override func stopLoading() { lock.withLock { stopped = true }; Self.state.didStop(id: id) }
    func reply() {
        guard !lock.withLock({ stopped }) else { return }
        let path = request.url!.path
        let data: Data
        let status: Int
        var headers = ["Content-Type": "application/json"]
        if Self.state.shouldReject(path: path) {
            status = 401; data = Data()
        } else if path == "/abs/auth/openid" {
            status = 302; data = Data(); headers["Location"] = "https://identity.example.test/authorize"
        } else if path == "/abs/status" {
            status = 200; data = Data(#"{"app":"audiobookshelf","serverVersion":"2.37.1","isInit":true,"authMethods":["local"]}"#.utf8)
        } else if path == "/abs/api/me/password" {
            status = 200; data = Data(#"{"success":true,"user":{"accessToken":"rotated-access","refreshToken":"rotated-refresh"}}"#.utf8)
        } else if ["/abs/login", "/abs/auth/refresh", "/abs/auth/openid/callback"].contains(path) {
            status = 200; data = Self.state.loginData
        } else { status = 200; data = retirementUser }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Delays a store write *before* committing it, so retirement must await the write
/// rather than assuming that cancelling the login/refresh caller revokes storage.
private actor RetirementTokenStore: TokenStore {
    private var tokens: AuthTokens? = retirementOriginal
    private var writeGate: CheckedContinuation<Void, Never>?
    private var loadGate: CheckedContinuation<Void, Never>?
    private var delayWrite: Bool
    private var delayLoad: Bool
    private let failLoad: Bool
    private(set) var loads = 0
    private(set) var saves = 0
    private(set) var removes = 0
    init(delayWrite: Bool = false, delayLoad: Bool = false, failLoad: Bool = false) { self.delayWrite = delayWrite; self.delayLoad = delayLoad; self.failLoad = failLoad }
    func load(account: String) async throws -> AuthTokens? {
        loads += 1
        let snapshot = tokens
        if delayLoad { delayLoad = false; await withCheckedContinuation { loadGate = $0 } }
        if failLoad { throw URLError(.cannotOpenFile) }
        return snapshot
    }
    func save(_ value: AuthTokens, account: String) async {
        saves += 1
        if delayWrite { delayWrite = false; await withCheckedContinuation { writeGate = $0 } }
        tokens = value
    }
    func remove(account: String) { removes += 1; tokens = nil }
    func remove(account: String, matching value: AuthTokens) { removes += 1; if tokens == value { tokens = nil } }
    func waitForWrite() async { while writeGate == nil { await Task.yield() } }
    func waitForLoad() async { while loadGate == nil { await Task.yield() } }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }
    func releaseLoad() { loadGate?.resume(); loadGate = nil }
    func snapshot() -> AuthTokens? { tokens }
}
private actor RetirementCompletion {
    private(set) var completed = false
    func finish() { completed = true }
}
private func retirementClient(store: any TokenStore, profile: ServerProfile? = nil) -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetirementHTTPProtocol.self]
    let profile = profile ?? ServerProfile(name: "Synthetic retirement fixture", baseURL: URL(string: "https://retirement.example.test/abs")!, username: "reader", serverVersion: "2.37.1")
    return ABSClient(profile: profile, session: URLSession(configuration: configuration), tokenStore: store)
}
private func expectRetired(_ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Retired client operation succeeded") }
    catch let error as ABSError { #expect(error == .sessionChanged) }
    catch { Issue.record("Unexpected retirement error: \(String(describing: type(of: error)))") }
}

@Suite(.serialized) struct APIRetirementTests {
    @Test func permanentRetirementPreservesTokensAndRejectsEveryTransportEntry() async throws {
        RetirementHTTPProtocol.state.reset()
        let store = RetirementTokenStore()
        let client = retirementClient(store: store)
        let profile = await client.profile
        _ = try await client.authorizedRequest(path: "api/me", method: "PATCH", body: Data("{}".utf8))
        let preparedGeneration = await client.authenticationGeneration
        await client.retireForServerRestore()
        await client.retireForServerRestore()
        #expect(await client.isRetired)
        await expectRetired { _ = try await client.currentUser() }
        await expectRetired { _ = try await client.status() }
        await expectRetired { _ = try await client.login(username: "reader", password: "synthetic-password") }
        await expectRetired { _ = try await client.refresh() }
        await expectRetired { try await client.logout() }
        await expectRetired { _ = try await client.beginOIDC() }
        await expectRetired { _ = try await client.completeOIDC(callbackURL: URL(string: "audilse://oauth?state=fixture&code=fixture")!) }
        await expectRetired { _ = try await client.accessToken() }
        await expectRetired { _ = try await client.authorizedRequest(path: "api/me", method: "PATCH") }
        await expectRetired { _ = try await client.authorizedURL(path: "api/items/fixture/cover") }
        await expectRetired { _ = try await client.resourceURL(path: "status") }
        await expectRetired { _ = try await client.changePassword(currentPassword: "synthetic-old", newPassword: "synthetic-new") }
        await expectRetired { try await client.closePlayback(sessionID: "fixture", currentTime: 1, timeListening: 0) }
        await expectRetired { _ = try await client.requestData(path: "api/me/progress/fixture", method: "PATCH", body: Data("{}".utf8)) }
        await expectRetired { _ = try await client.uploadMultipart(path: "api/upload", fileURL: URL(fileURLWithPath: "/nonexistent-prepared-fixture"), contentType: "multipart/form-data", expectedGeneration: preparedGeneration) }
        await expectRetired { try await client.downloadBackup(id: "fixture", destination: URL(fileURLWithPath: "/nonexistent-destination-fixture")) }
        #expect(RetirementHTTPProtocol.state.requestCount == 0)
        #expect(await store.snapshot() == retirementOriginal)
        #expect(await store.removes == 0)
        let fresh = retirementClient(store: store, profile: profile)
        #expect(try await fresh.currentUser().id == "fixture-user")
        #expect(!((await fresh.isRetired)))
        #expect(RetirementHTTPProtocol.state.requestCount == 1)
        #expect(await store.snapshot() == retirementOriginal)
    }

    @Test(arguments: ["read", "status", "login", "refresh", "oidc-begin", "oidc-complete", "mutation", "upload", "download"])
    func retirementCancelsOwnedInflightTransportsAndRejectsResponses(operation: String) async throws {
        RetirementHTTPProtocol.state.reset()
        let store = RetirementTokenStore()
        let client = retirementClient(store: store)
        var callback: URL?
        if operation == "oidc-complete" {
            let authorization = try await client.beginOIDC()
            callback = URL(string: "audilse://oauth?state=\(authorization.state)&code=synthetic-code")!
        }
        let path: String
        switch operation {
        case "status": path = "/abs/status"
        case "login": path = "/abs/login"
        case "refresh": path = "/abs/auth/refresh"
        case "oidc-begin": path = "/abs/auth/openid"
        case "oidc-complete": path = "/abs/auth/openid/callback"
        case "mutation": path = "/abs/api/session/fixture/close"
        case "upload": path = "/abs/api/upload"
        case "download": path = "/abs/api/backups/fixture/download"
        default: path = "/abs/api/me"
        }
        RetirementHTTPProtocol.state.reset(blocking: [path])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("retirement-upload-" + UUID().uuidString)
        try Data("synthetic upload".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let callbackURL = callback
        let task = Task {
            switch operation {
            case "status": _ = try await client.status()
            case "login": _ = try await client.login(username: "reader", password: "synthetic-password")
            case "refresh": _ = try await client.refresh()
            case "oidc-begin": _ = try await client.beginOIDC()
            case "oidc-complete": _ = try await client.completeOIDC(callbackURL: callbackURL!)
            case "mutation": try await client.closePlayback(sessionID: "fixture", currentTime: 12, timeListening: 0)
            case "upload": _ = try await client.uploadMultipart(path: "api/upload", fileURL: file, contentType: "multipart/form-data", expectedGeneration: client.authenticationGeneration)
            case "download": try await client.downloadBackup(id: "fixture", destination: file)
            default: _ = try await client.currentUser()
            }
        }
        try await RetirementHTTPProtocol.state.waitForRequest(path: path)
        await client.retireForServerRestore()
        await expectRetired { try await task.value }
        try await RetirementHTTPProtocol.state.waitForStop()
        RetirementHTTPProtocol.state.release()
        #expect(RetirementHTTPProtocol.state.stopCount > 0)
        #expect(RetirementHTTPProtocol.state.requestCount == 1)
        #expect(await store.saves == 0)
        #expect(await store.removes == 0)
        #expect(await store.snapshot() == retirementOriginal)
    }

    @Test func retirementDuringUnauthorizedRefreshDoesNotReplayRead() async throws {
        RetirementHTTPProtocol.state.reset(blocking: ["/abs/auth/refresh"], unauthorizedRead: true)
        let store = RetirementTokenStore()
        let client = retirementClient(store: store)
        let task = Task { try await client.currentUser() }
        try await RetirementHTTPProtocol.state.waitForRequest(path: "/abs/auth/refresh")
        await client.retireForServerRestore()
        await expectRetired { _ = try await task.value }
        try await RetirementHTTPProtocol.state.waitForStop()
        RetirementHTTPProtocol.state.release()
        #expect(RetirementHTTPProtocol.state.count(path: "/abs/api/me") == 1)
        #expect(RetirementHTTPProtocol.state.count(path: "/abs/auth/refresh") == 1)
        #expect(await store.snapshot() == retirementOriginal)
        #expect(await store.saves == 0)
    }

    @Test(arguments: ["login", "refresh", "password", "oidc"])
    func retirementDrainsCredentialWritesBeforeFreshClientCanTakeOver(operation: String) async throws {
        RetirementHTTPProtocol.state.reset()
        let store = RetirementTokenStore(delayWrite: true)
        let client = retirementClient(store: store)
        let profile = await client.profile
        var callback: URL?
        if operation == "oidc" {
            let authorization = try await client.beginOIDC()
            callback = URL(string: "audilse://oauth?state=\(authorization.state)&code=synthetic-code")!
        }
        let callbackURL = callback
        let writing = Task {
            switch operation {
            case "login": _ = try await client.login(username: "reader", password: "synthetic-password")
            case "refresh": _ = try await client.refresh()
            case "password": _ = try await client.changePassword(currentPassword: "synthetic-old", newPassword: "synthetic-new")
            default: _ = try await client.completeOIDC(callbackURL: callbackURL!)
            }
        }
        await store.waitForWrite()
        let completed = RetirementCompletion()
        let barrier = Task { await client.retireForServerRestore(); await completed.finish() }
        while !(await client.isRetired) { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await completed.completed))
        if operation == "oidc" { barrier.cancel() } // Cancellation cannot skip the retirement barrier.
        await store.releaseWrite()
        await barrier.value
        #expect(await completed.completed)
        let rotated = AuthTokens(accessToken: "rotated-access", refreshToken: "rotated-refresh", userID: "fixture-user")
        #expect(await store.snapshot() == rotated)
        #expect(await store.removes == 0)
        let fresh = retirementClient(store: store, profile: profile)
        #expect(try await fresh.accessToken() == rotated.accessToken)
        let replacement = AuthTokens(accessToken: "fresh-client-access", refreshToken: "fresh-client-refresh", userID: "fixture-user")
        RetirementHTTPProtocol.state.useReplacementLogin()
        #expect(try await fresh.login(username: "reader", password: "fresh-synthetic-password").accessToken == replacement.accessToken)
        await expectRetired { try await writing.value }
        #expect(await store.snapshot() == replacement)
        #expect(await store.removes == 0)
        #expect(await store.saves == 2)
    }

    @Test(arguments: [false, true]) func pendingTokenLoadCannotAuthorizeAfterRetirementAndStreamsFinishWithoutReload(failLoad: Bool) async throws {
        RetirementHTTPProtocol.state.reset()
        let store = RetirementTokenStore(delayLoad: true, failLoad: failLoad)
        let client = retirementClient(store: store)
        let existingStream = await client.tokenUpdates()
        let task = Task { try await client.authorizedRequest(path: "api/me", method: "PATCH") }
        await store.waitForLoad()
        await client.retireForServerRestore()
        await store.releaseLoad()
        await expectRetired { _ = try await task.value }
        for stream in [existingStream, await client.tokenUpdates()] {
            var iterator = stream.makeAsyncIterator()
            let first: AuthTokens?? = await iterator.next()
            #expect(first != nil)
            #expect(first! == nil)
            let end: AuthTokens?? = await iterator.next()
            #expect(end == nil)
        }
        #expect(await store.loads == 1)
        #expect(await store.removes == 0)
        #expect(RetirementHTTPProtocol.state.requestCount == 0)
    }

    @MainActor @Test func backupAppliedIsRegisteredAndAcceptsNullPayload() throws {
        #expect(ABSRealtimeClient.serverEvents.filter { $0 == "backup_applied" }.count == 1)
        #expect(try #require(ABSRealtimeClient.encodePayload(NSNull())) == Data("null".utf8))
        let noArgument = RealtimeEvent(name: "backup_applied", payload: nil)
        #expect(noArgument.name == "backup_applied")
        #expect(noArgument.payload == nil)
    }
}
