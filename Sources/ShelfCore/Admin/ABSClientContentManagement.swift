import Foundation

extension ABSClient {
    public func updateItemMedia(id: String, update: MediaUpdate) async throws -> ItemMediaUpdateResult {
        try await adminJSON(path: "api/items/\(FeaturePath.id(id))/media", method: "PATCH", body: update)
    }
    public func batchUpdateItemMedia(_ updates: [BatchMediaUpdate]) async throws -> BatchUpdateResult {
        try await postJSON(path: "api/items/batch/update", body: updates)
    }
    public func batchItems(ids: [String]) async throws -> [LibraryItem] {
        let response: AdminItemsResponse = try await postJSON(path: "api/items/batch/get", body: AdminItemIDs(libraryItemIds: ids)); return response.libraryItems
    }
    public func deleteItem(id: String, deleteFiles: Bool = false) async throws {
        _ = try await requestData(path: "api/items/\(FeaturePath.id(id))" + (deleteFiles ? "?hard=1" : ""), method: "DELETE")
    }
    public func deleteItems(ids: [String], deleteFiles: Bool = false) async throws {
        _ = try await requestData(path: "api/items/batch/delete" + (deleteFiles ? "?hard=1" : ""), method: "POST", body: JSONEncoder().encode(AdminItemIDs(libraryItemIds: ids)))
    }
    public func setItemCover(id: String, remoteURL: String) async throws -> CoverUpdateResult {
        try await postJSON(path: "api/items/\(FeaturePath.id(id))/cover", body: AdminCoverURL(url: remoteURL))
    }
    public func selectItemCover(id: String, serverPath: String) async throws -> CoverUpdateResult {
        try await adminJSON(path: "api/items/\(FeaturePath.id(id))/cover", method: "PATCH", body: AdminCoverPath(cover: serverPath))
    }
    public func deleteItemCover(id: String) async throws { _ = try await requestData(path: "api/items/\(FeaturePath.id(id))/cover", method: "DELETE") }
    public func matchItem(id: String, options: MatchItemOptions) async throws -> ItemMatchResult {
        try await postJSON(path: "api/items/\(FeaturePath.id(id))/match", body: options)
    }
    public func matchItems(ids: [String], options: MatchItemOptions) async throws {
        _ = try await requestData(path: "api/items/batch/quickmatch", method: "POST", body: JSONEncoder().encode(AdminBatchMatch(libraryItemIds: ids, options: options)))
    }
    /// The complete ordered list is required. ABS assigns one-based indexes to non-excluded files.
    public func updateAudioTrackOrder(itemID: String, files: [OrderedAudioFile]) async throws -> LibraryItem {
        try await adminJSON(path: "api/items/\(FeaturePath.id(itemID))/tracks", method: "PATCH", body: AdminTrackOrder(orderedFileData: files))
    }
    public func updateChapters(itemID: String, chapters: [Chapter]) async throws -> ChapterUpdateResult {
        try await postJSON(path: "api/items/\(FeaturePath.id(itemID))/chapters", body: AdminChapters(chapters: chapters))
    }
    public func scanItem(id: String) async throws -> ItemScanResult {
        try await postJSON(path: "api/items/\(FeaturePath.id(id))/scan", body: EmptyPayload())
    }
    public func scanItems(ids: [String]) async throws {
        _ = try await requestData(path: "api/items/batch/scan", method: "POST", body: JSONEncoder().encode(AdminItemIDs(libraryItemIds: ids)))
    }
    public func embeddedMetadata(itemID: String) async throws -> EmbeddedMetadata { try await getJSON(path: "api/items/\(FeaturePath.id(itemID))/metadata-object") }
    public func probeMediaFile(itemID: String, fileID: String) async throws -> ABSDiagnosticValue { try await getJSON(path: "api/items/\(FeaturePath.id(itemID))/ffprobe/\(FeaturePath.id(fileID))") }
    public func deleteMediaFile(itemID: String, fileID: String) async throws { _ = try await requestData(path: "api/items/\(FeaturePath.id(itemID))/file/\(FeaturePath.id(fileID))", method: "DELETE") }
    public func managedItemFiles(id: String) async throws -> [ManagedLibraryFile] {
        let response: ManagedItemFilesResponse = try await getJSON(path: "api/items/\(FeaturePath.id(id))?expanded=1")
        return response.libraryFiles
    }
    /// This server endpoint toggles primary/supplementary status; it does not accept a desired boolean.
    public func toggleEBookSupplementary(itemID: String, fileID: String) async throws { _ = try await requestData(path: "api/items/\(FeaturePath.id(itemID))/ebook/\(FeaturePath.id(fileID))/status", method: "PATCH") }
    public func encodeM4B(itemID: String, options: M4BEncodeOptions = .init()) async throws {
        let query = [URLQueryItem(name: "codec", value: options.codec), URLQueryItem(name: "channels", value: options.channels), URLQueryItem(name: "bitrate", value: options.bitrate)].filter { $0.value != nil }
        _ = try await requestData(path: FeaturePath.query("api/tools/item/\(FeaturePath.id(itemID))/encode-m4b", query), method: "POST")
    }
    public func cancelM4BEncoding(itemID: String) async throws { _ = try await requestData(path: "api/tools/item/\(FeaturePath.id(itemID))/encode-m4b", method: "DELETE") }
    public func embedItemMetadata(itemID: String, forceChapters: Bool = false, backup: Bool = false) async throws {
        _ = try await requestData(path: FeaturePath.query("api/tools/item/\(FeaturePath.id(itemID))/embed-metadata", embedQuery(forceChapters, backup)), method: "POST")
    }
    public func embedItemsMetadata(ids: [String], forceChapters: Bool = false, backup: Bool = false) async throws {
        _ = try await requestData(path: FeaturePath.query("api/tools/batch/embed-metadata", embedQuery(forceChapters, backup)), method: "POST", body: JSONEncoder().encode(AdminItemIDs(libraryItemIds: ids)))
    }
    public func metadataProviders() async throws -> MetadataProviderCatalog {
        if ServerVersion(profile.serverVersion ?? "2.26.0") >= ServerVersion("2.37.1") {
            let response: AdminProvidersResponse = try await getJSON(path: "api/search/providers"); return response.providers
        }
        // /search/providers is absent in the fixed 2.26 router. Its BookFinder exposes this list.
        let names = ["google", "itunes", "openlibrary", "fantlab", "audiobookcovers", "audible", "audible.ca", "audible.uk", "audible.au", "audible.fr", "audible.de", "audible.jp", "audible.it", "audible.in", "audible.es"]
        var catalog = MetadataProviderCatalog(books: names.filter { $0 != "audiobookcovers" }.map { .init(value: $0, text: $0) }, booksCovers: (["best"] + names + ["all"]).map { .init(value: $0, text: $0) }, podcasts: [.init(value: "itunes", text: "iTunes")])
        // Only administrators may enumerate custom-provider credentials.
        if try await currentUser().isAdmin {
            for provider in try await customMetadataProviders() {
                let item = MetadataProvider(value: "custom-" + provider.id, text: provider.name)
                if provider.mediaType == "book" { catalog.books.append(item); catalog.booksCovers.append(item) }
                else if provider.mediaType == "podcast" { catalog.podcasts.append(item) }
            }
        }
        return catalog
    }
    public func searchBookMetadata(_ query: MetadataSearchQuery) async throws -> [MetadataSearchBook] {
        let items = [URLQueryItem(name: "title", value: query.title), URLQueryItem(name: "author", value: query.author), URLQueryItem(name: "provider", value: query.provider), URLQueryItem(name: "id", value: query.itemID)].filter { $0.value != nil }
        return try await getJSON(path: FeaturePath.query("api/search/books", items))
    }
    public func searchCovers(title: String, author: String = "", provider: String = "google", podcast: Bool = false) async throws -> [String] {
        let response: AdminCoverSearchResponse = try await getJSON(path: FeaturePath.query("api/search/covers", [.init(name: "title", value: title), .init(name: "author", value: author), .init(name: "provider", value: provider), .init(name: "podcast", value: podcast ? "1" : "0")]))
        return response.results
    }
    public func searchChapters(asin: String, region: String = "us") async throws -> ChapterSearchResult { try await getJSON(path: FeaturePath.query("api/search/chapters", [.init(name: "asin", value: asin), .init(name: "region", value: region)])) }

    public func managedLibrary(id: String) async throws -> AdminLibrary { try await getJSON(path: "api/libraries/\(FeaturePath.id(id))") }
    public func createLibrary(_ draft: LibraryDraft) async throws -> AdminLibrary { try await postJSON(path: "api/libraries", body: draft) }
    public func updateLibrary(id: String, update: LibraryUpdate) async throws -> AdminLibrary { try await adminJSON(path: "api/libraries/\(FeaturePath.id(id))", method: "PATCH", body: update) }
    public func deleteLibrary(id: String) async throws -> AdminLibrary { let data = try await requestData(path: "api/libraries/\(FeaturePath.id(id))", method: "DELETE"); return try JSONDecoder().decode(AdminLibrary.self, from: data) }
    public func reorderLibraries(_ order: [LibraryOrderEntry]) async throws -> [AdminLibrary] { let response: AdminLibrariesResponse = try await postJSON(path: "api/libraries/order", body: order); return response.libraries }
    public func scanLibrary(id: String, force: Bool = false) async throws { _ = try await requestData(path: "api/libraries/\(FeaturePath.id(id))/scan" + (force ? "?force=1" : ""), method: "POST") }
    public func matchLibrary(id: String) async throws { _ = try await requestData(path: "api/libraries/\(FeaturePath.id(id))/matchall", retryAfterAuthentication: false) }
    public func removeLibraryItemsWithIssues(id: String) async throws { _ = try await requestData(path: "api/libraries/\(FeaturePath.id(id))/issues", method: "DELETE") }
    public func removeLibraryMetadataFiles(id: String) async throws { _ = try await requestData(path: "api/libraries/\(FeaturePath.id(id))/remove-metadata", method: "POST") }
    public func removeLibraryMetadataFiles(id: String, kind: LibraryMetadataFileKind) async throws -> MetadataFileRemovalResult {
        try JSONDecoder().decode(MetadataFileRemovalResult.self, from: await requestData(path: "api/libraries/\(FeaturePath.id(id))/remove-metadata?ext=\(kind.rawValue)", method: "POST"))
    }
    public func libraryItemsWithIssues(id: String, page: Int = 0, limit: Int = 60) async throws -> ItemPage {
        try await getJSON(path: FeaturePath.page("api/libraries/\(FeaturePath.id(id))/items", page: page, limit: limit, extra: [.init(name: "filter", value: "issues"), .init(name: "minified", value: "0")]))
    }
    public func serverDirectories(path: String? = nil, level: Int = 0) async throws -> ServerDirectories {
        try await getJSON(path: FeaturePath.query("api/filesystem", [.init(name: "path", value: path), .init(name: "level", value: String(max(0, level)))].filter { $0.value != nil }))
    }
    public func serverDirectoryExists(directory: String, folderPath: String) async throws -> ServerPathCheck {
        try await postJSON(path: "api/filesystem/pathexists", body: AdminPathCheck(directory: directory, folderPath: folderPath))
    }
    func adminJSON<Body: Encodable & Sendable, Response: Decodable & Sendable>(path: String, method: String, body: Body) async throws -> Response { try JSONDecoder().decode(Response.self, from: await requestData(path: path, method: method, body: JSONEncoder().encode(body))) }
    private func embedQuery(_ force: Bool, _ backup: Bool) -> [URLQueryItem] { [.init(name: "forceEmbedChapters", value: force ? "1" : "0"), .init(name: "backup", value: backup ? "1" : "0")] }
}
struct AdminItemIDs: Codable, Sendable { let libraryItemIds: [String] }
private struct AdminItemsResponse: Decodable, Sendable { let libraryItems: [LibraryItem] }
private struct AdminLibrariesResponse: Decodable, Sendable { let libraries: [AdminLibrary] }
private struct AdminCoverURL: Encodable, Sendable { let url: String }
private struct AdminCoverPath: Encodable, Sendable { let cover: String }
private struct AdminTrackOrder: Encodable, Sendable { let orderedFileData: [OrderedAudioFile] }
private struct AdminChapters: Encodable, Sendable { let chapters: [Chapter] }
private struct AdminBatchMatch: Encodable, Sendable { let libraryItemIds: [String]; let options: MatchItemOptions }
private struct AdminProvidersResponse: Decodable, Sendable { let providers: MetadataProviderCatalog }
private struct AdminCoverSearchResponse: Decodable, Sendable { let results: [String] }
private struct AdminPathCheck: Encodable, Sendable { let directory: String; let folderPath: String }
private struct ManagedItemFilesResponse: Decodable, Sendable { let libraryFiles: [ManagedLibraryFile] }
