import Foundation
import Testing
@testable import ShelfCore

private final class PodcastHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> Data) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler
    }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); let handler = handler; lock.unlock()
        return try handler!(request)
    }
}
private final class PodcastHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = PodcastHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func podcastData(_ value: String) -> Data { Data(value.utf8) }
private func podcastBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }; data.append(contentsOf: buffer.prefix(count))
    }
    return data
}
private func podcastClient(serverVersion: String = "2.37.1") async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PodcastHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Podcast fixture", baseURL: URL(string: "https://fixture.test/abs")!, username: "reader", serverVersion: serverVersion), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture-access", userID: "reader"), account: client.tokenAccount)
    return client
}
private let podcastItemJSON = #"{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"节目"}}}"#
private let episodeDetailsJSON = #"{"id":"episode","libraryItemId":"podcast","title":"第一集","subtitle":"简介","season":"2","episode":"8","episodeType":"bonus","pubDate":"Mon, 12 Oct 2026 00:00:00 +0000","publishedAt":1791763200000,"enclosure":{"url":"https://rss.test/episode.mp3","type":"audio/mpeg","length":1234},"chapters":[{"id":1,"title":"开场","start":0,"end":30}],"duration":60,"audioFile":{"ino":"file","duration":60}}"#

@Suite(.serialized) struct PodcastFeatureTests {
    @Test func libraryQueueReadsUseDistinctNonSensitiveFreshnessKeys() async throws {
        PodcastHTTPProtocol.state.install { request in
            let url = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            #expect(url.path == "/abs/api/libraries/library/episode-downloads")
            #expect(request.httpMethod == "GET")
            let query = try #require(url.queryItems)
            #expect(query.count == 1)
            #expect(query.first?.name == "_queueRefresh")
            let nonce = try #require(query.first?.value)
            #expect(UUID(uuidString: nonce) != nil)
            return podcastData("{\"queue\":[{\"id\":\"\(nonce)\",\"isFinished\":false,\"failed\":false}]}")
        }
        let client = await podcastClient()
        let first = try await client.podcastLibraryDownloadQueue(libraryID: "library")
        let second = try await client.podcastLibraryDownloadQueue(libraryID: "library")
        #expect(first.queue.first?.id != second.queue.first?.id)
    }

    @Test func settingsDateAndUnlimitedLimitsUseReleaseWireValues() async throws {
        let update = PodcastSettingsUpdate(maxEpisodesToKeep: 100_001, maxNewEpisodesToDownload: 0, lastEpisodeCheck: 1_700_000_000_123)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(wire["lastEpisodeCheck"] as? Double == 1_700_000_000_123)
        #expect(wire["maxNewEpisodesToDownload"] as? Int == 0)
        #expect(wire["maxEpisodesToKeep"] as? Int == 100_001)
        #expect(wire["autoDownloadEpisodes"] == nil)
        let omitted = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PodcastSettingsUpdate())) as? [String: Any])
        #expect(omitted["lastEpisodeCheck"] == nil)
        PodcastHTTPProtocol.state.install { request in
            #expect(request.url?.query == "limit=0")
            return podcastData(#"{"episodes":[]}"#)
        }
        #expect(try await podcastClient().checkNewPodcastEpisodes(itemID: "podcast", limit: 0).isEmpty)
    }

    @Test(arguments: [("", nil as String?), (",\"settings\":null", nil), (",\"settings\":{}", nil), (",\"settings\":{\"podcastSearchRegion\":null}", nil), (",\"settings\":{\"podcastSearchRegion\":\"\"}", ""), (",\"settings\":{\"podcastSearchRegion\":\"cn\"}", "cn"), (",\"settings\":{\"podcastSearchRegion\":\"zz\"}", "zz")])
    func libraryDetailsPreserveOptionalDirectoryRegion(settingsJSON: String, expected: String?) throws {
        let data = podcastData("{\"id\":\"library\",\"name\":\"Podcasts\",\"mediaType\":\"podcast\",\"folders\":[]\(settingsJSON)}")
        let details = try JSONDecoder().decode(LibraryDetails.self, from: data)
        #expect(details.settings?.podcastSearchRegion == expected)
        let roundTrip = try JSONDecoder().decode(LibraryDetails.self, from: JSONEncoder().encode(details))
        #expect(roundTrip == details)
        let initialized = LibraryDetails(id: details.id, name: details.name, mediaType: details.mediaType, folders: details.folders, settings: details.settings)
        #expect(initialized == details)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(details)) as? [String: Any])
        #expect(wire["podcastSearchRegion"] == nil)
        if let expected { #expect((wire["settings"] as? [String: Any])?["podcastSearchRegion"] as? String == expected) }
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func directoryRegionComesFromLibraryDetailsAcrossSupportedReleases(version: String) async throws {
        PodcastHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            if components.path == "/abs/api/libraries/library" {
                #expect(components.queryItems == nil)
                return podcastData(#"{"id":"library","name":"Podcasts","mediaType":"podcast","folders":[],"settings":{"podcastSearchRegion":"cn","coverAspectRatio":1}}"#)
            }
            #expect(components.path == "/abs/api/search/podcast")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query == ["term": "C++ 与历史", "country": "cn"])
            #expect(query["libraryId"] == nil)
            return podcastData("[]")
        }
        let client = await podcastClient(serverVersion: version)
        let details = try await client.libraryDetails(id: "library")
        let country = try #require(details.settings?.podcastSearchRegion)
        #expect(try await client.searchPodcastDirectory(term: "C++ 与历史", country: country).isEmpty)
    }

    @Test func malformedLibraryRegionDoesNotBecomeSilentUSFallback() throws {
        for settings in ["true", "{\"podcastSearchRegion\":42}"] {
            let data = podcastData("{\"id\":\"library\",\"name\":\"Podcasts\",\"mediaType\":\"podcast\",\"folders\":[],\"settings\":\(settings)}")
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(LibraryDetails.self, from: data) }
        }
    }

    @Test(arguments: [("no", false), ("false", false), ("yes", true), ("true", true), ("YES", true)])
    func subscriptionConvertsRSSExplicitAndCategories(explicit: String, expected: Bool) throws {
        var metadata = PodcastFeedMetadata(title: "节目", categories: ["Arts", "Books"])
        metadata.explicit = explicit
        let draft = PodcastSubscriptionDraft(libraryId: "library", folderId: "folder", path: "/podcasts/show", metadata: metadata)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let media = try #require(json["media"] as? [String: Any]), wire = try #require(media["metadata"] as? [String: Any])
        #expect(wire["explicit"] as? Bool == expected)
        #expect(wire["genres"] as? [String] == ["Arts", "Books"])
        #expect(wire["categories"] == nil); #expect(media["directoryResult"] == nil)
    }

    @Test func directoryMetadataPreservesIDsAndCanonicalFeedURL() throws {
        let directory = try JSONDecoder().decode(PodcastDirectoryResult.self, from: podcastData(#"{"id":1234567890,"title":"目录标题","artistName":"目录作者","artistId":987654321,"feedUrl":"HTTPS://RSS.TEST/feed","genres":["History"],"explicit":true,"pageUrl":"https://directory.test/podcast","cover":"https://rss.test/cover.jpg"}"#))
        #expect(directory.id == "1234567890"); #expect(directory.artistId == "987654321")
        let metadata = PodcastFeedMetadata(title: "RSS 标题", feedUrl: "https://rss.test/feed", categories: ["News"])
        let draft = PodcastSubscriptionDraft(libraryId: "library", folderId: "folder", path: "/podcasts/show", metadata: metadata, directoryResult: directory)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let media = try #require(json["media"] as? [String: Any]), wire = try #require(media["metadata"] as? [String: Any])
        #expect(wire["title"] as? String == "目录标题"); #expect(wire["itunesId"] as? String == "1234567890")
        #expect(wire["itunesArtistId"] as? String == "987654321"); #expect(wire["explicit"] as? Bool == true)
        #expect(wire["genres"] as? [String] == ["History"]); #expect(wire["feedUrl"] as? String == "https://rss.test/feed")
    }

    @Test func directorySearchAndExistingTitlesUseReleaseRoutes() async throws {
        PodcastHTTPProtocol.state.install { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            if components.path == "/abs/api/search/podcast" {
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                #expect(query == ["term": "C++ 与历史", "country": "cn"])
                #expect(request.url!.absoluteString.contains("C%2B%2B"))
                return podcastData(#"[{"id":42,"artistId":24,"title":"节目","feedUrl":"https://rss.test/feed","genres":[],"trackCount":8,"explicit":false}]"#)
            }
            #expect(components.path == "/abs/api/libraries/library/podcast-titles")
            return podcastData(#"{"podcasts":[{"title":"节目","itunesId":"42","libraryItemId":"podcast","libraryId":"library"}]}"#)
        }
        let client = await podcastClient()
        let results = try await client.searchPodcastDirectory(term: "C++ 与历史", country: "cn")
        #expect(results.first?.id == "42"); #expect(results.first?.trackCount == 8)
        #expect(try await client.existingPodcasts(libraryID: "library").first?.libraryItemId == "podcast")
    }

    @Test func recentEpisodesDecodeFlatRecordsAndStringPagination() async throws {
        PodcastHTTPProtocol.state.install { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            #expect(components.path == "/abs/api/libraries/library/recent-episodes")
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(query == ["page": "0", "limit": "100"])
            let record = String(episodeDetailsJSON.dropLast()) + #", "libraryId":"library","podcast":{"metadata":{"title":"节目"}}}"#
            return podcastData("{\"episodes\":[\(record)],\"limit\":\"100\",\"page\":\"0\"}")
        }
        let page = try await podcastClient().recentPodcastEpisodes(libraryID: "library", page: -5, limit: 1000)
        #expect(page.page == 0); #expect(page.limit == 100); #expect(!page.hasMore)
        #expect(page.episodes.first?.podcast.metadata.title == "节目")
        #expect(page.episodes.first?.details.episodeNumber == "8")
    }

    @Test func downloadQueueAllowsOmittedCurrentAndEpisodeDetailsPreserveMetadata() async throws {
        PodcastHTTPProtocol.state.install { request in
            if request.url?.path == "/abs/api/libraries/library/episode-downloads" {
                return podcastData(#"{"queue":[{"id":"download","episodeDisplayTitle":"第一集","libraryItemId":"podcast","podcastTitle":"节目","isFinished":false,"failed":false}]}"#)
            }
            #expect(request.url?.path == "/abs/api/podcasts/podcast/episode/episode")
            return podcastData(episodeDetailsJSON)
        }
        let client = await podcastClient(), queue = try await client.podcastLibraryDownloadQueue(libraryID: "library")
        #expect(queue.currentDownload == nil); #expect(queue.queue.first?.libraryItemId == "podcast")
        let episode = try await client.podcastEpisodeDetails(itemID: "podcast", episodeID: "episode")
        #expect(episode.season == "2"); #expect(episode.episodeType == "bonus")
        #expect(episode.enclosure?.length == "1234"); #expect(episode.chapters.first?.end == 30)
        #expect(episode.base.duration == 60)
    }

    @Test func matchingUpdateChangesOnlyRSSMetadata() async throws {
        let match = try JSONDecoder().decode(PodcastFeedEpisode.self, from: podcastData(#"{"title":"RSS 标题","season":"3","episode":"9","episodeType":"full","pubDate":"date","publishedAt":123456,"enclosure":{"url":"https://rss.test/new.mp3","type":"audio/mpeg","length":"999"},"durationSeconds":70,"chapters":[{"id":1,"title":"new","start":0,"end":70}]}"#))
        PodcastHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "PATCH"); #expect(request.url?.path == "/abs/api/podcasts/podcast/episode/episode")
            let body = try #require(JSONSerialization.jsonObject(with: podcastBody(request)) as? [String: Any])
            #expect(body["season"] as? String == "3"); #expect(body["episode"] as? String == "9")
            #expect(body["publishedAt"] as? Double == 123456)
            #expect((body["enclosure"] as? [String: Any])?["url"] as? String == "https://rss.test/new.mp3")
            #expect(body["duration"] == nil); #expect(body["audioFile"] == nil); #expect(body["chapters"] == nil)
            return podcastData(podcastItemJSON)
        }
        _ = try await podcastClient().updatePodcastEpisode(itemID: "podcast", episodeID: "episode", update: .init(matching: match))
    }

    @Test func finishingEpisodePreservesListeningAndReadingPosition() async throws {
        PodcastHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "PATCH"); #expect(request.url?.path == "/abs/api/me/progress/podcast/episode")
            let body = try #require(JSONSerialization.jsonObject(with: podcastBody(request)) as? [String: Bool])
            #expect(body == ["isFinished": true])
            return Data()
        }
        try await podcastClient().setPodcastEpisodeFinished(itemID: "podcast", episodeID: "episode", isFinished: true)
    }
}
