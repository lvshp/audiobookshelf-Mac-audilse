import Foundation
import Testing
@testable import ShelfCore

private final class MockHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    func set(_ value: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; handler = value }
    func respond(_ request: URLRequest) throws -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return try handler!(request) }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]
    func increment(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; storage[key, default: 0] += 1; return storage[key]! }
    func value(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return storage[key, default: 0] }
}
private actor DeferredTokenStore: TokenStore {
    private var tokens: AuthTokens? = .init(accessToken: "old", refreshToken: "refresh")
    private var firstLoad: CheckedContinuation<AuthTokens?, Never>?
    private var loadCount = 0
    private var firstSnapshot: AuthTokens?
    func load(account: String) async -> AuthTokens? {
        loadCount += 1
        if loadCount == 1 {
            firstSnapshot = tokens
            return await withCheckedContinuation { firstLoad = $0 }
        }
        return tokens
    }
    func save(_ tokens: AuthTokens, account: String) { self.tokens = tokens }
    func remove(account: String) { tokens = nil }
    func waitUntilBlocked() async { while firstLoad == nil { await Task.yield() } }
    func releaseFirstLoad() { firstLoad?.resume(returning: firstSnapshot); firstLoad = nil }
}
private actor DeferredSaveTokenStore: TokenStore {
    private var tokens: AuthTokens?
    private var pendingSave: CheckedContinuation<Void, Never>?
    func load(account: String) -> AuthTokens? { tokens }
    func save(_ tokens: AuthTokens, account: String) async {
        self.tokens = tokens
        await withCheckedContinuation { pendingSave = $0 }
    }
    func remove(account: String) { tokens = nil }
    func remove(account: String, matching tokens: AuthTokens) { if self.tokens == tokens { self.tokens = nil } }
    func waitUntilSaving() async { while pendingSave == nil { await Task.yield() } }
    func releaseSave() { pendingSave?.resume(); pendingSave = nil }
}
private actor DeferredWriteTokenStore: TokenStore {
    private var tokens: AuthTokens?
    private var pendingSave: CheckedContinuation<Void, Never>?
    init(tokens: AuthTokens?) { self.tokens = tokens }
    func load(account: String) -> AuthTokens? { tokens }
    func save(_ tokens: AuthTokens, account: String) async {
        await withCheckedContinuation { pendingSave = $0 }
        self.tokens = tokens
    }
    func remove(account: String) { tokens = nil }
    func remove(account: String, matching tokens: AuthTokens) { if self.tokens == tokens { self.tokens = nil } }
    func waitUntilSaving() async { while pendingSave == nil { await Task.yield() } }
    func releaseSave() { pendingSave?.resume(); pendingSave = nil }
}
private final class MockHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            var headers = ["Content-Type": "application/json"]
            if status == 302 { headers["Location"] = "https://identity.example.test/authorize" }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func json(_ value: String) -> Data { Data(value.utf8) }
private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
private func mockClient(store: MemoryTokenStore = .init()) -> ABSClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTPProtocol.self]
    return ABSClient(profile: .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Test", baseURL: URL(string: "https://example.test/abs")!, username: "reader"), session: URLSession(configuration: config), tokenStore: store)
}
private let loginJSON = #"{"user":{"id":"u1","username":"reader","type":"user","accessToken":"access-one","refreshToken":"refresh-one","token":"legacy-permanent","permissions":{"download":true}},"userDefaultLibraryId":"l1"}"#
private let refreshJSON = #"{"user":{"id":"u1","username":"reader","accessToken":"access-two","refreshToken":"refresh-two"}}"#
private let userJSON = #"{"id":"u1","username":"reader","permissions":{"download":true},"mediaProgress":[]}"#

@Suite(.serialized) struct APIClientTests {
    @Test(arguments: ["login", "refresh", "password"])
    func tokenWriteCompletingAfterLogoutCannotRestoreCredentials(operation: String) async throws {
        let initial: AuthTokens? = operation == "login" ? nil : .init(accessToken: "old", refreshToken: "old-refresh", userID: "u1")
        let store = DeferredWriteTokenStore(tokens: initial)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockHTTPProtocol.self]
        let client = ABSClient(profile: .init(name: "Fixture", baseURL: URL(string: "https://example.test/abs")!, serverVersion: "2.37.1"), session: URLSession(configuration: configuration), tokenStore: store)
        MockHTTPProtocol.state.set { request in
            if request.url!.path.hasSuffix("/password") { return (200, json(#"{"success":true,"user":{"accessToken":"password-access","refreshToken":"password-refresh"}}"#)) }
            if request.url!.path.hasSuffix("/logout") { return (200, Data()) }
            return (200, json(loginJSON))
        }
        let writing = Task {
            switch operation {
            case "login": _ = try await client.login(username: "reader", password: "fixture")
            case "refresh": _ = try await client.refresh()
            default: _ = try await client.changePassword(currentPassword: "fixture-old", newPassword: "fixture-new")
            }
        }
        await store.waitUntilSaving()
        try await client.logout()
        await store.releaseSave()
        do { try await writing.value; Issue.record("Old authentication write survived logout") } catch ABSError.sessionChanged {} catch { throw error }
        #expect(await store.load(account: client.tokenAccount) == nil)
        do { _ = try await client.accessToken(); Issue.record("Credentials restored after logout") } catch ABSError.notAuthenticated {} catch { throw error }
    }
    @Test func loginUsesNestedJWTAndProxyPrefix() async throws {
        MockHTTPProtocol.state.set { request in
            #expect(request.url?.absoluteString == "https://example.test/abs/login")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
            return (200, json(loginJSON))
        }
        let client = mockClient(); let result = try await client.login(username: "reader", password: "test-only-password")
        #expect(result.user.id == "u1")
        #expect(try await client.accessToken() == "access-one")
        #expect(try await client.resourceURL(path: "/api/items/book") == URL(string: "https://example.test/abs/api/items/book")!)
    }
    @Test func paginationAcceptsServerStringNumbers() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "valid"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { request in
            let c = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            #expect(c.path == "/abs/api/libraries/lib/items")
            #expect(c.queryItems?.contains(URLQueryItem(name: "page", value: "2")) == true)
            #expect(c.queryItems?.contains(URLQueryItem(name: "limit", value: "40")) == true)
            return (200, json(#"{"results":[{"id":"b1","libraryId":"lib","media":{"metadata":{"title":"书名","authors":[{"id":"a1","name":"作者"}]}}}],"total":101,"limit":"40","page":"2"}"#))
        }
        let result = try await client.libraryItems(libraryID: "lib", page: 2, limit: 40)
        #expect(result.results.first?.title == "书名"); #expect(result.results.first?.authorName == "作者")
        #expect(result.page == 2); #expect(result.limit == 40); #expect(!result.hasMore)
    }
    @Test func unauthorizedReadRefreshesOnceAndRetries() async throws {
        let counts = Counter()
        MockHTTPProtocol.state.set { request in
            switch request.url!.path {
            case "/abs/login": return (200, json(loginJSON))
            case "/abs/auth/refresh":
                _ = counts.increment("refresh")
                #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "refresh-one")
                return (200, json(refreshJSON))
            default:
                let n = counts.increment("read")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(n == 1 ? "access-one" : "access-two")")
                return n == 1 ? (401, Data()) : (200, json(userJSON))
            }
        }
        let client = mockClient(); _ = try await client.login(username: "reader", password: "test-only")
        #expect(try await client.currentUser().id == "u1")
        #expect(counts.value("refresh") == 1); #expect(counts.value("read") == 2)
    }
    @Test func unauthorizedMutationNeverReplays() async throws {
        let counts = Counter()
        MockHTTPProtocol.state.set { request in
            switch request.url!.path {
            case "/abs/login": return (200, json(loginJSON))
            case "/abs/auth/refresh": _ = counts.increment("refresh"); return (200, json(refreshJSON))
            default: _ = counts.increment("mutation"); return (401, Data())
            }
        }
        let client = mockClient(); _ = try await client.login(username: "reader", password: "test-only")
        do { _ = try await client.startPlayback(itemID: "book"); Issue.record("Expected 401") } catch ABSError.http(status: 401, message: _) {} catch { throw error }
        #expect(counts.value("mutation") == 1); #expect(counts.value("refresh") == 1)
        #expect(try await client.accessToken() == "access-two")
    }
    @Test func refreshIsSingleFlight() async throws {
        let counts = Counter(); let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "old", refreshToken: "old-refresh"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { _ in _ = counts.increment("refresh"); Thread.sleep(forTimeInterval: 0.05); return (200, json(refreshJSON)) }
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await client.refresh().accessToken } }
            for try await token in group { #expect(token == "access-two") }
        }
        #expect(counts.value("refresh") == 1)
    }
    @Test func authorizationNeverLeavesServer() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "secret"), account: await client.tokenAccount)
        do { _ = try await client.authorizedURL(path: "https://evil.test/api/book"); Issue.record("External URL accepted") } catch ABSError.untrustedResource {} catch { throw error }
        do { _ = try await client.authorizedURL(path: "https://example.test/another/book"); Issue.record("Outside proxy path accepted") } catch ABSError.untrustedResource {} catch { throw error }
        let url = try await client.authorizedURL(path: "/api/items/book/file/a?download=1")
        #expect(url.path == "/abs/api/items/book/file/a")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "token", value: "secret")) == true)
    }
    @Test func httpFailurePreservesStatusWithoutResponseSecrets() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "valid"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { _ in (403, json("DO NOT RETAIN SERVER SECRET")) }
        do { _ = try await client.libraries(); Issue.record("Expected error") }
        catch let error as ABSError { #expect(error == .http(status: 403, message: "账户没有执行此操作的权限")) }
    }
    @Test func logoutRemovesCredentialsEvenIfServerFails() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "valid", refreshToken: "refresh"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { _ in (503, Data()) }
        do { try await client.logout(); Issue.record("Expected server error") } catch ABSError.http(status: 503, message: _) {} catch { throw error }
        #expect(await store.load(account: client.tokenAccount) == nil)
        do { _ = try await client.accessToken(); Issue.record("Tokens survived logout") } catch ABSError.notAuthenticated {} catch { throw error }
    }
    @Test func statusRejectsUnsupportedServerAndDoesNotSendCredentials() async throws {
        MockHTTPProtocol.state.set { request in
            #expect(request.url?.path == "/abs/status")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, json(#"{"app":"audiobookshelf","serverVersion":"2.25.9","isInit":true,"authMethods":["local"]}"#))
        }
        do { _ = try await mockClient().status(); Issue.record("Old server accepted") }
        catch ABSError.unsupportedVersion("2.25.9") {} catch { throw error }
    }
    @Test func refreshFailureDoesNotReplayRead() async throws {
        let counts = Counter(); let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "old", refreshToken: "refresh"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { request in
            _ = counts.increment(request.url!.path)
            return (401, Data())
        }
        do { _ = try await client.currentUser(); Issue.record("Expected refresh failure") }
        catch ABSError.http(status: 401, message: _) {} catch { throw error }
        #expect(counts.value("/abs/api/me") == 1); #expect(counts.value("/abs/auth/refresh") == 1)
    }
    @Test func sessionLocalPreservesIdentityAndOriginalTimestamp() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "valid"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { request in
            #expect(request.url!.path == "/abs/api/session/local")
            #expect(request.httpMethod == "POST")
            let payload = try JSONDecoder().decode(LocalPlaybackSession.self, from: bodyData(request))
            #expect(payload.id == "stable-session")
            #expect(payload.startedAt == 1_000); #expect(payload.updatedAt == 5_000); #expect(payload.timeListening == 12)
            return (200, Data("OK".utf8))
        }
        try await client.syncLocalSession(.init(id: "stable-session", libraryItemId: "book", duration: 100, currentTime: 40, startedAt: 1_000, updatedAt: 5_000, timeListening: 12))
    }
    @Test func tokenNamespaceRemainsStableAfterCanonicalUsername() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        let account = await client.tokenAccount
        MockHTTPProtocol.state.set { _ in (200, json(loginJSON)) }
        _ = try await client.login(username: "Reader", password: "test-only")
        #expect(await client.tokenAccount == account)
        #expect(await store.load(account: account)?.accessToken == "access-one")
    }
    @Test func invalidOIDCCallbackCannotChangeCredentials() async throws {
        let client = mockClient()
        do { _ = try await client.completeOIDC(callbackURL: URL(string: "shelfmac://oauth?code=code&state=unknown")!); Issue.record("Unsolicited callback accepted") }
        catch ABSError.invalidOIDCCallback {} catch { throw error }
    }

    @Test func delayedCredentialLoadCannotRestoreTokensAfterLogout() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTPProtocol.self]
        let store = DeferredTokenStore()
        let client = ABSClient(profile: .init(name: "Test", baseURL: URL(string: "https://example.test/abs")!), session: URLSession(configuration: config), tokenStore: store)
        MockHTTPProtocol.state.set { _ in (200, Data()) }
        let staleRead = Task { try await client.accessToken() }
        await store.waitUntilBlocked()
        try await client.logout()
        await store.releaseFirstLoad()
        do { _ = try await staleRead.value; Issue.record("Stale token load survived logout") }
        catch ABSError.sessionChanged {} catch { throw error }
        do { _ = try await client.accessToken(); Issue.record("Token restored after logout") }
        catch ABSError.notAuthenticated {} catch { throw error }
    }

    @Test func onlineSyncUsesDeltaTimeListenedWireKey() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store)
        await store.save(.init(accessToken: "valid"), account: await client.tokenAccount)
        let counts = Counter()
        MockHTTPProtocol.state.set { request in
            _ = counts.increment("requests")
            let payload = try JSONSerialization.jsonObject(with: bodyData(request)) as! [String: Double]
            #expect(payload["timeListened"] == 3)
            #expect(payload["timeListening"] == nil)
            #expect(payload["currentTime"] == 12)
            return (200, Data("OK".utf8))
        }
        try await client.syncPlayback(sessionID: "session", currentTime: 12, timeListening: 3)
        try await client.closePlayback(sessionID: "session", currentTime: 12, timeListening: 3)
        #expect(counts.value("requests") == 2)
    }

    @Test func canceledOIDCDuringCredentialSaveRemovesOnlyItsCredentials() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTPProtocol.self]
        let store = DeferredSaveTokenStore()
        let client = ABSClient(profile: .init(name: "Test", baseURL: URL(string: "https://example.test/abs")!), session: URLSession(configuration: config), tokenStore: store)
        MockHTTPProtocol.state.set { request in
            if request.url!.path == "/abs/auth/openid" { return (302, Data()) }
            #expect(request.value(forHTTPHeaderField: "x-return-tokens") == "true")
            return (200, json(loginJSON))
        }
        let flow = try await client.beginOIDC()
        let callback = URL(string: "shelfmac://oauth?code=test-code&state=\(flow.state)")!
        let completion = Task { try await client.completeOIDC(callbackURL: callback) }
        await store.waitUntilSaving()
        await client.cancelOIDC()
        await store.releaseSave()
        do { _ = try await completion.value; Issue.record("Canceled OIDC completed") }
        catch ABSError.sessionChanged {} catch { throw error }
        #expect(await store.load(account: client.tokenAccount) == nil)
    }
    @Test func startingOIDCDoesNotRetainOldFailedRefreshTask() async throws {
        let store = MemoryTokenStore(); let client = mockClient(store: store); let counts = Counter()
        await store.save(.init(accessToken: "old", refreshToken: "refresh"), account: await client.tokenAccount)
        MockHTTPProtocol.state.set { request in
            if request.url!.path == "/abs/auth/openid" { return (302, Data()) }
            if counts.increment("refresh") == 1 { Thread.sleep(forTimeInterval: 0.1) }
            return (200, json(refreshJSON))
        }
        let oldRefresh = Task { try await client.refresh() }
        while counts.value("refresh") == 0 { await Task.yield() }
        _ = try await client.beginOIDC()
        await client.cancelOIDC()
        _ = try? await oldRefresh.value
        #expect(try await client.refresh().accessToken == "access-two")
        #expect(counts.value("refresh") == 2)
    }

}
