import Foundation
import Testing
@testable import ShelfCore

private func recoveryJWT(_ claims: String, header: String = #"{"alg":"HS256","typ":"JWT"}"#) -> String {
    func segment(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return segment(header) + "." + segment(claims) + ".fixture-signature"
}
private let recoveryRetained = AuthTokens(accessToken: recoveryJWT(#"{"userId":"u1","username":"reader","iat":1700000000,"exp":4102444800,"type":"access"}"#), refreshToken: "retained-refresh", userID: "u1")
private let recoveryRenewed = AuthTokens(accessToken: "renewed-access", refreshToken: "renewed-refresh", userID: "u1")
private let recoveryUserJSON = Data(#"{"id":"u1","username":"reader","isActive":true}"#.utf8)
private let recoveryRenewedJSON = Data(#"{"user":{"id":"u1","username":"reader","accessToken":"renewed-access","refreshToken":"renewed-refresh"}}"#.utf8)
private final class RecoveryHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var handler: @Sendable (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    private var blocking: Set<String> = []
    private var pending: [RecoveryHTTPProtocol] = []
    func reset(blocking: Set<String> = [], handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock { requests = []; pending = []; self.blocking = blocking; self.handler = handler }
    }
    func start(_ value: RecoveryHTTPProtocol) -> Bool {
        lock.withLock {
            requests.append(value.request)
            if blocking.contains(value.request.url!.path) { pending.append(value); return false }
            return true
        }
    }
    func response(_ request: URLRequest) -> (Int, Data) { let value = lock.withLock { handler }; return value(request) }
    func count(_ suffix: String) -> Int { lock.withLock { requests.filter { $0.url!.path.hasSuffix(suffix) }.count } }
    var total: Int { lock.withLock { requests.count } }
    func release() { let values = lock.withLock { let values = pending; pending = []; return values }; for value in values { value.reply() } }
    func wait(_ suffix: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count(suffix) == 0 { guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }; await Task.yield() }
    }
}
private final class RecoveryHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = RecoveryHTTPState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "recovery-auth.example.test" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        if Self.state.start(self) { reply() }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
    func reply() {
        guard !lock.withLock({ stopped }) else { return }
        let (status, data) = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
}
private func recoveryClient(store: MemoryTokenStore, version: String? = "2.37.1", userID: String? = "u1") -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [RecoveryHTTPProtocol.self]
    return ABSClient(profile: .init(name: "Recovery fixture", baseURL: URL(string: "https://recovery-auth.example.test/proxy/abs")!, username: "reader", userID: userID, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
}

@Suite(.serialized) struct APIRecoveryAuthenticationTests {
    @Test func stillValidAccessCannotHideMissingRestoredRefreshSession() async throws {
        let store = MemoryTokenStore()
        // Use one store for both reads so failed verification must retain the exact credentials.
        let target = recoveryClient(store: store)
        await store.save(recoveryRetained, account: target.tokenAccount)
        RecoveryHTTPProtocol.state.reset { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return (401, Data()) }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(recoveryRetained.accessToken)")
            return (200, recoveryUserJSON)
        }
        #expect(try await target.currentUser().id == "u1") // Before-fix gate accepted this.
        do { _ = try await target.validateServerRecoveryAuthentication(); Issue.record("Missing restored session accepted") }
        catch ABSError.http(status: 401, message: _) { }
        #expect(RecoveryHTTPProtocol.state.count("/auth/refresh") == 1)
        #expect(RecoveryHTTPProtocol.state.count("/api/me") == 1)
        #expect(await store.load(account: target.tokenAccount) == recoveryRetained)
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func allFixedVersionsForceRefreshBeforeReading(version: String) async throws {
        let store = MemoryTokenStore()
        let target = recoveryClient(store: store, version: version)
        await store.save(recoveryRetained, account: target.tokenAccount)
        RecoveryHTTPProtocol.state.reset { request in
            #expect(request.url!.path.hasPrefix("/proxy/abs/"))
            if request.url!.path.hasSuffix("/auth/refresh") {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "retained-refresh")
                #expect(RecoveryHTTPProtocol.state.count("/api/me") == 0)
                return (200, recoveryRenewedJSON)
            }
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed-access")
            return (200, recoveryUserJSON)
        }
        #expect(try await target.validateServerRecoveryAuthentication().id == "u1")
        #expect(RecoveryHTTPProtocol.state.count("/auth/refresh") == 1)
        #expect(RecoveryHTTPProtocol.state.count("/api/me") == 1)
        #expect(await store.load(account: target.tokenAccount) == recoveryRenewed)
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func permanentLegacyJWTUsesFreshReadIncludingServerOldIDMapping(version: String) async throws {
        let store = MemoryTokenStore()
        let client = recoveryClient(store: store, version: version)
        let legacy = AuthTokens(accessToken: recoveryJWT(#"{"userId":"legacy-old-id","username":"reader","iat":1700000000}"#), userID: "u1")
        await store.save(legacy, account: client.tokenAccount)
        RecoveryHTTPProtocol.state.reset { request in
            #expect(request.url!.path == "/proxy/abs/api/me")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(legacy.accessToken)")
            return (200, recoveryUserJSON)
        }
        #expect(try await client.validateServerRecoveryAuthentication().id == "u1")
        #expect(RecoveryHTTPProtocol.state.total == 1)
        #expect(await store.load(account: client.tokenAccount) == legacy)
    }

    @Test(arguments: [
        #"{"userId":"u1","username":"reader","iat":1,"exp":4102444800}"#,
        #"{"userId":"u1","username":"reader","iat":1,"exp":null}"#,
        #"{"userId":"u1","username":"reader","iat":1,"exp":"bad"}"#,
        #"{"userId":"u1","username":"reader","iat":1,"type":"access"}"#,
        #"{"userId":"u1","username":"reader","iat":1,"type":"refresh"}"#,
        #"{"userId":"u1","username":"reader","iat":1,"type":"api"}"#,
        #"{"userId":"u1","username":"reader","iat":1,"type":null}"#,
        #"{"userId":"u1","username":"reader","iat":true}"#,
        #"{"userId":"u1","username":"reader"}"#,
        #"{"userId":"","username":"reader","iat":1}"#,
        #"{"userId":"u1","username":"","iat":1}"#,
        #"{"userId":"u1","username":"reader","iat":1,"unknown":true}"#
    ])
    func accessOnlyAndMalformedClaimsCannotDowngradeToLegacy(claims: String) async throws {
        let store = MemoryTokenStore()
        let target = recoveryClient(store: store)
        let retained = AuthTokens(accessToken: recoveryJWT(claims), userID: "u1")
        await store.save(retained, account: target.tokenAccount)
        RecoveryHTTPProtocol.state.reset { _ in Issue.record("Invalid legacy token reached HTTP"); return (200, recoveryUserJSON) }
        await #expect(throws: ABSError.notAuthenticated) { try await target.validateServerRecoveryAuthentication() }
        #expect(RecoveryHTTPProtocol.state.total == 0)
        #expect(await store.load(account: target.tokenAccount) == retained)
    }

    @Test(arguments: ["malformed", "wrong-header", "unknown-version", "wrong-user", "absent"])
    func unprovenCredentialsFailClosed(kind: String) async throws {
        let store = MemoryTokenStore(), client = recoveryClient(store: store, version: kind == "unknown-version" ? nil : "2.37.1")
        let token = kind == "malformed" ? "not-a-jwt" : recoveryJWT(#"{"userId":"u1","username":"reader","iat":1}"#, header: kind == "wrong-header" ? #"{"alg":"none","typ":"JWT"}"# : #"{"alg":"HS256","typ":"JWT"}"#)
        if kind != "absent" { await store.save(.init(accessToken: token, userID: kind == "wrong-user" ? "other-user" : "u1"), account: client.tokenAccount) }
        RecoveryHTTPProtocol.state.reset { _ in Issue.record("Unproven credentials reached HTTP"); return (200, recoveryUserJSON) }
        await #expect(throws: ABSError.notAuthenticated) { try await client.validateServerRecoveryAuthentication() }
        #expect(RecoveryHTTPProtocol.state.total == 0)
    }

    @Test(arguments: ["refresh-other-user", "refresh-inactive", "refresh-missing", "refresh-null", "refresh-empty", "me-other-user", "me-inactive", "me-401", "refresh-503"])
    func refreshOrFreshUserFailuresNeverFallbackOrReplay(kind: String) async throws {
        let store = MemoryTokenStore(), target = recoveryClient(store: store)
        await store.save(recoveryRetained, account: target.tokenAccount)
        RecoveryHTTPProtocol.state.reset { request in
            if request.url!.path.hasSuffix("/auth/refresh") {
                if kind == "refresh-503" { return (503, Data()) }
                if kind == "refresh-other-user" { return (200, Data(#"{"user":{"id":"other","username":"other","accessToken":"bad","refreshToken":"bad"}}"#.utf8)) }
                if kind == "refresh-inactive" { return (200, Data(#"{"user":{"id":"u1","username":"reader","isActive":false,"accessToken":"bad","refreshToken":"bad"}}"#.utf8)) }
                if kind == "refresh-missing" { return (200, Data(#"{"user":{"id":"u1","username":"reader","accessToken":"bad"}}"#.utf8)) }
                if kind == "refresh-null" { return (200, Data(#"{"user":{"id":"u1","username":"reader","accessToken":"bad","refreshToken":null}}"#.utf8)) }
                if kind == "refresh-empty" { return (200, Data(#"{"user":{"id":"u1","username":"reader","accessToken":"bad","refreshToken":""}}"#.utf8)) }
                return (200, recoveryRenewedJSON)
            }
            if kind == "me-401" { return (401, Data()) }
            if kind == "me-other-user" { return (200, Data(#"{"id":"other","username":"other"}"#.utf8)) }
            if kind == "me-inactive" { return (200, Data(#"{"id":"u1","username":"reader","isActive":false}"#.utf8)) }
            return (200, recoveryUserJSON)
        }
        do { _ = try await target.validateServerRecoveryAuthentication(); Issue.record("Invalid recovery proof accepted") }
        catch ABSError.notAuthenticated { }
        catch ABSError.http(let status, _) { #expect(status == (kind == "me-401" ? 401 : 503)) }
        #expect(RecoveryHTTPProtocol.state.count("/auth/refresh") == 1)
        #expect(RecoveryHTTPProtocol.state.count("/api/me") == (kind.hasPrefix("refresh-") ? 0 : 1))
        #expect(await store.load(account: target.tokenAccount) == (kind.hasPrefix("refresh-") ? recoveryRetained : recoveryRenewed))
    }

    @Test(arguments: ["cancel", "retire", "login"])
    func lateRenewalCannotValidateAnInvalidatedCaller(kind: String) async throws {
        let store = MemoryTokenStore(), client = recoveryClient(store: store)
        await store.save(recoveryRetained, account: client.tokenAccount)
        RecoveryHTTPProtocol.state.reset(blocking: ["/proxy/abs/auth/refresh"]) { request in
            if request.url!.path.hasSuffix("/login") { return (200, Data(#"{"user":{"id":"u1","username":"reader","accessToken":"replacement-access","refreshToken":"replacement-refresh"}}"#.utf8)) }
            return (200, recoveryRenewedJSON)
        }
        let validating = Task { try await client.validateServerRecoveryAuthentication() }
        try await RecoveryHTTPProtocol.state.wait("/auth/refresh")
        if kind == "cancel" { validating.cancel() }
        if kind == "retire" { await client.retireForServerRestore() }
        if kind == "login" { _ = try await client.login(username: "reader", password: "synthetic") }
        RecoveryHTTPProtocol.state.release()
        do { _ = try await validating.value; Issue.record("Late recovery proof accepted") }
        catch is CancellationError { #expect(kind == "cancel") }
        catch ABSError.sessionChanged { #expect(kind != "cancel") }
        #expect(RecoveryHTTPProtocol.state.count("/api/me") == 0)
        if kind == "login" { #expect(await store.load(account: client.tokenAccount)?.accessToken == "replacement-access") }
        if kind == "retire" { #expect(await store.load(account: client.tokenAccount) == recoveryRetained) }
    }

    @Test func alreadyCancelledOrRetiredEntryHasNoSideEffects() async throws {
        let store = MemoryTokenStore(), client = recoveryClient(store: store)
        await store.save(recoveryRetained, account: client.tokenAccount)
        RecoveryHTTPProtocol.state.reset { _ in Issue.record("Cancelled entry reached HTTP"); return (200, recoveryRenewedJSON) }
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.validateServerRecoveryAuthentication() }
        do { _ = try await cancelled.value; Issue.record("Cancelled entry accepted") } catch is CancellationError { }
        await client.retireForServerRestore()
        await #expect(throws: ABSError.sessionChanged) { try await client.validateServerRecoveryAuthentication() }
        #expect(RecoveryHTTPProtocol.state.total == 0)
        #expect(await store.load(account: client.tokenAccount) == recoveryRetained)
    }
}
