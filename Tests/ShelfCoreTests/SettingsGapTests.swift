import Foundation
import Testing
@testable import ShelfCore

private final class SettingsGapHTTP: URLProtocol, @unchecked Sendable {
    static let state = SettingsGapResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class SettingsGapResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func install(_ value: @escaping @Sendable (URLRequest) throws -> Data) { lock.withLock { handler = value } }
    func respond(_ request: URLRequest) throws -> Data {
        let handler = lock.withLock { handler }
        return try handler!(request)
    }
}
private func settingsGapBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&bytes, maxLength: bytes.count)
        guard count > 0 else { break }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}

@Suite(.serialized) struct SettingsGapTests {
    @Test(arguments: [nil, "", "episodic", "serial", "future-type"] as [String?])
    func itemMetadataPreservesPodcastTypeAndOldCaches(type: String?) throws {
        var source: [String: Any] = ["title": "Synthetic podcast"]
        if let type { source["type"] = type }
        let decoded = try JSONDecoder().decode(ItemMetadata.self, from: JSONSerialization.data(withJSONObject: source))
        #expect(decoded.type == type)
        let roundTrip = try JSONDecoder().decode(ItemMetadata.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
        #expect(ItemMetadata(title: "Synthetic podcast", type: type).type == type)
        let legacyNull = try JSONDecoder().decode(ItemMetadata.self, from: Data(#"{"title":"Synthetic podcast","type":null}"#.utf8))
        #expect(legacyNull.type == nil)
    }

    @Test(arguments: [nil, "episodic", "serial", "future-type", ""] as [String?])
    func subscriptionExplicitTypeWinsWithoutChangingDirectoryInput(override: String?) throws {
        let directory = try JSONDecoder().decode(PodcastDirectoryResult.self, from: Data(#"{"id":"directory","title":"Directory title","type":"serial","feedUrl":"https://rss.fixture.test/feed"}"#.utf8))
        let feed = PodcastFeedMetadata(title: "Feed title", feedUrl: "https://rss.fixture.test/feed", type: "episodic")
        let draft = PodcastSubscriptionDraft(libraryId: "library", folderId: "folder", path: "/podcasts/synthetic", metadata: feed, directoryResult: directory, typeOverride: override)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let media = try #require(json["media"] as? [String: Any])
        let metadata = try #require(media["metadata"] as? [String: Any])
        #expect(metadata["type"] as? String == (override ?? "serial"))
        #expect(metadata["title"] as? String == "Directory title")
        #expect(metadata["itunesId"] as? String == "directory")
        #expect(metadata["feedUrl"] as? String == "https://rss.fixture.test/feed")
        #expect(media["directoryResult"] == nil && media["typeOverride"] == nil && json["typeOverride"] == nil)
        #expect(directory.type == "serial" && feed.type == "episodic")
    }

    @Test func subscriptionRetainsLegacyFeedFallbackAndDefault() throws {
        for type in [nil, "future-type"] as [String?] {
            let draft = PodcastSubscriptionDraft(libraryId: "library", folderId: "folder", path: "/podcasts/synthetic", metadata: .init(title: "Synthetic", type: type))
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            let media = try #require(json["media"] as? [String: Any])
            let metadata = try #require(media["metadata"] as? [String: Any])
            #expect(metadata["type"] as? String == (type ?? "episodic"))
        }
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func podcastMetadataUsesSparseExistingMediaRoute(version: String) async throws {
        SettingsGapHTTP.state.install { request in
            #expect(request.url?.host == "settings-gap.fixture.test")
            #expect(request.url?.path == "/abs/api/items/podcast/media")
            #expect(request.httpMethod == "PATCH")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-settings")
            let object = try #require(JSONSerialization.jsonObject(with: settingsGapBody(request)) as? [String: Any])
            #expect(Set(object.keys) == ["metadata"])
            let metadata = try #require(object["metadata"] as? [String: Any])
            #expect(Set(metadata.keys) == ["type"])
            #expect(metadata["type"] as? String == "serial")
            return Data(#"{"updated":true,"libraryItem":{"id":"podcast","libraryId":"library","mediaType":"podcast","media":{"metadata":{"title":"Synthetic podcast","type":"serial"}}}}"#.utf8)
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SettingsGapHTTP.self]
        let tokens = MemoryTokenStore()
        let client = ABSClient(profile: .init(name: "Synthetic settings", baseURL: URL(string: "https://settings-gap.fixture.test/abs")!, serverVersion: version), session: URLSession(configuration: config), tokenStore: tokens)
        await tokens.save(.init(accessToken: "synthetic-settings", userID: "actor"), account: client.tokenAccount)
        var metadata = MetadataUpdate(); metadata.type = "serial"
        let result = try await client.updateItemMedia(id: "podcast", update: .init(metadata: metadata))
        #expect(result.updated && result.libraryItem.media.metadata.type == "serial")
    }

    @Test func backupValidationAllowsUnlimitedSizeAndRejectsInvalidBounds() {
        #expect(ServerSettingsValidation.validBackup(maximumSizeGB: 0, retainedCount: 1))
        #expect(ServerSettingsValidation.validBackup(maximumSizeGB: 0.25, retainedCount: 99))
        #expect(ServerSettingsValidation.validBackup(maximumSizeGB: Double.greatestFiniteMagnitude, retainedCount: 2))
        for size in [-1, -.infinity, .infinity, .nan] as [Double] {
            #expect(!ServerSettingsValidation.validBackup(maximumSizeGB: size, retainedCount: 2))
        }
        for count in [Int.min, 0, 100, Int.max] {
            #expect(!ServerSettingsValidation.validBackup(maximumSizeGB: 1, retainedCount: count))
        }
    }

    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func unchangedMetadataResponseOmitsUpdatedButMalformedPresentValueFails(version: String) async throws {
        let item: [String: Any] = ["id": "podcast", "libraryId": "library", "mediaType": "podcast", "media": ["metadata": ["title": "Synthetic podcast", "type": "serial"]]]
        let unchanged = try JSONSerialization.data(withJSONObject: ["libraryItem": item])
        SettingsGapHTTP.state.install { request in
            #expect(request.url?.host == "settings-gap.fixture.test")
            #expect(request.url?.path == "/abs/api/items/podcast/media" && request.httpMethod == "PATCH")
            let object = try #require(JSONSerialization.jsonObject(with: settingsGapBody(request)) as? [String: Any])
            let metadata = try #require(object["metadata"] as? [String: Any])
            #expect(metadata["type"] as? String == "serial")
            return unchanged
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SettingsGapHTTP.self]
        let tokens = MemoryTokenStore()
        let client = ABSClient(profile: .init(name: "Synthetic settings", baseURL: URL(string: "https://settings-gap.fixture.test/abs")!, serverVersion: version), session: URLSession(configuration: config), tokenStore: tokens)
        await tokens.save(.init(accessToken: "synthetic-settings", userID: "actor"), account: client.tokenAccount)
        var metadata = MetadataUpdate(); metadata.type = "serial"
        let result = try await client.updateItemMedia(id: "podcast", update: .init(metadata: metadata))
        #expect(!result.updated && result.libraryItem.media.metadata.type == "serial")
        for invalid in ["false", 0, NSNull(), [false]] as [Any] {
            let malformed = try JSONSerialization.data(withJSONObject: ["updated": invalid, "libraryItem": item])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(ItemMediaUpdateResult.self, from: malformed) }
        }
    }

    @Test func notificationInputsHaveNoArbitraryPresetMaximum() throws {
        for (text, expected) in [("101", 101), ("1001", 1001), (" 1000000 \n", 1_000_000), (String(Int.max), Int.max), ("1", 1)] {
            #expect(ServerSettingsValidation.positiveInteger(text) == expected)
        }
        for text in ["", " ", "0", "-1", "1.5", "1e3", "nan", "inf", String(Int.max) + "0"] {
            #expect(ServerSettingsValidation.positiveInteger(text) == nil)
        }
        let value = NotificationSettingsUpdate(appriseApiUrl: "", maxFailedAttempts: 101, maxNotificationQueue: 1001)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(json["maxFailedAttempts"] as? Int == 101)
        #expect(json["maxNotificationQueue"] as? Int == 1001)
    }
}
