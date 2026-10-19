import Foundation

extension ABSClient {
    public func adminUsers(includeProgress: Bool = false) async throws -> [AdminUser] {
        let response: AdminUsersResponse = try await getJSON(path: "api/users" + (includeProgress ? "?include=progress" : "")); return response.users
    }
    public func adminUser(id: String) async throws -> AdminUser { try await getJSON(path: "api/users/\(FeaturePath.id(id))") }
    public func createUser(_ draft: UserDraft) async throws -> AdminUser { let response: AdminUserResponse = try await postJSON(path: "api/users", body: draft); return response.user }
    public func updateUser(id: String, update: UserUpdate) async throws -> AdminUser { let response: AdminUserResponse = try await adminJSON(path: "api/users/\(FeaturePath.id(id))", method: "PATCH", body: update); return response.user }
    public func deleteUser(id: String) async throws { _ = try await requestData(path: "api/users/\(FeaturePath.id(id))", method: "DELETE") }
    public func unlinkUserOpenID(id: String) async throws { _ = try await requestData(path: "api/users/\(FeaturePath.id(id))/openid-unlink", method: "PATCH") }
    public func userListeningHistory(id: String, page: Int = 0, limit: Int = 30) async throws -> AdminPlaybackSessionPage {
        try await getJSON(path: adminHistoryPath("api/users/\(FeaturePath.id(id))/listening-sessions", page, limit))
    }
    public func userListeningStats(id: String) async throws -> ListeningStatistics { try await getJSON(path: "api/users/\(FeaturePath.id(id))/listening-stats") }
    public func adminPlaybackSessions(page: Int = 0, limit: Int = 30, userID: String? = nil,
                                      sort: AdminPlaybackSessionSort = .updatedAt, descending: Bool = true) async throws -> AdminPlaybackSessionPage {
        if let userID, !AdminPlaybackSessionPolicy.isValidIdentifier(userID) { throw AdminPlaybackSessionInputError.invalidUserID }
        var query = [URLQueryItem(name: "page", value: String(max(0, page))),
                     URLQueryItem(name: "itemsPerPage", value: String(min(500, max(1, limit)))),
                     URLQueryItem(name: "sort", value: sort.rawValue),
                     URLQueryItem(name: "desc", value: descending ? "1" : "0")]
        if let userID { query.append(.init(name: "user", value: userID)) }
        return try await getJSON(path: FeaturePath.query("api/sessions", query))
    }
    public func adminOpenPlaybackSessions() async throws -> AdminOpenSessions { try await getJSON(path: "api/sessions/open") }
    /// Typed snapshot for native management. Preserve the older diagnostic
    /// wrapper for callers that inspect arbitrary share-session fields.
    public func adminPlaybackSessionSnapshot() async throws -> AdminPlaybackSessionSnapshot { try await getJSON(path: "api/sessions/open") }
    /// Close the activity while retaining its recorded listening history. An
    /// empty body prevents syncSession from overwriting the owner's progress.
    public func closeAdminPlaybackSession(id: String) async throws {
        guard AdminPlaybackSessionPolicy.isValidIdentifier(id) else { throw AdminPlaybackSessionInputError.invalidSessionIDs }
        _ = try await requestData(path: "api/session/\(FeaturePath.id(id))/close", method: "POST", retryAfterAuthentication: false)
    }
    public func adminOnlineUsers() async throws -> AdminOnlineUsers { try await getJSON(path: "api/users/online") }
    public func deletePlaybackSession(id: String) async throws {
        guard AdminPlaybackSessionPolicy.isValidIdentifier(id) else { throw AdminPlaybackSessionInputError.invalidSessionIDs }
        _ = try await requestData(path: "api/sessions/\(FeaturePath.id(id))", method: "DELETE", retryAfterAuthentication: false)
    }
    public func deletePlaybackSessions(ids: [String]) async throws {
        guard !ids.isEmpty, ids.allSatisfy(AdminPlaybackSessionPolicy.isValidIdentifier) else { throw AdminPlaybackSessionInputError.invalidSessionIDs }
        _ = try await requestData(path: "api/sessions/batch/delete", method: "POST", body: JSONEncoder().encode(AdminSessionIDs(sessions: ids)), retryAfterAuthentication: false)
    }
    public func deleteAuthenticationSession(id: String) async throws {
        try requireAuthenticationSessions()
        _ = try await requestData(path: "api/me/sessions/\(FeaturePath.id(id))", method: "DELETE")
    }
    public func apiKeys() async throws -> [APIKeyRecord] { try requireAPIKeys(); let response: AdminAPIKeysResponse = try await getJSON(path: "api/api-keys"); return response.apiKeys }
    public func createAPIKey(_ draft: APIKeyDraft) async throws -> APIKeyRecord { try requireAPIKeys(); let response: AdminAPIKeyResponse = try await postJSON(path: "api/api-keys", body: draft); return response.apiKey }
    public func updateAPIKey(id: String, update: APIKeyUpdate) async throws -> APIKeyRecord { try requireAPIKeys(); let response: AdminAPIKeyResponse = try await adminJSON(path: "api/api-keys/\(FeaturePath.id(id))", method: "PATCH", body: update); return response.apiKey }
    public func deleteAPIKey(id: String) async throws { try requireAPIKeys(); _ = try await requestData(path: "api/api-keys/\(FeaturePath.id(id))", method: "DELETE") }

    public func backups() async throws -> BackupListing { try await getJSON(path: "api/backups") }
    public func createBackup() async throws -> BackupListing { try await postJSON(path: "api/backups", body: EmptyPayload()) }
    public func deleteBackup(id: String) async throws -> BackupListing { let data = try await requestData(path: "api/backups/\(FeaturePath.id(id))", method: "DELETE"); return try JSONDecoder().decode(BackupListing.self, from: data) }
    public func backupDownloadRequest(id: String) async throws -> URLRequest { try await authorizedRequest(path: "api/backups/\(FeaturePath.id(id))/download") }
    /// Applying a backup mutates the server despite its GET route. Never replay on 401.
    public func applyBackup(id: String) async throws { _ = try await requestData(path: "api/backups/\(FeaturePath.id(id))/apply", retryAfterAuthentication: false) }
    public func updateBackupLocation(path: String) async throws { _ = try await requestData(path: "api/backups/path", method: "PATCH", body: JSONEncoder().encode(AdminBackupPath(path: path))) }
    public func serverTasks(includeQueue: Bool = true) async throws -> ServerTaskListing { try await getJSON(path: "api/tasks" + (includeQueue ? "?include=queue" : "")) }
    public func purgeServerCache() async throws { _ = try await requestData(path: "api/cache/purge", method: "POST") }
    public func purgeItemCache() async throws { _ = try await requestData(path: "api/cache/items/purge", method: "POST") }
    public func serverSettings() async throws -> ServerSettingsUpdate { let response: AdminSettingsResponse = try await postJSON(path: "api/authorize", body: EmptyPayload()); return response.serverSettings }
    public func updateServerSettings(_ settings: ServerSettingsUpdate) async throws -> ServerSettingsUpdate { let response: AdminSettingsResponse = try await adminJSON(path: "api/settings", method: "PATCH", body: settings); return response.serverSettings }
    public func updateSortingPrefixes(_ prefixes: [String]) async throws -> ServerSettingsUpdate { let response: AdminSettingsResponse = try await adminJSON(path: "api/sorting-prefixes", method: "PATCH", body: AdminSortingPrefixes(sortingPrefixes: prefixes)); return response.serverSettings }
    /// Contains OIDC secrets; retain in memory only while an administrator edits the form.
    public func authenticationSettings() async throws -> AuthenticationSettings { try await getJSON(path: "api/auth-settings") }
    public func updateAuthenticationSettings(_ settings: AuthenticationSettings) async throws {
        _ = try await requestData(path: "api/auth-settings", method: "PATCH", body: JSONEncoder().encode(settings))
    }
    /// Contains SMTP credentials; do not persist this response in shelf caches.
    public func smtpSettings() async throws -> SMTPSettings { let response: AdminSMTPResponse = try await getJSON(path: "api/emails/settings"); return response.settings }
    public func updateSMTPSettings(_ settings: SMTPSettings) async throws -> SMTPSettings { let response: AdminSMTPResponse = try await adminJSON(path: "api/emails/settings", method: "PATCH", body: settings); return response.settings }
    public func sendSMTPTest() async throws { _ = try await requestData(path: "api/emails/test", method: "POST") }
    public func updateServerEReaderDevices(_ devices: [EReaderDevice]) async throws -> [EReaderDevice] { let response: AdminDevicesResponse = try await postJSON(path: "api/emails/ereader-devices", body: AdminDevicesPayload(ereaderDevices: devices)); return response.ereaderDevices }
    public func notificationConfiguration() async throws -> ServerNotificationConfiguration { try await getJSON(path: "api/notifications") }
    public func updateNotificationSettings(_ settings: NotificationSettingsUpdate) async throws { _ = try await requestData(path: "api/notifications", method: "PATCH", body: JSONEncoder().encode(settings)) }
    public func createNotification(_ notification: NotificationDraft) async throws -> NotificationSettings { try await postJSON(path: "api/notifications", body: notification) }
    public func updateNotification(id: String, update: NotificationDraft) async throws -> NotificationSettings {
        var payload = update; payload.id = id
        return try await adminJSON(path: "api/notifications/\(FeaturePath.id(id))", method: "PATCH", body: payload)
    }
    public func deleteNotification(id: String) async throws -> NotificationSettings { let data = try await requestData(path: "api/notifications/\(FeaturePath.id(id))", method: "DELETE"); return try JSONDecoder().decode(NotificationSettings.self, from: data) }
    public func sendNotificationTest(id: String) async throws { _ = try await requestData(path: "api/notifications/\(FeaturePath.id(id))/test", retryAfterAuthentication: false) }
    public func fireNotificationTestEvent(fail: Bool = false) async throws { _ = try await requestData(path: "api/notifications/test" + (fail ? "?fail=1" : ""), retryAfterAuthentication: false) }
    public func serverLogs() async throws -> [ServerLogEntry] { let response: AdminLogsResponse = try await getJSON(path: "api/logger-data"); return response.currentDailyLogs }
    /// Read-only, server-wide totals; the server requires an admin/root account.
    public func serverStorageStatistics() async throws -> ServerStorageStatistics { try await getJSON(path: "api/stats/server") }
    /// Read-only annual review, available on all supported ABS versions. The server
    /// accepts years 2000...9999 and enforces admin/root access; failures propagate.
    public func adminYearlyStatistics(year: Int) async throws -> AdminYearlyStatistics { try await getJSON(path: "api/stats/year/\(year)") }
    public func customMetadataProviders() async throws -> [CustomMetadataProvider] { let response: AdminCustomProvidersResponse = try await getJSON(path: "api/custom-metadata-providers"); return response.providers }
    public func createCustomMetadataProvider(_ draft: CustomMetadataProviderDraft) async throws -> CustomMetadataProvider { let response: AdminCustomProviderResponse = try await postJSON(path: "api/custom-metadata-providers", body: draft); return response.provider }
    public func deleteCustomMetadataProvider(id: String) async throws { _ = try await requestData(path: "api/custom-metadata-providers/\(FeaturePath.id(id))", method: "DELETE") }
    public func serverTags() async throws -> [String] { let response: AdminTagsResponse = try await getJSON(path: "api/tags"); return response.tags }
    public func serverGenres() async throws -> [String] { let response: AdminGenresResponse = try await getJSON(path: "api/genres"); return response.genres }
    public func renameServerTag(_ tag: String, to newTag: String) async throws -> TaxonomyUpdateResult { try await postJSON(path: "api/tags/rename", body: AdminRenameTag(tag: tag, newTag: newTag)) }
    public func renameServerGenre(_ genre: String, to newGenre: String) async throws -> TaxonomyUpdateResult { try await postJSON(path: "api/genres/rename", body: AdminRenameGenre(genre: genre, newGenre: newGenre)) }
    public func deleteServerTag(_ tag: String) async throws -> TaxonomyUpdateResult { let data = try await requestData(path: "api/tags/\(FeaturePath.id(Data(tag.utf8).base64EncodedString()))", method: "DELETE"); return try JSONDecoder().decode(TaxonomyUpdateResult.self, from: data) }
    public func deleteServerGenre(_ genre: String) async throws -> TaxonomyUpdateResult { let data = try await requestData(path: "api/genres/\(FeaturePath.id(Data(genre.utf8).base64EncodedString()))", method: "DELETE"); return try JSONDecoder().decode(TaxonomyUpdateResult.self, from: data) }
    public func validateCronExpression(_ expression: String) async throws { _ = try await requestData(path: "api/validate-cron", method: "POST", body: JSONEncoder().encode(AdminCronExpression(expression: expression))) }
    private func adminHistoryPath(_ path: String, _ page: Int, _ limit: Int) -> String { FeaturePath.query(path, [.init(name: "page", value: String(max(0, page))), .init(name: "itemsPerPage", value: String(min(500, max(1, limit))))]) }
    private func requireAPIKeys() throws { guard AdminCapabilities(version: profile.serverVersion).hasAPIKeys else { throw AdminFeatureError.unavailable(feature: "API Key 管理", minimumVersion: "2.37.1") } }
    private func requireAuthenticationSessions() throws { guard AdminCapabilities(version: profile.serverVersion).hasAuthenticationSessions else { throw AdminFeatureError.unavailable(feature: "活跃登录会话", minimumVersion: "2.37.1") } }
}
private struct AdminUsersResponse: Decodable, Sendable { let users: [AdminUser] }
private struct AdminUserResponse: Decodable, Sendable { let user: AdminUser }
private struct AdminAPIKeysResponse: Decodable, Sendable { let apiKeys: [APIKeyRecord] }
private struct AdminAPIKeyResponse: Decodable, Sendable { let apiKey: APIKeyRecord }
private struct AdminSessionIDs: Codable, Sendable { let sessions: [String] }
private struct AdminBackupPath: Codable, Sendable { let path: String }
private struct AdminSettingsResponse: Decodable, Sendable { let serverSettings: ServerSettingsUpdate }
private struct AdminSortingPrefixes: Codable, Sendable { let sortingPrefixes: [String] }
private struct AdminSMTPResponse: Decodable, Sendable { let settings: SMTPSettings }
private struct AdminDevicesResponse: Decodable, Sendable { let ereaderDevices: [EReaderDevice] }
private struct AdminDevicesPayload: Codable, Sendable { let ereaderDevices: [EReaderDevice] }
private struct AdminLogsResponse: Decodable, Sendable { let currentDailyLogs: [ServerLogEntry] }
private struct AdminCustomProvidersResponse: Decodable, Sendable { let providers: [CustomMetadataProvider] }
private struct AdminCustomProviderResponse: Decodable, Sendable { let provider: CustomMetadataProvider }
private struct AdminTagsResponse: Decodable, Sendable { let tags: [String] }
private struct AdminGenresResponse: Decodable, Sendable { let genres: [String] }
private struct AdminRenameTag: Encodable, Sendable { let tag: String; let newTag: String }
private struct AdminRenameGenre: Encodable, Sendable { let genre: String; let newGenre: String }
private struct AdminCronExpression: Encodable, Sendable { let expression: String }
