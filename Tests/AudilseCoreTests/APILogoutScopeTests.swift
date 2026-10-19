import Foundation
import Testing
@testable import AudilseCore

private let logoutFixtureTokens = AuthTokens(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: "u1")
private let logoutLoginData = Data(#"{"user":{"id":"u1","username":"reader","accessToken":"new-access","refreshToken":"new-refresh"},"serverVersion":"2.37.1"}"#.utf8)

private final class LogoutHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var handler: @Sendable (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    func reset(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.withLock { requests = []; self.handler = handler }
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let handler = lock.withLock { requests.append(request); return self.handler }
        return try handler(request)
    }
    var captured: [URLRequest] { lock.withLock { requests } }
}

private final class LogoutHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = LogoutHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "logout-scope.example.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func logoutClient(store: any TokenStore, version: String? = "2.37.1", userID: String? = "u1", cookie: Bool = false) -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LogoutHTTPProtocol.self]
    if cookie, let value = HTTPCookie(properties: [.domain: "logout-scope.example.test", .path: "/", .name: "refresh_token", .value: "unrelated-cookie-refresh", .secure: "TRUE"]) {
        configuration.httpCookieStorage?.setCookie(value)
    }
    return ABSClient(profile: .init(name: "Logout fixture", baseURL: URL(string: "https://logout-scope.example.test/proxy/abs")!, username: "reader", userID: userID, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
}

private actor LogoutGateStore: TokenStore {
    enum Gate { case load, remove }
    private var stored: AuthTokens?
    private let gate: Gate
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    init(gate: Gate, tokens: AuthTokens = logoutFixtureTokens) { self.gate = gate; stored = tokens }
    func load(account: String) async -> AuthTokens? {
        let snapshot = stored
        if gate == .load, !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        return snapshot
    }
    func save(_ tokens: AuthTokens, account: String) { stored = tokens }
    func remove(account: String) { stored = nil }
    func remove(account: String, matching tokens: AuthTokens) async {
        if gate == .remove, !entered {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        if stored == tokens { stored = nil }
    }
    func value() -> AuthTokens? { stored }
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while continuation == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor LogoutFailingStore: TokenStore {
    enum Failure: Error { case storage }
    let failLoad: Bool
    private var stored: AuthTokens? = logoutFixtureTokens
    init(failLoad: Bool) { self.failLoad = failLoad }
    func load(account: String) throws -> AuthTokens? { if failLoad { throw Failure.storage }; return stored }
    func save(_ tokens: AuthTokens, account: String) { stored = tokens }
    func remove(account: String) throws { throw Failure.storage }
    func remove(account: String, matching tokens: AuthTokens) throws { throw Failure.storage }
    func value() -> AuthTokens? { stored }
}

@Suite(.serialized) struct APILogoutScopeTests {
    @Test func automaticReauthenticationReportsRemoteFailureAfterLocalRemoval() async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store, cookie: true)
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.url?.query == nil)
            return (401, Data())
        }
        do { _ = try await client.logoutForReauthentication(); Issue.record("Remote failure was hidden") }
        catch let error as LogoutError {
            #expect(error.localCredentialsRemoved)
            guard case ABSError.http(status: 401, message: _) = error.underlyingError else { Issue.record("Wrong underlying error"); return }
        }
        #expect(await store.load(account: client.tokenAccount) == nil)
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test(arguments: [true, false])
    func automaticReauthenticationDoesNotClaimFailedStorageWasRemoved(failLoad: Bool) async throws {
        let store = LogoutFailingStore(failLoad: failLoad), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        do { _ = try await client.logoutForReauthentication(); Issue.record("Storage failure was hidden") }
        catch let error as LogoutError {
            #expect(!error.localCredentialsRemoved)
            #expect(error.underlyingError is LogoutFailingStore.Failure)
        }
        #expect(await store.value() == logoutFixtureTokens)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test func defaultLogoutStillExposesItsOriginalStorageError() async throws {
        let store = LogoutFailingStore(failLoad: false), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        do { _ = try await client.logout(); Issue.record("Storage failure was hidden") }
        catch { #expect(error is LogoutFailingStore.Failure) }
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: ["2.36.1", "2.37.1"])
    func allDevicesUsesOneFrozenHeaderRequestAndNoCookie(version: String) async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store, version: version, cookie: true)
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.url?.absoluteString == "https://logout-scope.example.test/proxy/abs/logout?allDevices=1")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "fixture-refresh")
            #expect(request.httpShouldHandleCookies == false)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return (200, Data(#"{"redirect_url":"https://identity.example.test/logout"}"#.utf8))
        }
        #expect(try await client.allDevicesLogoutEligibility() == .available)
        #expect(try await client.logout(scope: .allDevices) == .allDevicesRequested)
        #expect(await store.load(account: client.tokenAccount) == nil)
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test func defaultLogoutPreservesCurrentDeviceWireContract() async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store, version: "2.26.0")
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.url?.path == "/proxy/abs/logout")
            #expect(request.url?.query == nil)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "fixture-refresh")
            return (200, Data())
        }
        #expect(try await client.logout() == .currentDevice)
        #expect(await store.load(account: client.tokenAccount) == nil)
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test(arguments: [nil, "", "garbage", "2.26.0", "2.36.0"] as [String?])
    func unsupportedAndUnknownVersionsDoNotMutate(version: String?) async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store, version: version)
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        #expect(try await client.allDevicesLogoutEligibility() == .unsupportedServer)
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Unsupported all-device logout accepted") }
        catch let error as LogoutError {
            #expect(!error.localCredentialsRemoved)
            #expect(error.underlyingError as? LogoutPolicyError == .unavailable(.unsupportedServer))
        }
        #expect(await store.load(account: client.tokenAccount) == logoutFixtureTokens)
        #expect(try await client.accessToken() == "fixture-access")
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: [nil, "", " \n"] as [String?])
    func missingRefreshCannotReportAFalseServerSuccess(refresh: String?) async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store)
        let stored = AuthTokens(accessToken: "fixture-access", refreshToken: refresh, userID: "u1")
        await store.save(stored, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        #expect(try await client.allDevicesLogoutEligibility() == .missingRefreshToken)
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Missing refresh accepted") }
        catch let error as LogoutError {
            #expect(!error.localCredentialsRemoved)
            #expect(error.underlyingError as? LogoutPolicyError == .unavailable(.missingRefreshToken))
        }
        #expect(await store.load(account: client.tokenAccount) == stored)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: ["profileMissing", "tokenMissing", "differentUser"])
    func identityMustMatchBeforeLocalCleanup(identity: String) async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store, userID: identity == "profileMissing" ? nil : "u1")
        let stored = AuthTokens(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: identity == "tokenMissing" ? nil : "u2")
        await store.save(stored, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        #expect(try await client.allDevicesLogoutEligibility() == .accountMismatch)
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Mismatched identity accepted") }
        catch let error as LogoutError {
            #expect(!error.localCredentialsRemoved)
            #expect(error.underlyingError as? LogoutPolicyError == .unavailable(.accountMismatch))
        }
        #expect(await store.load(account: client.tokenAccount) == stored)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: [401, 503, -1])
    func failedRemoteRequestReportsLocalRemovalAndNeverReplays(status: Int) async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store)
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { _ in
            if status == -1 { throw URLError(.networkConnectionLost) }
            return (status, Data("fixture server body must not be retained".utf8))
        }
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Failed request reported success") }
        catch let error as LogoutError { #expect(error.localCredentialsRemoved) }
        #expect(await store.load(account: client.tokenAccount) == nil)
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
        do { _ = try await client.accessToken(); Issue.record("Removed credential remained usable") }
        catch ABSError.notAuthenticated {}
    }

    @Test func retiredAndAlreadyCancelledClientsCannotBeginLogout() async throws {
        let store = MemoryTokenStore(), client = logoutClient(store: store)
        await store.save(logoutFixtureTokens, account: client.tokenAccount)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.logout(scope: .allDevices)
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled entry accepted") }
        catch let error as LogoutError { #expect(!error.localCredentialsRemoved); #expect(error.underlyingError is CancellationError) }
        await client.retireForServerRestore()
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Retired entry accepted") }
        catch let error as LogoutError { #expect(!error.localCredentialsRemoved); #expect(error.underlyingError as? ABSError == .sessionChanged) }
        #expect(await store.load(account: client.tokenAccount) == logoutFixtureTokens)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: [true, false])
    func storageFailuresNeverBecomeSuccessOrSendRemoteWrite(failLoad: Bool) async throws {
        let store = LogoutFailingStore(failLoad: failLoad), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Failed store reported success") }
        catch let error as LogoutError { #expect(!error.localCredentialsRemoved); #expect(error.underlyingError is LogoutFailingStore.Failure) }
        #expect(await store.value() == logoutFixtureTokens)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test(arguments: ["eligibility", "execution"])
    func delayedCredentialLoadCannotLogoutANewerLogin(operation: String) async throws {
        let store = LogoutGateStore(gate: .load), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.url?.path.hasSuffix("/login") == true)
            return (200, logoutLoginData)
        }
        let loading = Task {
            if operation == "eligibility" { _ = try await client.allDevicesLogoutEligibility() }
            else { _ = try await client.logout(scope: .allDevices) }
        }
        try await store.wait()
        _ = try await client.login(username: "reader", password: "fixture-only")
        await store.release()
        do { try await loading.value; Issue.record("Stale read survived a newer login") }
        catch ABSError.sessionChanged { #expect(operation == "eligibility") }
        catch let error as LogoutError { #expect(!error.localCredentialsRemoved); #expect(error.underlyingError as? ABSError == .sessionChanged) }
        #expect(await store.value()?.accessToken == "new-access")
        #expect(try await client.accessToken() == "new-access")
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test func failedMatchingRemovalKeepsTheCurrentAccountAuthenticated() async throws {
        let store = LogoutFailingStore(failLoad: false), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.url?.path == "/proxy/abs/api/me")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            return (200, Data(#"{"id":"u1","username":"reader","isActive":true}"#.utf8))
        }
        do { _ = try await client.logout(scope: .allDevices); Issue.record("Failed removal accepted") }
        catch let error as LogoutError { #expect(!error.localCredentialsRemoved) }
        #expect(await store.value() == logoutFixtureTokens)
        #expect(try await client.currentUser().id == "u1")
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test func matchingRemovalCannotDeleteConcurrentNewLoginOrSendStaleLogout() async throws {
        let store = LogoutGateStore(gate: .remove), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { request in
            #expect(request.url?.path.hasSuffix("/login") == true)
            return (200, logoutLoginData)
        }
        let loggingOut = Task { try await client.logout(scope: .allDevices) }
        try await store.wait()
        _ = try await client.login(username: "reader", password: "fixture-only")
        await store.release()
        do { _ = try await loggingOut.value; Issue.record("Stale logout survived a newer login") }
        catch let error as LogoutError { #expect(error.localCredentialsRemoved); #expect(error.underlyingError as? ABSError == .sessionChanged) }
        #expect(await store.value()?.accessToken == "new-access")
        #expect(try await client.accessToken() == "new-access")
        #expect(LogoutHTTPProtocol.state.captured.count == 1)
    }

    @Test func cancellationAfterCommitFinishesMatchingRemovalWithoutRemoteWrite() async throws {
        let store = LogoutGateStore(gate: .remove), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        let loggingOut = Task { try await client.logout(scope: .allDevices) }
        try await store.wait()
        loggingOut.cancel()
        await store.release()
        do { _ = try await loggingOut.value; Issue.record("Cancelled operation reported completion") }
        catch let error as LogoutError { #expect(error.localCredentialsRemoved); #expect(error.underlyingError is CancellationError) }
        #expect(await store.value() == nil)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }

    @Test func retirementDuringRemovalStillReportsTheCompletedLocalCleanup() async throws {
        let store = LogoutGateStore(gate: .remove), client = logoutClient(store: store)
        LogoutHTTPProtocol.state.reset { _ in (200, Data()) }
        let loggingOut = Task { try await client.logout(scope: .allDevices) }
        try await store.wait()
        let retiring = Task { await client.retireForServerRestore() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !client.isRetired {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
        await store.release()
        await retiring.value
        do { _ = try await loggingOut.value; Issue.record("Retired operation reported success") }
        catch let error as LogoutError { #expect(error.localCredentialsRemoved); #expect(error.underlyingError as? ABSError == .sessionChanged) }
        #expect(await store.value() == nil)
        #expect(LogoutHTTPProtocol.state.captured.isEmpty)
    }
}
