import Foundation
import Testing
@testable import ShelfCore

private final class PersonalHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> Data) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    func respond(_ request: URLRequest) throws -> Data { lock.lock(); let handler = handler; lock.unlock(); guard let handler else { throw URLError(.badServerResponse) }; return try handler(request) }
}
private final class PersonalHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = PersonalHTTPState()
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
private func personalBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
private func personalClient() async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PersonalHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Fixture", baseURL: URL(string: "https://fixture.test/abs")!, username: "reader", serverVersion: "2.37.1"), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: "u1"), account: client.tokenAccount)
    return client
}

@Suite(.serialized) struct PersonalFeatureTests {
    @Test func expandedItemHasPublicationStateBesideMedia() async throws {
        PersonalHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/items/book id")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(.init(name: "expanded", value: "1")))
            #expect(query.contains(.init(name: "include", value: "rssfeed,share")))
            return Data(#"{"id":"book id","libraryId":"lib","mediaType":"book","media":{"id":"internal-book","metadata":{"title":"样书"}},"rssFeed":{"id":"feed-uuid","entityType":"libraryItem","entityId":"book id","feedUrl":"/feed/private-rss","meta":{"preventIndexing":true}},"mediaItemShare":{"id":"share-uuid","mediaItemId":"internal-book","mediaItemType":"book","slug":"private-share","expiresAt":null,"isDownloadable":false}}"#.utf8)
        }
        let result = try await personalClient().itemPersonalDetails(id: "book id")
        #expect(result.item.id == "book id")
        #expect(result.item.media.id == result.mediaItemShare?.mediaItemId)
        #expect(result.rssFeed?.entityType == "libraryItem")
        #expect(result.mediaItemShare?.expiresAt == nil)
    }
    @Test func publicationLinksKeepProxyPathWithoutCredentialsOrTokens() throws {
        let profile = ServerProfile(name: "Fixture", baseURL: URL(string: "https://fixture.test:8443/abs/?discard=1")!, username: "reader")
        #expect(try PersonalPublicationLinks.origin(profile: profile) == "https://fixture.test:8443")
        let feed = try JSONDecoder().decode(RSSFeed.self, from: Data(#"{"id":"feed-uuid","feedUrl":"/feed/opaque-rss"}"#.utf8))
        let rss = try PersonalPublicationLinks.rss(feed: feed, profile: profile)
        let share = try PersonalPublicationLinks.share(slug: "opaque-share", profile: profile)
        #expect(rss.absoluteString == "https://fixture.test:8443/abs/feed/opaque-rss")
        #expect(share.absoluteString == "https://fixture.test:8443/abs/share/opaque-share")
        #expect(rss.query == nil && share.query == nil)
        #expect(throws: (any Error).self) { try PersonalPublicationLinks.share(slug: "../../admin?token=x", profile: profile) }
        let foreign = try JSONDecoder().decode(RSSFeed.self, from: Data(#"{"id":"foreign","feedUrl":"https://outside.test/feed/a"}"#.utf8))
        #expect(throws: (any Error).self) { try PersonalPublicationLinks.rss(feed: foreign, profile: profile) }
    }
    @Test func personalDevicePayloadContainsOnlyCurrentUsersDevices() async throws {
        let devices = [EReaderDevice(name: "我的阅读器", email: "reader@example.test", userID: "u1")]
        try PersonalPublicationLinks.validatePersonalDevices(devices, userID: "u1")
        PersonalHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "POST" && request.url?.path == "/abs/api/me/ereader-devices")
            let object = try #require(JSONSerialization.jsonObject(with: personalBody(request)) as? [String: Any])
            let records = try #require(object["ereaderDevices"] as? [[String: Any]])
            #expect(records.count == 1)
            #expect(records.first?["availabilityOption"] as? String == "specificUsers")
            #expect(records.first?["users"] as? [String] == ["u1"])
            return Data(#"{"ereaderDevices":[{"name":"我的阅读器","email":"reader@example.test","availabilityOption":"specificUsers","users":["u1"]},{"name":"共享阅读器","email":"shared@example.test","availabilityOption":"userOrUp","users":[]}]}"#.utf8)
        }
        let result = try await personalClient().updateEReaderDevices(devices)
        #expect(result.count == 2)
        #expect(result.last?.availabilityOption == "userOrUp")
        #expect(throws: (any Error).self) { try PersonalPublicationLinks.validatePersonalDevices([.init(name: "其他账户", email: "a@example.test", userID: "u2")], userID: "u1") }
        #expect(throws: (any Error).self) { try PersonalPublicationLinks.validatePersonalDevices(devices + devices, userID: "u1") }
    }
    @Test func ebookSendingUsesLibraryItemAndAccessibleDeviceName() async throws {
        PersonalHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/api/emails/send-ebook-to-device")
            #expect(request.httpMethod == "POST")
            let object = try #require(JSONSerialization.jsonObject(with: personalBody(request)) as? [String: String])
            #expect(object == ["libraryItemId": "library-book", "deviceName": "我的阅读器"])
            return Data("OK".utf8)
        }
        try await personalClient().sendEBook(itemID: "library-book", deviceName: "我的阅读器")
    }
    @Test func partialLocalPreferencesRetainDefaults() throws {
        let value = try JSONDecoder().decode(ClientPreferences.self, from: Data(#"{"useChapterTrack":true,"jumpForwardAmount":60}"#.utf8))
        #expect(value.useChapterTrack && value.jumpForwardAmount == 60)
        #expect(value.jumpBackwardAmount == 15 && value.playbackRate == 1)
        #expect(value.playbackRateIncrementDecrement == 0.1)
        #expect(try JSONDecoder().decode(ClientPreferences.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test func personalCapabilitiesHonorFinePermissionsActivityAndVersion() {
        var user = UserAccount(id: "u1", username: "reader")
        #expect(!PersonalCapabilities(user: user, version: "2.37.1").canPublish)
        #expect(!PersonalCapabilities(user: user, version: "2.37.1").canManageReaderDevices)
        user.permissions.createEreader = true
        #expect(PersonalCapabilities(user: user, version: "2.26.0").canManageReaderDevices)
        user.type = "admin"
        #expect(PersonalCapabilities(user: user, version: "2.37.1").canPublish)
        #expect(!PersonalCapabilities(user: user, version: "2.25.0").isSupported)
        user.isActive = false
        #expect(!PersonalCapabilities(user: user, version: "2.37.1").canPublish)
        #expect(!PersonalCapabilities(user: user, version: "2.37.1").canChangePassword)
        user.isActive = true; user.type = "guest"
        #expect(!PersonalCapabilities(user: user, version: "2.37.1").canChangePassword)
    }
}

@Suite struct RSSFeedDetailsTests {
    @Test func officialFeedDetailsPreserveTitlesAndMillisecondTimestamp() throws {
        // Both fixed 2.26 and 2.37 Feed.toOldJSON/getOldEpisode expose these fields.
        let data = Data(#"{"id":"feed","entityType":"libraryItem","entityId":"book","feedUrl":"/feed/synthetic","updatedAt":1720000000123,"episodes":[{"id":"ep1","title":"第一章","pubDate":"Mon, 01 Jul 2024 00:00:00 GMT","enclosure":{"url":"/feed/track/1"},"futureField":true},{"id":"ep2","title":"Second chapter","pubDate":null}],"futureFeedField":{}}"#.utf8)
        let feed = try JSONDecoder().decode(RSSFeed.self, from: data)
        #expect(feed.updatedAt == 1_720_000_000_123)
        #expect(feed.episodes?.map(\.title) == ["第一章", "Second chapter"])
        #expect(feed.episodes?.first?.pubDate == "Mon, 01 Jul 2024 00:00:00 GMT")
        #expect(feed.episodes?.last?.pubDate == nil)
    }
    @Test func absentOrNullEntryListsAreNotAnExplicitEmptyFeed() throws {
        for suffix in ["", #", "episodes":null, "updatedAt":null"#] {
            let data = Data((#"{"id":"feed","feedUrl":"/feed/synthetic""# + suffix + "}").utf8)
            let feed = try JSONDecoder().decode(RSSFeed.self, from: data)
            #expect(feed.episodes == nil && feed.updatedAt == nil)
        }
        let empty = try JSONDecoder().decode(RSSFeed.self, from: Data(#"{"id":"feed","feedUrl":"/feed/synthetic","episodes":[]}"#.utf8))
        #expect(empty.episodes != nil && empty.episodes?.isEmpty == true)
    }
    @Test func sparseEntriesAndLargeListsPreserveEveryTitle() throws {
        let entries = (0..<2_114).map { ["id": "ep\($0)", "title": "Chapter \($0)"] }
        let data = try JSONSerialization.data(withJSONObject: ["id": "feed", "feedUrl": "/feed/synthetic", "episodes": entries])
        let feed = try JSONDecoder().decode(RSSFeed.self, from: data)
        #expect(feed.episodes?.count == 2_114)
        #expect(feed.episodes?.last?.title == "Chapter 2113")
        let sparse = try JSONDecoder().decode(RSSFeedEpisode.self, from: Data("{}".utf8))
        #expect(sparse.id == nil && sparse.title == nil && sparse.pubDate == nil)
    }
}
