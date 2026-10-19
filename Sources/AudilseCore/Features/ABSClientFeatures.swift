import Foundation

extension ABSClient {
    public func libraryDetails(id: String) async throws -> LibraryDetails { try await getJSON(path: "api/libraries/\(FeaturePath.id(id))") }
    public func authors(libraryID: String, page: Int = 0, limit: Int = 60) async throws -> FeaturePage<Author> {
        try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(libraryID))/authors", page: page, limit: limit, extra: [URLQueryItem(name: "sort", value: "name")]))
    }
    public func author(id: String) async throws -> Author { try await getJSON(path: "api/authors/\(FeaturePath.id(id))?include=items,series") }
    public func updateAuthor(id: String, update: AuthorUpdate) async throws -> Author { try await updateAuthorResult(id: id, update: update).author }
    public func updateAuthorResult(id: String, update: AuthorUpdate) async throws -> AuthorMutationResult { try await featureJSON(path: "api/authors/\(FeaturePath.id(id))", method: "PATCH", body: update) }
    public func matchAuthor(id: String, match: AuthorMatch) async throws -> Author { try await matchAuthorResult(id: id, match: match).author }
    public func matchAuthorResult(id: String, match: AuthorMatch) async throws -> AuthorMutationResult { try await postJSON(path: "api/authors/\(FeaturePath.id(id))/match", body: match) }
    public func setAuthorImage(id: String, url: String) async throws -> Author { try await setAuthorImageResult(id: id, url: url).author }
    public func setAuthorImageResult(id: String, url: String) async throws -> AuthorMutationResult { try await postJSON(path: "api/authors/\(FeaturePath.id(id))/image", body: ImageURLPayload(url: url)) }
    public func deleteAuthorImage(id: String) async throws -> Author { try await deleteAuthorImageResult(id: id).author }
    public func deleteAuthorImageResult(id: String) async throws -> AuthorMutationResult { try JSONDecoder().decode(AuthorMutationResult.self, from: await requestData(path: "api/authors/\(FeaturePath.id(id))/image", method: "DELETE")) }
    public func deleteAuthor(id: String) async throws { _ = try await requestData(path: "api/authors/\(FeaturePath.id(id))", method: "DELETE") }
    public func series(libraryID: String, page: Int = 0, limit: Int = 60) async throws -> FeaturePage<BookSeries> {
        try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(libraryID))/series", page: page, limit: limit, extra: [URLQueryItem(name: "sort", value: "name"), URLQueryItem(name: "include", value: "progress,rssfeed")]))
    }
    public func series(id: String, libraryID: String) async throws -> BookSeries { try await getJSON(path: "api/libraries/\(FeaturePath.id(libraryID))/series/\(FeaturePath.id(id))?include=progress,rssfeed") }
    public func updateSeries(id: String, update: SeriesUpdate) async throws -> BookSeries { try await featureJSON(path: "api/series/\(FeaturePath.id(id))", method: "PATCH", body: update) }
    public func setSeriesHiddenFromContinueListening(id: String, hidden: Bool) async throws { _ = try await setSeriesHiddenFromContinueListeningResult(id: id, hidden: hidden) }
    public func setSeriesHiddenFromContinueListeningResult(id: String, hidden: Bool) async throws -> UserAccount {
        try JSONDecoder().decode(UserAccount.self, from: await requestData(path: "api/me/series/\(FeaturePath.id(id))/\(hidden ? "remove-from-continue-listening" : "readd-to-continue-listening")", retryAfterAuthentication: false))
    }
    /// This route mutates state despite using GET. Never retry after authentication.
    public func hideProgressFromContinueListening(progressID: String) async throws -> UserAccount {
        try JSONDecoder().decode(UserAccount.self, from: await requestData(path: "api/me/progress/\(FeaturePath.id(progressID))/remove-from-continue-listening", retryAfterAuthentication: false))
    }
    public func items(libraryID: String, authorID: String, page: Int = 0, limit: Int = 60) async throws -> ItemPage { try await filteredItems(libraryID: libraryID, filter: "authors." + FeaturePath.filterValue(authorID), page: page, limit: limit) }
    public func items(libraryID: String, seriesID: String, page: Int = 0, limit: Int = 60) async throws -> ItemPage { try await filteredItems(libraryID: libraryID, filter: "series." + FeaturePath.filterValue(seriesID), page: page, limit: limit) }
    private func filteredItems(libraryID: String, filter: String, page: Int, limit: Int) async throws -> ItemPage {
        try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(libraryID))/items", page: page, limit: limit, extra: [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "sort", value: "media.metadata.title"), URLQueryItem(name: "minified", value: "0")]))
    }

    public func collections(libraryID: String, page: Int = 0, limit: Int = 60) async throws -> FeaturePage<BookCollection> { try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(libraryID))/collections", page: page, limit: limit, extra: [URLQueryItem(name: "include", value: "rssfeed")])) }
    public func collection(id: String) async throws -> BookCollection { try await getJSON(path: "api/collections/\(FeaturePath.id(id))?include=rssfeed") }
    public func createCollection(_ draft: CollectionDraft) async throws -> BookCollection { try await postJSON(path: "api/collections", body: draft) }
    public func updateCollection(id: String, update: CollectionUpdate) async throws -> BookCollection { try await featureJSON(path: "api/collections/\(FeaturePath.id(id))", method: "PATCH", body: update) }
    public func deleteCollection(id: String) async throws { _ = try await requestData(path: "api/collections/\(FeaturePath.id(id))", method: "DELETE") }
    public func addCollectionBooks(id: String, itemIDs: [String]) async throws -> BookCollection { try await postJSON(path: "api/collections/\(FeaturePath.id(id))/batch/add", body: BookIDsPayload(books: itemIDs)) }
    public func removeCollectionBooks(id: String, itemIDs: [String]) async throws -> BookCollection { try await postJSON(path: "api/collections/\(FeaturePath.id(id))/batch/remove", body: BookIDsPayload(books: itemIDs)) }

    public func playlists(libraryID: String, page: Int = 0, limit: Int = 60) async throws -> FeaturePage<Playlist> { try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(libraryID))/playlists", page: page, limit: limit)) }
    public func playlist(id: String) async throws -> Playlist { try await getJSON(path: "api/playlists/\(FeaturePath.id(id))") }
    public func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist { try await postJSON(path: "api/playlists", body: draft) }
    public func updatePlaylist(id: String, update: PlaylistUpdate) async throws -> Playlist { try await featureJSON(path: "api/playlists/\(FeaturePath.id(id))", method: "PATCH", body: update) }
    public func deletePlaylist(id: String) async throws { _ = try await requestData(path: "api/playlists/\(FeaturePath.id(id))", method: "DELETE") }
    public func addPlaylistItems(id: String, items: [PlaylistItemReference]) async throws -> Playlist { try await postJSON(path: "api/playlists/\(FeaturePath.id(id))/batch/add", body: PlaylistItemsPayload(items: items)) }
    public func removePlaylistItems(id: String, items: [PlaylistItemReference]) async throws -> Playlist { try await postJSON(path: "api/playlists/\(FeaturePath.id(id))/batch/remove", body: PlaylistItemsPayload(items: items)) }
    public func createPlaylist(collectionID: String) async throws -> Playlist { try await postJSON(path: "api/playlists/collection/\(FeaturePath.id(collectionID))", body: EmptyPayload()) }

    public func listeningStats() async throws -> ListeningStatistics { try await getJSON(path: "api/me/listening-stats") }
    public func listeningHistory(page: Int = 0, limit: Int = 30, itemID: String? = nil, episodeID: String? = nil) async throws -> ListeningHistoryPage {
        let path: String
        if let itemID { path = "api/me/item/listening-sessions/\(FeaturePath.id(itemID))" + (episodeID.map { "/" + FeaturePath.id($0) } ?? "") }
        else { path = "api/me/listening-sessions" }
        return try await getJSON(path: FeaturePath.query(path, [URLQueryItem(name: "page", value: String(max(0, page))), URLQueryItem(name: "itemsPerPage", value: String(min(500, max(1, limit))))]))
    }
    public func yearlyStatistics(year: Int) async throws -> YearlyStatistics { try await getJSON(path: "api/me/stats/year/\(year)") }
    public func personalAccountDetails() async throws -> PersonalAccountDetails { try await postJSON(path: "api/authorize", body: EmptyPayload()) }
    public func updateEReaderDevices(_ devices: [EReaderDevice]) async throws -> [EReaderDevice] { let response: EReaderDevicesResponse = try await postJSON(path: "api/me/ereader-devices", body: EReaderDevicesPayload(ereaderDevices: devices)); return response.ereaderDevices }
    public func sendEBook(itemID: String, deviceName: String) async throws { _ = try await requestData(path: "api/emails/send-ebook-to-device", method: "POST", body: JSONEncoder().encode(SendEBookPayload(libraryItemId: itemID, deviceName: deviceName))) }

    public func rssFeeds() async throws -> [RSSFeed] { let response: FeedsResponse = try await getJSON(path: "api/feeds"); return response.feeds }
    public func openRSSFeed(entity: RSSEntity, id: String, options: RSSFeedOptions) async throws -> RSSFeed { let response: FeedResponse = try await postJSON(path: "api/feeds/\(entity.rawValue)/\(FeaturePath.id(id))/open", body: options); return response.feed }
    public func closeRSSFeed(id: String) async throws { _ = try await requestData(path: "api/feeds/\(FeaturePath.id(id))/close", method: "POST", body: JSONEncoder().encode(EmptyPayload())) }
    public func createShare(_ draft: MediaShareDraft) async throws -> MediaShare { try await postJSON(path: "api/share/mediaitem", body: draft) }
    public func deleteShare(id: String) async throws { _ = try await requestData(path: "api/share/mediaitem/\(FeaturePath.id(id))", method: "DELETE") }

    private func featureJSON<Body: Encodable & Sendable, Response: Decodable & Sendable>(path: String, method: String, body: Body) async throws -> Response { try JSONDecoder().decode(Response.self, from: await requestData(path: path, method: method, body: JSONEncoder().encode(body))) }
}

struct FeaturePath {
    static func id(_ value: String) -> String { ServerEndpoint.component(value) }
    static func filterValue(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    static func query(_ path: String, _ items: [URLQueryItem]) -> String { var c = URLComponents(); c.percentEncodedPath = path; c.queryItems = items; c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B"); return c.string ?? path }
    static func page(_ path: String, page: Int, limit: Int, extra: [URLQueryItem] = []) -> String { query(path, [URLQueryItem(name: "page", value: String(max(0, page))), URLQueryItem(name: "limit", value: String(min(500, max(1, limit))))] + extra) }
}
private struct BookIDsPayload: Encodable, Sendable { let books: [String] }
private struct PlaylistItemsPayload: Encodable, Sendable { let items: [PlaylistItemReference] }
struct EmptyPayload: Encodable, Sendable {}
private struct FeedsResponse: Decodable, Sendable { let feeds: [RSSFeed] }
private struct FeedResponse: Decodable, Sendable { let feed: RSSFeed }
private struct EReaderDevicesResponse: Decodable, Sendable { let ereaderDevices: [EReaderDevice] }
private struct EReaderDevicesPayload: Encodable, Sendable { let ereaderDevices: [EReaderDevice] }
private struct SendEBookPayload: Encodable, Sendable { let libraryItemId: String; let deviceName: String }
private struct ImageURLPayload: Encodable, Sendable { let url: String }
