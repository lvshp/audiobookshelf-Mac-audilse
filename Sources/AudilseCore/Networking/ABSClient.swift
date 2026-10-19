import Foundation
import CryptoKit
import Security

public actor ABSClient {
    public private(set) var profile: ServerProfile
    private let session: URLSession
    private let tokenStore: any TokenStore
    private var tokens: AuthTokens?
    private var tokensLoaded = false
    private var refreshTask: Task<AuthTokens, Error>?
    private var generation: UInt64 = 0
    public private(set) var isRetired = false
    private var credentialOperations: [UUID: Task<Void, Error>] = [:]
    private var oidcFlow: OIDCFlow?
    private var tokenObservers: [UUID: AsyncStream<AuthTokens?>.Continuation] = [:]
    public init(profile: ServerProfile, session: URLSession = URLSession(configuration: .ephemeral), tokenStore: any TokenStore = LocalFileTokenStore.shared) {
        self.profile = profile; self.session = session; self.tokenStore = tokenStore
    }
    public var tokenAccount: String { profile.id.uuidString }
    var authenticationGeneration: UInt64 { generation }
    public var capabilities: ServerCapabilities { .init(version: profile.serverVersion ?? "2.26.0") }
    public func resourceURL(path: String) throws -> URL {
        try requireActive()
        return try ServerEndpoint(baseURL: profile.baseURL).url(path: path)
    }

    /// Permanently stop this instance before replacing server state. This is not logout:
    /// retained credentials belong to the fresh client and are never removed here.
    /// Await the barrier before creating that client: an already-entered store operation
    /// cannot be revoked, so it must finish before the replacement can use the account.
    public func retireForServerRestore() async {
        if !isRetired {
            isRetired = true
            generation &+= 1
            refreshTask?.cancel(); refreshTask = nil
            oidcFlow?.session.invalidateAndCancel(); oidcFlow = nil
            session.invalidateAndCancel()
            tokens = nil; tokensLoaded = true
            for observer in tokenObservers.values { observer.yield(nil); observer.finish() }
            tokenObservers.removeAll()
        }
        let pendingCredentials = Array(credentialOperations.values)
        for operation in pendingCredentials { _ = try? await operation.value }
    }

    private func requireActive(generation expectedGeneration: UInt64? = nil) throws {
        guard !isRetired, expectedGeneration == nil || generation == expectedGeneration else { throw ABSError.sessionChanged }
    }

    public func login(username: String, password: String) async throws -> LoginResponse {
        try requireActive()
        generation &+= 1; let loginGeneration = generation
        let account = tokenAccount
        refreshTask?.cancel(); refreshTask = nil
        var request = URLRequest(url: try resourceURL(path: "login"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONEncoder().encode(LoginPayload(username: username, password: password))
        let data = try await perform(request, using: session)
        let response = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard generation == loginGeneration else { throw ABSError.sessionChanged }
        profile.username = username; profile.userID = response.user.id; profile.serverVersion = response.serverVersion ?? profile.serverVersion
        let newTokens = AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken, userID: response.user.id)
        try await persistTokens(newTokens, account: account, expectedGeneration: loginGeneration)
        tokens = newTokens; tokensLoaded = true; publishTokens(newTokens)
        return response
    }

    @discardableResult
    public func logout(scope: LogoutScope = .currentDevice) async throws -> LogoutResult {
        if scope == .allDevices { return try await logoutAllDevices() }
        return try await logoutCurrentDevice(reportRemoval: false)
    }

    /// Automatic reauthentication needs a precise local/remote outcome without
    /// changing the default logout API's established error behavior.
    @discardableResult public func logoutForReauthentication() async throws -> LogoutResult {
        try await logoutCurrentDevice(reportRemoval: true)
    }

    private func logoutCurrentDevice(reportRemoval: Bool) async throws -> LogoutResult {
        let receipt = LogoutCredentialRemovalReceipt()
        do {
        try requireActive()
        let account = tokenAccount
        let cachedTokens = tokens
        generation &+= 1; let logoutGeneration = generation
        refreshTask?.cancel(); refreshTask = nil; tokens = nil; tokensLoaded = true; publishTokens(nil)
        oidcFlow?.session.invalidateAndCancel(); oidcFlow = nil
        // Invalidate in-flight credential readers before yielding to the store.
        let oldTokens: AuthTokens?
        if let cachedTokens { oldTokens = cachedTokens }
        else if reportRemoval { oldTokens = try await tokenStore.load(account: account) }
        else { oldTokens = try? await tokenStore.load(account: account) }
        guard generation == logoutGeneration else { throw ABSError.sessionChanged }
        if let oldTokens {
            try await credentialOperation { [tokenStore] in
                try await tokenStore.remove(account: account, matching: oldTokens)
                receipt.recordCompletion()
            }
        } else { receipt.recordCompletion() }
        guard generation == logoutGeneration else { throw ABSError.sessionChanged }
        // Local credentials are removed even if the server is unreachable.
        guard let oldTokens else { return .currentDevice }
        var request = URLRequest(url: try resourceURL(path: "logout")); request.httpMethod = "POST"
        if reportRemoval { request.httpShouldHandleCookies = false }
        request.setValue("Bearer \(oldTokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let refresh = oldTokens.refreshToken { request.setValue(refresh, forHTTPHeaderField: "x-refresh-token") }
        _ = try await perform(request, using: session)
        return .currentDevice
        } catch {
            if reportRemoval { throw LogoutError(localCredentialsRemoved: receipt.isComplete, underlyingError: error) }
            throw error
        }
    }

    /// This read is only a UI hint. Execution repeats the checks while freezing
    /// this actor's authentication generation before any local side effect.
    public func allDevicesLogoutEligibility() async throws -> AllDevicesLogoutEligibility {
        try Task.checkCancellation()
        try requireActive()
        let expectedGeneration = generation
        guard let version = profile.serverVersion,
              ServerCapabilities(version: version).supportsLogoutAllDevices else { return .unsupportedServer }
        let stored = try await loadTokens()
        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        return allDevicesLogoutEligibility(tokens: stored)
    }

    private func allDevicesLogoutEligibility(tokens stored: AuthTokens?) -> AllDevicesLogoutEligibility {
        guard let version = profile.serverVersion,
              ServerCapabilities(version: version).supportsLogoutAllDevices else { return .unsupportedServer }
        guard let stored, let refresh = stored.refreshToken,
              !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missingRefreshToken }
        guard let userID = profile.userID, !userID.isEmpty, stored.userID == userID else { return .accountMismatch }
        return .available
    }

    private func logoutAllDevices() async throws -> LogoutResult {
        let removalReceipt = LogoutCredentialRemovalReceipt()
        do {
            try Task.checkCancellation()
            try requireActive()
            let expectedGeneration = generation
            guard let version = profile.serverVersion,
                  ServerCapabilities(version: version).supportsLogoutAllDevices else {
                throw LogoutPolicyError.unavailable(.unsupportedServer)
            }
            let stored = try await loadTokens()
            try requireActive(generation: expectedGeneration)
            try Task.checkCancellation()
            let eligibility = allDevicesLogoutEligibility(tokens: stored)
            guard eligibility == .available, let oldTokens = stored,
                  let refreshToken = oldTokens.refreshToken else { throw LogoutPolicyError.unavailable(eligibility) }
            let account = tokenAccount
            var request = URLRequest(url: try resourceURL(path: "logout?allDevices=1"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(oldTokens.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
            // ABS gives its cookie precedence over x-refresh-token. Never let
            // a shared cookie select a different account than this snapshot.
            request.httpShouldHandleCookies = false

            generation &+= 1; let logoutGeneration = generation
            refreshTask?.cancel(); refreshTask = nil
            oidcFlow?.session.invalidateAndCancel(); oidcFlow = nil
            // Once committed, finish local cleanup even if cancellation arrives.
            // Matching removal cannot erase a concurrent newer login's tokens.
            try await credentialOperation { [tokenStore] in
                try await tokenStore.remove(account: account, matching: oldTokens)
                removalReceipt.recordCompletion()
            }
            try requireActive(generation: logoutGeneration)
            // A failed store removal leaves this account authenticated. Clear
            // the cache only after successful cleanup, without replacing a
            // newer login or the state of a client retired during that await.
            tokens = nil; tokensLoaded = true; publishTokens(nil)
            try Task.checkCancellation()
            // Unsafe writes get exactly one attempt, with no refresh or replay.
            _ = try await perform(request, using: session)
            try requireActive(generation: logoutGeneration)
            try Task.checkCancellation()
            return .allDevicesRequested
        } catch {
            throw LogoutError(localCredentialsRemoved: removalReceipt.isComplete, underlyingError: error)
        }
    }

    public func status() async throws -> ServerStatus {
        let response = try JSONDecoder().decode(ServerStatus.self, from: await perform(URLRequest(url: resourceURL(path: "status")), using: session))
        guard response.app == "audiobookshelf" else { throw ABSError.invalidResponse }
        guard ServerCapabilities(version: response.serverVersion).isSupported else { throw ABSError.unsupportedVersion(response.serverVersion) }
        profile.serverVersion = response.serverVersion
        return response
    }
    public func changePassword(currentPassword: String, newPassword: String) async throws -> PasswordChangeResult {
        let expectedGeneration = generation
        let account = tokenAccount
        var request = try await authorizedRequest(path: "api/me/password", method: "PATCH", body: JSONEncoder().encode(PasswordChangePayload(password: currentPassword, newPassword: newPassword)))
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        let previous = try await loadTokens()
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        if let refreshToken = previous?.refreshToken { request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token") }
        let data = try await perform(request, using: session)
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        if let result = try? JSONDecoder().decode(PasswordTokensResponse.self, from: data), let accessToken = result.user?.accessToken {
            let updated = AuthTokens(accessToken: accessToken, refreshToken: result.user?.refreshToken ?? previous?.refreshToken, userID: previous?.userID)
            try await persistTokens(updated, account: account, expectedGeneration: expectedGeneration)
            tokens = updated; tokensLoaded = true; publishTokens(updated)
            return .authenticated
        }
        // The verified 2.26 server returns plain OK without invalidating sessions.
        if ServerVersion(profile.serverVersion ?? "2.26.0") < ServerVersion("2.37.1") { return .authenticated }
        generation &+= 1; let invalidatedGeneration = generation
        refreshTask?.cancel(); refreshTask = nil
        tokens = nil; tokensLoaded = true; publishTokens(nil)
        if let previous { try await credentialOperation { [tokenStore] in try await tokenStore.remove(account: account, matching: previous) } }
        guard generation == invalidatedGeneration else { throw ABSError.sessionChanged }
        return .requiresSignIn
    }
    public func currentUser() async throws -> UserAccount { try await getJSON(path: "api/me") }

    /// A restored database may have removed this credential's refresh-session row
    /// while its access JWT remains valid. A successful ordinary GET is therefore
    /// insufficient proof that a saved login can survive its next token expiry.
    /// Call on a fresh client after the user has acknowledged the server restart.
    /// Authentication failures retain credentials for explicit reauthentication.
    public func validateServerRecoveryAuthentication() async throws -> UserAccount {
        try Task.checkCancellation()
        try requireActive()
        guard let version = profile.serverVersion, ServerCapabilities(version: version).isSupported else { throw ABSError.notAuthenticated }
        let expectedGeneration = generation
        guard let stored = try await loadTokens() else { throw ABSError.notAuthenticated }
        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        guard let expectedUserID = profile.userID ?? stored.userID, !expectedUserID.isEmpty,
              stored.userID == nil || stored.userID == expectedUserID else { throw ABSError.notAuthenticated }

        let access: String
        if let refreshToken = stored.refreshToken, !refreshToken.isEmpty {
            // All fixed supported releases (including 2.26) have this endpoint.
            // Force it even when the retained access token has hours left to live.
            let renewed = try await refresh()
            try requireActive(generation: expectedGeneration)
            try Task.checkCancellation()
            guard renewed.userID == expectedUserID else { throw ABSError.notAuthenticated }
            access = renewed.accessToken
        } else {
            // The deprecated user.token is genuinely permanent. Do not confuse a
            // malformed/unreadable exp, an API key, or an access-only JWT with it.
            guard Self.isLegacyPermanentToken(stored.accessToken) else { throw ABSError.notAuthenticated }
            access = stored.accessToken
        }

        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        var request = URLRequest(url: try resourceURL(path: "api/me"))
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("Audilse/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
        // No fallback to the pre-restore token and no automatic refresh/replay.
        let data = try await perform(request, using: session)
        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        let user = try JSONDecoder().decode(UserAccount.self, from: data)
        guard user.id == expectedUserID, user.isActive else { throw ABSError.notAuthenticated }
        return user
    }

    private static func isLegacyPermanentToken(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        func decode(_ value: Substring) -> Data? {
            var encoded = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            return Data(base64Encoded: encoded)
        }
        struct Header: Decodable { let alg: String; let typ: String }
        struct Claims: Decodable { let userId: String; let username: String; let iat: Double }
        guard let headerData = decode(parts[0]), let header = try? JSONDecoder().decode(Header.self, from: headerData),
              header.alg == "HS256", header.typ == "JWT",
              let data = decode(parts[1]), let legacy = try? JSONDecoder().decode(Claims.self, from: data),
              !legacy.userId.isEmpty, !legacy.username.isEmpty, legacy.iat.isFinite,
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(claims.keys) == ["userId", "username", "iat"] else { return false }
        // Server-side getUserByIdOrOldId may map a legacy JWT's historical ID.
        // The authenticated GET verifies its signature and the final account ID.
        return true
    }
    public func libraries() async throws -> [Library] { let response: LibrariesResponse = try await getJSON(path: "api/libraries"); return response.libraries }
    public func libraryItems(libraryID: String, page: Int = 0, limit: Int = 60, search: String? = nil) async throws -> ItemPage {
        let page = max(0, page); let limit = min(500, max(1, limit))
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Search has no page parameter in ABS. Fetch enough matches and slice consistently.
            let count = min(10_000, (page + 1) * limit + 1)
            let response: SearchResponse = try await getJSON(path: queryPath("api/libraries/\(ServerEndpoint.component(libraryID))/search", [URLQueryItem(name: "q", value: search), URLQueryItem(name: "limit", value: String(count))]))
            let matches = response.book + response.podcast
            let items = matches.map(\.libraryItem)
            let offset = page * limit
            let slice = offset < items.count ? Array(items.dropFirst(offset).prefix(limit)) : []
            return ItemPage(results: slice, total: items.count, limit: limit, page: page)
        }
        let data = try await requestData(path: queryPath("api/libraries/\(ServerEndpoint.component(libraryID))/items", [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "minified", value: "0"), URLQueryItem(name: "sort", value: "media.metadata.title")]))
        return try JSONDecoder().decode(ItemPage.self, from: data)
    }
    public func item(id: String) async throws -> LibraryItem { try await getJSON(path: "api/items/\(ServerEndpoint.component(id))?expanded=1&include=progress") }
    public func startPlayback(itemID: String, episodeID: String? = nil) async throws -> PlaybackSession {
        let suffix = episodeID.map { "/" + ServerEndpoint.component($0) } ?? ""
        let body = PlaybackStartPayload(deviceInfo: DeviceInfo(deviceId: profile.id.uuidString), supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/aac", "audio/x-m4a", "audio/flac", "audio/x-flac", "audio/wav", "audio/aiff"])
        return try await postJSON(path: "api/items/\(ServerEndpoint.component(itemID))/play\(suffix)", body: body)
    }
    public func syncPlayback(sessionID: String, currentTime: Double, timeListening: Double) async throws {
        _ = try await requestData(path: "api/session/\(ServerEndpoint.component(sessionID))/sync", method: "POST", body: try encode(PlaybackSyncPayload(currentTime: currentTime, timeListening: timeListening)))
    }
    public func closePlayback(sessionID: String, currentTime: Double, timeListening: Double) async throws {
        _ = try await requestData(path: "api/session/\(ServerEndpoint.component(sessionID))/close", method: "POST", body: try encode(PlaybackSyncPayload(currentTime: currentTime, timeListening: timeListening)))
    }
    public func syncLocalSession(_ localSession: LocalPlaybackSession) async throws { _ = try await requestData(path: "api/session/local", method: "POST", body: try encode(localSession)) }
    public func progress() async throws -> [MediaProgress] {
        // /api/me includes full progress in both verified 2.26.0 and 2.37.1 releases.
        try await currentUser().mediaProgress
    }
    public func progress(itemID: String, episodeID: String? = nil) async throws -> MediaProgress? {
        let suffix = episodeID.map { "/" + ServerEndpoint.component($0) } ?? ""
        do { return try await getJSON(path: "api/me/progress/\(ServerEndpoint.component(itemID))\(suffix)") }
        catch ABSError.http(status: 404, message: _) { return nil }
    }
    /// Legacy combined request retained for callers that explicitly change completion state.
    /// Position synchronization must use `setAudioPosition` instead: supported ABS releases
    /// ignore the supplied percentage whenever `isFinished` is present on an existing record.
    public func updateProgress(itemID: String, episodeID: String? = nil, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        let suffix = episodeID.map { "/" + ServerEndpoint.component($0) } ?? ""
        let payload = ProgressPayload(currentTime: currentTime, duration: duration, progress: duration > 0 ? min(1, max(0, currentTime / duration)) : 0, isFinished: isFinished)
        _ = try await requestData(path: "api/me/progress/\(ServerEndpoint.component(itemID))\(suffix)", method: "PATCH", body: try encode(payload))
    }
    /// Move audio without invoking ABS's explicit "mark unfinished" reset-to-zero behavior.
    public func updateAudioPosition(itemID: String, episodeID: String? = nil, currentTime: Double, duration: Double) async throws {
        let suffix = episodeID.map { "/" + ServerEndpoint.component($0) } ?? ""
        let payload = AudioPositionPayload(currentTime: currentTime, duration: duration, progress: duration > 0 ? min(1, max(0, currentTime / duration)) : 0)
        _ = try await requestData(path: "api/me/progress/\(ServerEndpoint.component(itemID))\(suffix)", method: "PATCH", body: try encode(payload))
    }
    /// An explicit user completion action. Marking unfinished resets ABS's audio position.
    public func setProgressFinished(itemID: String, episodeID: String? = nil, isFinished: Bool) async throws {
        let suffix = episodeID.map { "/" + ServerEndpoint.component($0) } ?? ""
        _ = try await requestData(path: "api/me/progress/\(ServerEndpoint.component(itemID))\(suffix)", method: "PATCH", body: try encode(ProgressFinishedPayload(isFinished: isFinished)))
    }
    /// Restore a chosen audio position without mixing position and completion wire semantics.
    /// A false target does not force a reset: the caller must verify the server's resulting state.
    public func setAudioPosition(itemID: String, episodeID: String? = nil, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        let expectedGeneration = generation
        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        try await updateAudioPosition(itemID: itemID, episodeID: episodeID, currentTime: currentTime, duration: duration)
        try requireActive(generation: expectedGeneration)
        try Task.checkCancellation()
        if isFinished {
            // A separate state-only request also preserves manually finished partial positions.
            try await setProgressFinished(itemID: itemID, episodeID: episodeID, isFinished: true)
            try requireActive(generation: expectedGeneration)
            try Task.checkCancellation()
        }
    }
    public func updateReadingProgress(itemID: String, location: String, progress: Double) async throws {
        _ = try await requestData(path: "api/me/progress/\(ServerEndpoint.component(itemID))", method: "PATCH", body: try encode(ReadingProgressPayload(ebookLocation: location, ebookProgress: min(1, max(0, progress)))))
    }
    public func bookmarks(itemID: String? = nil) async throws -> [Bookmark] {
        // Older releases expose bookmarks on the user; this endpoint is stable across supported versions.
        let user: UserWithBookmarks = try await getJSON(path: "api/me")
        return user.bookmarks.filter { itemID == nil || $0.libraryItemId == itemID }
    }
    public func createBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark { try await postJSON(path: "api/me/item/\(ServerEndpoint.component(itemID))/bookmark", body: BookmarkPayload(time: time, title: title)) }
    public func updateBookmark(itemID: String, time: Double, title: String) async throws -> Bookmark {
        let data = try await requestData(path: "api/me/item/\(ServerEndpoint.component(itemID))/bookmark", method: "PATCH", body: try encode(BookmarkPayload(time: time, title: title)))
        return try JSONDecoder().decode(Bookmark.self, from: data)
    }
    public func deleteBookmark(itemID: String, time: Double) async throws { _ = try await requestData(path: "api/me/item/\(ServerEndpoint.component(itemID))/bookmark/\(ServerEndpoint.component(String(time)))", method: "DELETE") }

    public func authorizedRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> URLRequest {
        let expectedGeneration = generation
        try requireActive()
        let token = try await accessToken()
        try requireActive(generation: expectedGeneration)
        var request = URLRequest(url: try resourceURL(path: path)); request.httpMethod = method.uppercased(); request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Audilse/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    public func authorizedURL(path: String) async throws -> URL {
        let expectedGeneration = generation
        try requireActive()
        let token = try await accessToken()
        try requireActive(generation: expectedGeneration)
        var c = URLComponents(url: try resourceURL(path: path), resolvingAgainstBaseURL: false)!
        var items = c.queryItems?.filter { $0.name != "token" } ?? []; items.append(URLQueryItem(name: "token", value: token)); c.queryItems = items
        guard let url = c.url else { throw ABSError.invalidResourcePath }; return url
    }
    public func accessToken() async throws -> String {
        let expectedGeneration = generation
        try requireActive()
        guard let tokens = try await loadTokens() else { throw ABSError.notAuthenticated }
        try requireActive(generation: expectedGeneration)
        if let expiry = tokens.expiresAt, expiry.timeIntervalSinceNow < 60, tokens.refreshToken != nil {
            let updated = try await refresh()
            try requireActive(generation: expectedGeneration)
            return updated.accessToken
        }
        return tokens.accessToken
    }
    public func getJSON<Response: Decodable & Sendable>(path: String) async throws -> Response { try JSONDecoder().decode(Response.self, from: await requestData(path: path)) }
    public func postJSON<Body: Encodable & Sendable, Response: Decodable & Sendable>(path: String, body: Body) async throws -> Response { try JSONDecoder().decode(Response.self, from: await requestData(path: path, method: "POST", body: encode(body))) }
    public func requestData(path: String, method: String = "GET", body: Data? = nil, retryAfterAuthentication: Bool? = nil) async throws -> Data {
        try await requestData(path: path, method: method, body: body, retryAfterAuthentication: retryAfterAuthentication, includeRefreshToken: false)
    }
    private func requestData(path: String, method: String, body: Data?, retryAfterAuthentication: Bool?, includeRefreshToken: Bool) async throws -> Data {
        try requireActive()
        let requestGeneration = generation
        let request = try await sessionRequest(path: path, method: method, body: body, includeRefreshToken: includeRefreshToken)
        guard generation == requestGeneration else { throw ABSError.sessionChanged }
        do {
            let data = try await perform(request, using: session)
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            return data
        }
        catch ABSError.http(status: 401, message: _) {
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            let rejectedToken = request.value(forHTTPHeaderField: "Authorization")
            let current = try await loadTokens()
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            if rejectedToken == current.map({ "Bearer \($0.accessToken)" }) { _ = try await refresh() }
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            // Only safe reads replay automatically. Mutations return an error for an explicit user retry.
            guard retryAfterAuthentication ?? ["GET", "HEAD"].contains(method.uppercased()) else { throw ABSError.http(status: 401, message: "认证已更新，请重试此操作。") }
            let retryRequest = try await sessionRequest(path: path, method: method, body: body, includeRefreshToken: includeRefreshToken)
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            let data = try await perform(retryRequest, using: session)
            guard generation == requestGeneration else { throw ABSError.sessionChanged }
            return data
        }
    }
    private func sessionRequest(path: String, method: String, body: Data?, includeRefreshToken: Bool) async throws -> URLRequest {
        let expectedGeneration = generation
        var request = try await authorizedRequest(path: path, method: method, body: body)
        if includeRefreshToken {
            let stored = try await loadTokens()
            guard generation == expectedGeneration else { throw ABSError.sessionChanged }
            if let refreshToken = stored?.refreshToken { request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token") }
        }
        return request
    }
    public func authenticationSessions(page: Int = 0, limit: Int = 20) async throws -> AuthenticationSessionPage {
        guard AdminCapabilities(version: profile.serverVersion).hasAuthenticationSessions else { throw AdminFeatureError.unavailable(feature: "活跃登录会话", minimumVersion: "2.37.1") }
        let path = queryPath("api/me/sessions", [.init(name: "page", value: String(max(0, page))), .init(name: "itemsPerPage", value: String(min(500, max(1, limit))))])
        return try JSONDecoder().decode(AuthenticationSessionPage.self, from: await requestData(path: path, method: "GET", body: nil, retryAfterAuthentication: true, includeRefreshToken: true))
    }
    /// Upload a prepared multipart file without loading the complete audiobook into memory.
    /// Unsafe writes never replay automatically after an ambiguous failure.
    func uploadMultipart(path: String, fileURL: URL, contentType: String, expectedGeneration: UInt64, progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> Data {
        try requireActive(generation: expectedGeneration)
        var request = try await authorizedRequest(path: path, method: "POST")
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: SameServerRedirectDelegate(endpoint: try ServerEndpoint(baseURL: profile.baseURL), uploadProgress: progress)) }
        catch { try requireActive(generation: expectedGeneration); throw error }
        try requireActive(generation: expectedGeneration)
        guard let response = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw ABSError.http(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        return data
    }
    public func downloadBackup(id: String, destination: URL) async throws {
        try requireActive()
        guard destination.isFileURL else { throw ABSError.invalidResourcePath }
        let expectedGeneration = generation
        let request = try await authorizedRequest(path: "api/backups/\(ServerEndpoint.component(id))/download")
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(for: request, delegate: SameServerRedirectDelegate(endpoint: try ServerEndpoint(baseURL: profile.baseURL))) }
        catch { try requireActive(generation: expectedGeneration); throw error }
        try requireActive(generation: expectedGeneration)
        guard let response = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ABSError.http(status: response.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)) }
        try Task.checkCancellation()
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Audilse-backup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: temporary, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
        else { try FileManager.default.moveItem(at: staging, to: destination) }
    }

    public func refresh() async throws -> AuthTokens {
        try requireActive()
        let refreshGeneration = generation
        if let refreshTask {
            let result = try await refreshTask.value
            try requireActive(generation: refreshGeneration)
            return result
        }
        guard let old = try await loadTokens(), let refreshToken = old.refreshToken else { throw ABSError.notAuthenticated }
        try requireActive(generation: refreshGeneration)
        if let refreshTask {
            let result = try await refreshTask.value
            try requireActive(generation: refreshGeneration)
            return result
        }
        let expectedUserID = old.userID ?? profile.userID
        let task = Task<AuthTokens, Error> { try await self.performRefresh(refreshToken, expectedGeneration: refreshGeneration, expectedUserID: expectedUserID) }
        refreshTask = task
        defer { if generation == refreshGeneration { refreshTask = nil } }
        let result = try await task.value
        try requireActive(generation: refreshGeneration)
        return result
    }
    private func performRefresh(_ refreshToken: String, expectedGeneration: UInt64, expectedUserID: String?) async throws -> AuthTokens {
        let account = tokenAccount
        var request = URLRequest(url: try resourceURL(path: "auth/refresh")); request.httpMethod = "POST"; request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
        let response = try JSONDecoder().decode(LoginResponse.self, from: await perform(request, using: session))
        guard generation == expectedGeneration else { throw ABSError.sessionChanged }
        // Header-based refresh returns the current/rotated refresh token on all
        // fixed releases. Retaining an omitted old value cannot prove renewal.
        guard response.user.isActive, expectedUserID == nil || response.user.id == expectedUserID,
              let renewedRefreshToken = response.refreshToken, !renewedRefreshToken.isEmpty else { throw ABSError.notAuthenticated }
        let updated = AuthTokens(accessToken: response.accessToken, refreshToken: renewedRefreshToken, userID: response.user.id)
        try await persistTokens(updated, account: account, expectedGeneration: expectedGeneration)
        tokens = updated; tokensLoaded = true; publishTokens(updated)
        return updated
    }
    public func tokenUpdates() -> AsyncStream<AuthTokens?> {
        if isRetired { return AsyncStream { $0.yield(nil); $0.finish() } }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            tokenObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeTokenObserver(id) } }
        }
    }
    private func removeTokenObserver(_ id: UUID) { tokenObservers.removeValue(forKey: id) }
    private func publishTokens(_ tokens: AuthTokens?) { for observer in tokenObservers.values { observer.yield(tokens) } }
    private func credentialOperation(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try requireActive()
        let id = UUID()
        let task = Task {
            try self.requireActive()
            try await operation()
        }
        credentialOperations[id] = task
        defer { credentialOperations.removeValue(forKey: id) }
        do { try await task.value }
        catch { try requireActive(); throw error }
        try requireActive()
    }
    private func persistTokens(_ updated: AuthTokens, account: String, expectedGeneration: UInt64) async throws {
        try requireActive(generation: expectedGeneration)
        try await credentialOperation { [tokenStore] in try await tokenStore.save(updated, account: account) }
        guard generation == expectedGeneration else {
            try await credentialOperation { [tokenStore] in try await tokenStore.remove(account: account, matching: updated) }
            throw ABSError.sessionChanged
        }
    }
    private func loadTokens() async throws -> AuthTokens? {
        try requireActive()
        if !tokensLoaded {
            let expectedGeneration = generation
            let loaded: AuthTokens?
            do { loaded = try await tokenStore.load(account: tokenAccount) }
            catch { try requireActive(generation: expectedGeneration); throw error }
            try requireActive(generation: expectedGeneration)
            // Another reader or refresh may have filled the cache while storage was suspended.
            if !tokensLoaded { tokens = loaded; tokensLoaded = true }
        }
        return tokens
    }
    private func transfer(_ request: URLRequest, using session: URLSession, followRedirects: Bool = true) async throws -> (Data, URLResponse) {
        try requireActive()
        let expectedGeneration = generation
        do {
            let delegate: any URLSessionTaskDelegate = followRedirects ? SameServerRedirectDelegate(endpoint: try ServerEndpoint(baseURL: profile.baseURL)) : StopRedirectDelegate()
            let result = try await session.data(for: request, delegate: delegate)
            try requireActive(generation: expectedGeneration)
            return result
        } catch { try requireActive(generation: expectedGeneration); throw error }
    }
    private func perform(_ request: URLRequest, using session: URLSession) async throws -> Data {
        let (data, response) = try await transfer(request, using: session)
        guard let response = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            // Server error bodies can include paths/tokens; never retain arbitrary response bodies in diagnostics.
            let message: String
            switch response.statusCode { case 401: message = "需要重新认证"; case 403: message = "账户没有执行此操作的权限"; case 404: message = "资源不存在或当前版本不支持"; case 429: message = "请求过于频繁，请稍后重试"; default: message = HTTPURLResponse.localizedString(forStatusCode: response.statusCode) }
            throw ABSError.http(status: response.statusCode, message: message)
        }
        return data
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private func queryPath(_ path: String, _ query: [URLQueryItem]) -> String { var c = URLComponents(); c.percentEncodedPath = path; c.queryItems = query; c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B"); return c.string ?? path }
}

private struct LoginPayload: Encodable { let username: String; let password: String }
private struct LibrariesResponse: Decodable { let libraries: [Library] }
private struct SearchMatch: Decodable { let libraryItem: LibraryItem }
private struct SearchResponse: Decodable {
    let book: [SearchMatch]; let podcast: [SearchMatch]
    enum CodingKeys: String, CodingKey { case book, podcast }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); book = c.value(.book, default: []); podcast = c.value(.podcast, default: []) }
}
private struct PlaybackStartPayload: Encodable { let deviceInfo: DeviceInfo; let supportedMimeTypes: [String]; let mediaPlayer = "AVFoundation" }
private struct PlaybackSyncPayload: Encodable {
    let currentTime: Double
    let timeListening: Double
    enum CodingKeys: String, CodingKey { case currentTime; case timeListening = "timeListened" }
}
private struct ProgressPayload: Encodable { let currentTime: Double; let duration: Double; let progress: Double; let isFinished: Bool }
private struct AudioPositionPayload: Encodable { let currentTime: Double; let duration: Double; let progress: Double }
private struct ProgressFinishedPayload: Encodable { let isFinished: Bool }
private struct ReadingProgressPayload: Encodable { let ebookLocation: String; let ebookProgress: Double }
private struct BookmarkPayload: Encodable { let time: Double; let title: String }
private struct UserWithBookmarks: Decodable { let bookmarks: [Bookmark] }

public struct OIDCAuthorization: Sendable {
    public let authorizationURL: URL
    public let callbackScheme: String
    public let state: String
}

private struct OIDCFlow {
    let session: URLSession
    let state: String
    let verifier: String
    let generation: UInt64
}

extension ABSClient {
    /// The server must allow audilse://oauth in its OpenID mobile redirect URI list.
    /// The first request stays in URLSession to preserve the server session cookie for PKCE exchange.
    public func beginOIDC() async throws -> OIDCAuthorization {
        try requireActive()
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil
        oidcFlow?.session.invalidateAndCancel()
        let state = try randomBase64URL(); let verifier = try randomBase64URL()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let authSession = URLSession(configuration: session.configuration, delegate: StopRedirectDelegate(), delegateQueue: nil)
        let flow = OIDCFlow(session: authSession, state: state, verifier: verifier, generation: generation)
        oidcFlow = flow
        let path = queryPath("auth/openid", [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: "audilse://oauth"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256")])
        let (data, response) = try await transfer(URLRequest(url: resourceURL(path: path)), using: authSession, followRedirects: false)
        _ = data
        guard let response = response as? HTTPURLResponse, [301, 302, 303, 307, 308].contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let url = URL(string: location), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { throw ABSError.invalidResponse }
        guard generation == flow.generation else { throw ABSError.sessionChanged }
        return OIDCAuthorization(authorizationURL: url, callbackScheme: "audilse", state: state)
    }
    public func completeOIDC(callbackURL: URL) async throws -> LoginResponse {
        try requireActive()
        guard let flow = oidcFlow, callbackURL.scheme == "audilse", callbackURL.host == "oauth", let c = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false), c.queryItems?.first(where: { $0.name == "state" })?.value == flow.state, let code = c.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw ABSError.invalidOIDCCallback }
        guard generation == flow.generation else { throw ABSError.sessionChanged }
        let path = queryPath("auth/openid/callback", [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: flow.state), URLQueryItem(name: "code_verifier", value: flow.verifier)])
        var request = URLRequest(url: try resourceURL(path: path)); request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        let response = try JSONDecoder().decode(LoginResponse.self, from: await perform(request, using: flow.session))
        guard generation == flow.generation else { throw ABSError.sessionChanged }
        profile.username = response.user.username; profile.userID = response.user.id
        let updated = AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken, userID: response.user.id)
        let account = tokenAccount
        try await persistTokens(updated, account: account, expectedGeneration: flow.generation)
        tokens = updated; tokensLoaded = true; publishTokens(updated); oidcFlow = nil; flow.session.finishTasksAndInvalidate()
        return response
    }
    public func cancelOIDC() {
        guard oidcFlow != nil else { return }
        generation &+= 1
        oidcFlow?.session.invalidateAndCancel(); oidcFlow = nil
    }
    private func randomBase64URL() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ABSError.invalidResponse }
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
private final class StopRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class SameServerRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let endpoint: ServerEndpoint
    let uploadProgress: (@Sendable (Int64, Int64) -> Void)?
    init(endpoint: ServerEndpoint, uploadProgress: (@Sendable (Int64, Int64) -> Void)? = nil) { self.endpoint = endpoint; self.uploadProgress = uploadProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        uploadProgress?(totalBytesSent, totalBytesExpectedToSend)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? endpoint.url(path: url.absoluteString)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private struct PasswordChangePayload: Encodable { let password: String; let newPassword: String }
private struct PasswordTokensResponse: Decodable { struct UserTokens: Decodable { let accessToken: String?; let refreshToken: String? }; let success: Bool?; let user: UserTokens? }
