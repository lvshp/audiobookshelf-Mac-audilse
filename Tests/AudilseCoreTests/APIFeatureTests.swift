import Foundation
import Testing
@testable import AudilseCore

private final class FeatureHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var calls: [String: Int] = [:]
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler; calls = [:] }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); let handler = handler; calls[request.url!.path, default: 0] += 1; lock.unlock()
        return try handler!(request)
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[path, default: 0] }
}
private final class FeatureHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = FeatureHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func featureData(_ string: String) -> Data { Data(string.utf8) }
private func featureBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
private func featureClient(store: MemoryTokenStore = .init(), version: String = "2.37.1") async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FeatureHTTPProtocol.self]
    let client = ABSClient(profile: .init(name: "Fixture", baseURL: URL(string: "https://fixture.test/abs")!, username: "reader", serverVersion: version), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: "u1"), account: client.tokenAccount)
    return client
}
private let featureItem = #"{"id":"library-item","libraryId":"lib","mediaType":"book","media":{"id":"internal-book","metadata":{"title":"一本书","series":{"id":"series","name":"系列","sequence":"1"}}}}"#
private let featurePlaylist = #"{"id":"playlist","libraryId":"lib","name":"收听队列","items":[{"libraryItemId":"podcast","episodeId":"episode","episode":{"id":"episode","title":"单集"}}]}"#

@Suite(.serialized) struct APIFeatureTests {
    @Test func podcastCreationCanLoadServerFolderPaths() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/libraries/podcasts")
            return (200, featureData(#"{"id":"podcasts","name":"播客","mediaType":"podcast","folders":[{"id":"folder","fullPath":"/media/podcasts","libraryId":"podcasts"}]}"#))
        }
        let library = try await featureClient().libraryDetails(id: "podcasts")
        #expect(library.folders.first?.fullPath == "/media/podcasts")
    }
    @Test func authorMutationDecodesWrappedAuthorAndDoesNotClearUneditedFields() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "PATCH"); #expect(request.url?.path == "/abs/api/authors/author")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: String])
            #expect(body == ["description": "新的简介"])
            return (200, featureData(#"{"updated":true,"author":{"id":"author","name":"作者","description":"新的简介"}}"#))
        }
        let author = try await featureClient().updateAuthor(id: "author", update: .init(description: "新的简介"))
        #expect(author.description == "新的简介")
    }
    @Test func authorIncludesGroupedItemsWithSingletonSeriesMetadata() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/authors/author")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "items,series")
            return (200, featureData("{\"id\":\"author\",\"name\":\"作者\",\"libraryItems\":[\(featureItem)],\"series\":[{\"id\":\"series\",\"name\":\"系列\",\"items\":[\(featureItem)]}]}"))
        }
        let author = try await featureClient().author(id: "author")
        #expect(author.libraryItems.first?.media.metadata.series.first?.sequence == "1")
        #expect(author.series.first?.items.first?.title == "一本书")
    }
    @Test func featurePaginationAndEncodedFilterKeepProxyPath() async throws {
        FeatureHTTPProtocol.state.install { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            #expect(components.path == "/abs/api/libraries/lib id/items")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query["filter"] == "authors." + Data("作者/a+".utf8).base64EncodedString())
            #expect(query["page"] == "1"); #expect(query["limit"] == "20")
            #expect(request.url!.absoluteString.contains("lib%20id"))
            #expect(!request.url!.absoluteString.contains("%2520"))
            return (200, featureData(#"{"results":[],"total":41,"page":"1","limit":"20"}"#))
        }
        let page = try await featureClient().items(libraryID: "lib id", authorID: "作者/a+", page: 1, limit: 20)
        #expect(page.hasMore)
    }
    @Test func searchPreservesLiteralPlusCharacters() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url!.absoluteString.contains("C%2B%2B"))
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value == "C++")
            return (200, featureData(#"{"book":[],"podcast":[]}"#))
        }
        _ = try await featureClient().libraryItems(libraryID: "lib", search: "C++")
    }
    @Test func collectionCreationUsesLibraryItemIDsAndExpandedResponse() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "POST"); #expect(request.url?.path == "/abs/api/collections")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            #expect(body["books"] as? [String] == ["library-item"])
            return (200, featureData("{\"id\":\"collection\",\"libraryId\":\"lib\",\"name\":\"珍藏\",\"books\":[\(featureItem)]}"))
        }
        let result = try await featureClient().createCollection(.init(libraryId: "lib", name: "珍藏", books: ["library-item"]))
        #expect(result.books.first?.id == "library-item"); #expect(result.books.first?.media.id == "internal-book")
    }
    @Test func playlistPodcastReferencesUseEpisodeIDs() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/playlists/playlist/batch/add")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            let items = try #require(body["items"] as? [[String: String]])
            #expect(items == [["libraryItemId": "podcast", "episodeId": "episode"]])
            return (200, featureData(featurePlaylist))
        }
        let playlist = try await featureClient().addPlaylistItems(id: "playlist", items: [.init(libraryItemId: "podcast", episodeId: "episode")])
        #expect(playlist.items.first?.episode?.title == "单集")
    }
    @Test func rssOptionsUseNestedMetadataAndWrappedFeedResponse() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/feeds/collection/collection/open")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            let metadata = try #require(body["metadataDetails"] as? [String: Any])
            #expect(metadata["preventIndexing"] as? Bool == true); #expect(metadata["ownerName"] as? String == "Reader")
            #expect(body["ownerName"] == nil)
            return (200, featureData(#"{"feed":{"id":"feed","entityType":"collection","entityId":"collection","feedUrl":"https://fixture.test/feed/private-slug"}}"#))
        }
        let result = try await featureClient().openRSSFeed(entity: .collection, id: "collection", options: .init(serverAddress: "https://fixture.test", slug: "private-slug", ownerName: "Reader"))
        #expect(result.id == "feed")
    }
    @Test func shareUsesInternalMediaIDAndNumericNoExpiry() async throws {
        FeatureHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            #expect(body["mediaItemId"] as? String == "internal-book")
            #expect(body["mediaItemType"] as? String == "book")
            #expect((body["expiresAt"] as? NSNumber)?.doubleValue == 0)
            return (200, featureData(#"{"id":"share","mediaItemId":"internal-book","mediaItemType":"book","slug":"sample","expiresAt":null,"isDownloadable":false}"#))
        }
        let result = try await featureClient().createShare(.init(mediaItemId: "internal-book", mediaItemType: .book, slug: "sample"))
        #expect(result.expiresAt == nil)
    }
    @Test func podcastFeedAndDownloadUseActualRSSShapes() async throws {
        FeatureHTTPProtocol.state.install { request in
            if request.url!.path.hasSuffix("/feed") {
                let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
                #expect(body["rssFeed"] as? String == "https://podcast.test/rss")
                return (200, featureData(#"{"podcast":{"metadata":{"title":"播客","image":"https://podcast.test/cover.png"},"episodes":[{"title":"第一集","guid":"guid","enclosure":{"url":"https://podcast.test/1.mp3","length":12345}}]}}"#))
            }
            #expect(request.url?.path == "/abs/api/podcasts/podcast/download-episodes")
            let episodes = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [[String: Any]])
            #expect(episodes.first?["guid"] as? String == "guid")
            return (200, featureData("OK"))
        }
        let client = await featureClient(); let feed = try await client.podcastFeed(url: "https://podcast.test/rss")
        #expect(feed.episodes.first?.enclosure.length == "12345")
        #expect(feed.numEpisodes == 1)
        try await client.downloadPodcastEpisodes(itemID: "podcast", episodes: feed.episodes)
        let draft = PodcastSubscriptionDraft(libraryId: "lib", folderId: "folder", path: "/podcasts/播客", metadata: feed.metadata)
        #expect(draft.media.metadata.imageUrl == "https://podcast.test/cover.png")
    }
    @Test func podcastSearchUnwrapsEpisodeMatches() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/podcasts/podcast/search-episode")
            return (200, featureData(#"{"episodes":[{"episode":{"title":"第一集","guid":"guid","enclosure":{"url":"https://podcast.test/1.mp3"}}}]}"#))
        }
        let episodes = try await featureClient().searchPodcastEpisodes(itemID: "podcast", title: "第一集")
        #expect(episodes.first?.id == "guid")
    }
    @Test func opmlImportSendsURLArrayAndFolderIdentity() async throws {
        FeatureHTTPProtocol.state.install { request in
            if request.url!.path.hasSuffix("/parse") { return (200, featureData(#"{"feeds":[{"title":"播客","feedUrl":"https://podcast.test/rss"}]}"#)) }
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            #expect(body["feeds"] as? [String] == ["https://podcast.test/rss"])
            #expect(body["libraryId"] as? String == "lib"); #expect(body["folderId"] as? String == "folder")
            return (200, featureData("OK"))
        }
        let client = await featureClient(); let feeds = try await client.parseOPML(text: "<opml/>")
        try await client.importOPML(feedURLs: feeds.map(\.feedUrl), libraryID: "lib", folderID: "folder")
    }
    @Test func podcastSettingsDecodeWrappedLibraryItem() async throws {
        FeatureHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/items/podcast/media"); #expect(request.httpMethod == "PATCH")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: Any])
            #expect(body["maxEpisodesToKeep"] as? Int == 8); #expect(body["metadata"] == nil)
            return (200, featureData(#"{"updated":true,"libraryItem":{"id":"podcast","libraryId":"lib","mediaType":"podcast","media":{"metadata":{"title":"播客"},"maxEpisodesToKeep":8}}}"#))
        }
        let item = try await featureClient().updatePodcastSettings(itemID: "podcast", update: .init(maxEpisodesToKeep: 8))
        #expect(item.media.maxEpisodesToKeep == 8)
    }
    @Test func mutatingPodcastGETRefreshesButNeverReplays() async throws {
        FeatureHTTPProtocol.state.install { request in
            if request.url!.path == "/abs/auth/refresh" { return (200, featureData(#"{"user":{"id":"u1","username":"reader","accessToken":"updated","refreshToken":"updated-refresh"}}"#)) }
            #expect(request.httpMethod == "GET")
            return (401, Data())
        }
        let client = await featureClient()
        do { _ = try await client.checkNewPodcastEpisodes(itemID: "podcast"); Issue.record("Mutating GET must return 401 for explicit retry") }
        catch ABSError.http(status: 401, message: _) {} catch { throw error }
        #expect(FeatureHTTPProtocol.state.count("/abs/api/podcasts/podcast/checknew") == 1)
        #expect(FeatureHTTPProtocol.state.count("/abs/auth/refresh") == 1)
    }
    @Test func historyUsesItemsPerPageAndRetainsDeletedMedia() async throws {
        FeatureHTTPProtocol.state.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.contains(URLQueryItem(name: "itemsPerPage", value: "12")) == true)
            #expect(query?.contains(where: { $0.name == "limit" }) == false)
            return (200, featureData(#"{"total":14,"numPages":2,"page":0,"itemsPerPage":12,"sessions":[{"id":"session","libraryItemId":null,"displayTitle":"已删除的书","timeListening":"73.25","currentTime":"120","duration":3600}]}"#))
        }
        let result = try await featureClient().listeningHistory(limit: 12)
        #expect(result.hasMore); #expect(result.sessions.first?.libraryItemId == nil); #expect(result.sessions.first?.timeListening == 73.25)
    }
    @Test func passwordChangePersistsRotatedJWTWithoutRequiringUserIDInResponse() async throws {
        let store = MemoryTokenStore(); let client = await featureClient(store: store)
        FeatureHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "PATCH"); #expect(request.url?.path == "/abs/api/me/password")
            #expect(request.value(forHTTPHeaderField: "x-refresh-token") == "fixture-refresh")
            let body = try #require(JSONSerialization.jsonObject(with: featureBody(request)) as? [String: String])
            #expect(body == ["password": "fixture-old", "newPassword": "fixture-new"])
            return (200, featureData(#"{"success":true,"user":{"accessToken":"password-access","refreshToken":"password-refresh"}}"#))
        }
        #expect(try await client.changePassword(currentPassword: "fixture-old", newPassword: "fixture-new") == .authenticated)
        #expect(try await client.accessToken() == "password-access")
        let tokens = await store.load(account: client.tokenAccount)
        #expect(tokens?.refreshToken == "password-refresh"); #expect(tokens?.userID == "u1")
    }
}
