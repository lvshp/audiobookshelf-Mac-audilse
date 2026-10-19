import Foundation
import Testing
@testable import AudilseCore

private final class AdminHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    private var calls: [String: Int] = [:]
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler; calls = [:] }
    func respond(_ request: URLRequest) throws -> (Int, Data) { lock.lock(); let handler = handler; calls[request.url!.path, default: 0] += 1; lock.unlock(); return try handler!(request) }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[path, default: 0] }
}
private final class AdminHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = AdminHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
private func adminData(_ string: String) -> Data { Data(string.utf8) }
private func adminBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
private func adminClient(version: String = "2.37.1") async -> ABSClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdminHTTPProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Fixture", baseURL: URL(string: "https://fixture.test/abs")!, serverVersion: version), session: URLSession(configuration: config), tokenStore: store)
    await store.save(.init(accessToken: "fixture-access", refreshToken: "fixture-refresh", userID: "user"), account: client.tokenAccount)
    return client
}
private let adminItemFixture = #"{"id":"book","libraryId":"lib","mediaType":"book","isMissing":true,"isInvalid":false,"libraryFiles":[{"ino":"f","metadata":{"filename":"book.mp3"}}],"media":{"metadata":{"title":"原生测试","isbn":"9780000000000","asin":"B000000001","abridged":false},"audioFiles":[{"ino":"f","exclude":true,"metadata":{"filename":"book.mp3"}}]}}"#
private let adminLibraryFixture = #"{"id":"lib","name":"书库","mediaType":"book","folders":[{"id":"folder","fullPath":"/media/books"}],"settings":{"coverAspectRatio":1,"metadataPrecedence":["folderStructure","absMetadata"],"markAsFinishedTimeRemaining":10,"epubsAllowScriptedContent":false}}"#

@Suite(.serialized) struct AdminAPITests {
    @Test(arguments: ["合成标签 + / B", "ÿÿ", "plain"])
    func taxonomyDeleteUsesStandardUTF8Base64(name: String) async throws {
        let identifier = ServerEndpoint.component(Data(name.utf8).base64EncodedString())
        AdminHTTPProtocol.state.install { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            #expect(request.httpMethod == "DELETE")
            #expect(["/abs/api/tags/" + identifier, "/abs/api/genres/" + identifier].contains(components.percentEncodedPath))
            #expect(components.query == nil)
            return (200, adminData(#"{"numItemsUpdated":1}"#))
        }
        let client = await adminClient()
        #expect(try await client.deleteServerTag(name).numItemsUpdated == 1)
        #expect(try await client.deleteServerGenre(name).numItemsUpdated == 1)
    }

    @Test func newUserUncheckedPermissionsAreExplicitlyDenied() throws {
        var draft = UserDraft(username: "restricted", password: "fixture-password", type: .admin)
        draft.permissions = .restrictedCreationDefaults
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        let permissions = try #require(body["permissions"] as? [String: Bool])
        #expect(Set(permissions.keys) == ["download", "update", "delete", "upload", "createEreader", "accessAllLibraries", "accessAllTags", "accessExplicitContent", "selectedTagsNotAccessible"])
        #expect(permissions.values.allSatisfy { !$0 })
    }
    @Test func sparseMetadataPatchDoesNotEraseUneditedFieldsAndUsesWrappedResult() async throws {
        AdminHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "PATCH"); #expect(request.url?.path == "/abs/api/items/book/media")
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: Any])
            #expect(Set(body.keys) == ["metadata"])
            #expect(body["metadata"] as? [String: String] == ["title": "新标题"])
            return (200, adminData("{\"updated\":true,\"libraryItem\":\(adminItemFixture)}"))
        }
        var metadata = MetadataUpdate(); metadata.title = "新标题"
        let result = try await adminClient().updateItemMedia(id: "book", update: .init(metadata: metadata))
        #expect(result.updated); #expect(result.libraryItem.isMissing)
        #expect(result.libraryItem.media.metadata.asin == "B000000001")
        #expect(result.libraryItem.media.audioFiles.first?.exclude == true)
        #expect(result.libraryItem.libraryFiles.first?.metadata.filename == "book.mp3")
    }
    @Test func batchMetadataUsesBareArrayAndMediaPayload() async throws {
        AdminHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [[String: Any]])
            #expect(body.count == 1); #expect(body[0]["id"] as? String == "book")
            let media = try #require(body[0]["mediaPayload"] as? [String: Any]); #expect(media["tags"] as? [String] == ["收藏"])
            return (200, adminData(#"{"success":true,"updates":1}"#))
        }
        let result = try await adminClient().batchUpdateItemMedia([.init(id: "book", mediaPayload: .init(tags: ["收藏"]))])
        #expect(result.updates == 1)
    }
    @Test func audioOrderAndChapterResponsesFollowDifferentServerShapes() async throws {
        AdminHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: Any])
            if request.url!.path.hasSuffix("tracks") {
                #expect(request.httpMethod == "PATCH")
                #expect(body["orderedFileData"] as? [[String: Any]] != nil)
                #expect(body["chapters"] == nil)
                return (200, adminData(adminItemFixture))
            }
            #expect(request.httpMethod == "POST"); #expect((body["chapters"] as? [[String: Any]])?.first?["start"] as? Double == 0)
            return (200, adminData(#"{"success":true,"updated":false}"#))
        }
        let client = await adminClient()
        #expect(try await client.updateAudioTrackOrder(itemID: "book", files: [.init(ino: "f", exclude: true)]).id == "book")
        let result = try await client.updateChapters(itemID: "book", chapters: [.init(id: 0, title: "一", start: 0, end: 20)])
        #expect(result.success && !result.updated)
    }
    @Test func encodingOptionsAreQueryParametersAndEmbedUsesLibraryItemIDs() async throws {
        AdminHTTPProtocol.state.install { request in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if request.url!.path.hasSuffix("encode-m4b") {
                #expect(query == ["codec": "aac", "channels": "2", "bitrate": "96k"]); #expect(adminBody(request).isEmpty)
            } else {
                #expect(query["forceEmbedChapters"] == "1"); #expect(query["backup"] == "1")
                let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: [String]])
                #expect(body == ["libraryItemIds": ["book"]])
            }
            return (200, Data())
        }
        let client = await adminClient(); var options = M4BEncodeOptions(); options.codec = "aac"; options.channels = "2"; options.bitrate = "96k"
        try await client.encodeM4B(itemID: "book", options: options)
        try await client.embedItemsMetadata(ids: ["book"], forceChapters: true, backup: true)
    }
    @Test func customEncodingValuesRemainSingleQueryValuesAndFailuresAreNotRetried() async throws {
        let codec = "custom+codec&backup=1"
        AdminHTTPProtocol.state.install { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/abs/api/tools/item/book/encode-m4b")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            #expect(components?.percentEncodedQuery?.contains("custom%2Bcodec%26backup%3D1") == true)
            let pairs = components?.queryItems ?? []
            #expect(pairs.count == 3)
            let query = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value ?? "") })
            #expect(query == ["codec": codec, "channels": "6", "bitrate": "245k"])
            #expect(adminBody(request).isEmpty)
            return (400, adminData("Unsupported encoder"))
        }
        let client = await adminClient()
        var options = M4BEncodeOptions()
        options.codec = codec; options.channels = "6"; options.bitrate = "245k"
        do {
            try await client.encodeM4B(itemID: "book", options: options)
            Issue.record("Expected HTTP 400 to remain a failed encoding request")
        } catch ABSError.http(status: 400, message: _) { }
        #expect(AdminHTTPProtocol.state.count("/abs/api/tools/item/book/encode-m4b") == 1)
    }
    @Test func legacyProviderCatalogAvoidsUnavailableRouteAndIncludesCustomBooks() async throws {
        AdminHTTPProtocol.state.install { request in
            if request.url?.path == "/abs/api/me" {
                return (200, adminData(#"{"id":"root","username":"synthetic","type":"root","permissions":{}}"#))
            }
            #expect(request.url?.path == "/abs/api/custom-metadata-providers")
            return (200, adminData(#"{"providers":[{"id":"synthetic","name":"Local","mediaType":"book","url":"http://127.0.0.1:58142/provider"}]}"#))
        }
        let catalog = try await adminClient(version: "2.26.0").metadataProviders()
        #expect(catalog.books.contains { $0.value == "google" })
        #expect(catalog.books.contains { $0.value == "custom-synthetic" })
        #expect(catalog.podcasts.contains { $0.value == "itunes" })
        #expect(AdminHTTPProtocol.state.count("/abs/api/search/providers") == 0)
    }

    @Test func metadataProviderCatalogIsAnObjectAndSearchKeepsLiteralPlus() async throws {
        AdminHTTPProtocol.state.install { request in
            if request.url!.path.hasSuffix("providers") { return (200, adminData(#"{"providers":{"books":[{"value":"google","text":"Google Books"}],"booksCovers":[{"value":"best","text":"Best"}],"podcasts":[{"value":"itunes","text":"iTunes"}]}}"#)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "title" })?.value == "C++")
            #expect(query?.first(where: { $0.name == "id" })?.value == "book/id")
            return (200, adminData(#"[{"title":"C++","series":[{"series":"教程","sequence":"1"}],"duration":60,"genres":null,"abridged":false}]"#))
        }
        let client = await adminClient(); #expect(try await client.metadataProviders().books.first?.value == "google")
        let books = try await client.searchBookMetadata(.init(title: "C++", itemID: "book/id"))
        #expect(books.first?.series?.first?.sequence == "1")
    }
    @Test func libraryCreationUsesFolderPathsAndTypedSettings() async throws {
        AdminHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: Any])
            #expect(body["folders"] as? [[String: String]] == [["fullPath": "/media/books"]])
            #expect(body["mediaType"] as? String == "book")
            return (200, adminData(adminLibraryFixture))
        }
        let library = try await adminClient().createLibrary(.init(name: "书库", folders: [.init(fullPath: "/media/books")]))
        #expect(library.settings?.metadataPrecedence?.last == "absMetadata")
    }
    @Test func switchingCompletionModeCanExplicitlyClearPreviousPercentage() throws {
        var update = LibrarySettingsUpdate(); update.markAsFinishedTimeRemaining = 15; update.clearMarkAsFinishedPercentComplete = true; update.clearAutoScanCronExpression = true
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(wire["markAsFinishedTimeRemaining"] as? Double == 15)
        #expect(wire["markAsFinishedPercentComplete"] is NSNull); #expect(wire["autoScanCronExpression"] is NSNull)
        #expect(wire["clearMarkAsFinishedPercentComplete"] == nil)
        let decoded = try JSONDecoder().decode(LibrarySettingsUpdate.self, from: adminData(#"{"markAsFinishedPercentComplete":95}"#))
        #expect(decoded.markAsFinishedPercentComplete == 95); #expect(!decoded.clearMarkAsFinishedPercentComplete)
    }
    @Test func authenticationSessionsSendRefreshHeaderAndRetryWithRotatedHeader() async throws {
        AdminHTTPProtocol.state.install { request in
            if request.url!.path.hasSuffix("/auth/refresh") { return (200, adminData(#"{"user":{"id":"user","username":"reader","accessToken":"rotated-access","refreshToken":"rotated-refresh"}}"#)) }
            let count = AdminHTTPProtocol.state.count("/abs/api/me/sessions")
            #expect(request.value(forHTTPHeaderField: "x-refresh-token") == (count == 1 ? "fixture-refresh" : "rotated-refresh"))
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(query == ["page": "1", "itemsPerPage": "20"])
            if count == 1 { return (401, Data()) }
            return (200, adminData(#"{"sessions":[{"id":"session","ipAddress":"127.0.0.1","deviceInfo":{"osName":"macOS"},"createdAt":1000,"updatedAt":2000,"current":true}],"total":1,"numPages":1,"page":1,"itemsPerPage":20}"#))
        }
        let page = try await adminClient().authenticationSessions(page: 1)
        #expect(page.sessions.first?.current == true); #expect(page.sessions.first?.deviceInfo?.osName == "macOS")
        #expect(AdminHTTPProtocol.state.count("/abs/api/me/sessions") == 2)
    }
    @Test func oldServerDoesNotCallUnsupportedAuthenticationOrAPIKeyEndpoints() async throws {
        AdminHTTPProtocol.state.install { _ in Issue.record("Unsupported endpoint must not be called"); return (500, Data()) }
        let client = await adminClient(version: "2.26.0")
        await #expect(throws: AdminFeatureError.unavailable(feature: "活跃登录会话", minimumVersion: "2.37.1")) { try await client.authenticationSessions() }
        await #expect(throws: AdminFeatureError.unavailable(feature: "API Key 管理", minimumVersion: "2.37.1")) { try await client.apiKeys() }
    }
    @Test func oneTimeAPIKeyKeepsISODateAndOnlyPermittedUpdateFields() async throws {
        AdminHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: Any])
            if request.httpMethod == "POST" { #expect(body["expiresIn"] as? Double == 3600); #expect(body["userId"] as? String == "reader") }
            else { #expect(Set(body.keys) == ["isActive"]) }
            return (200, adminData(#"{"apiKey":{"id":"key","name":"Mac","userId":"reader","isActive":true,"expiresAt":"2026-10-12T12:00:00.000Z","createdAt":"2026-10-12T11:00:00.000Z","apiKey":"fixture-one-time-key"}}"#))
        }
        let client = await adminClient(); let key = try await client.createAPIKey(.init(name: "Mac", userId: "reader", expiresIn: 3600))
        #expect(key.expiresAt?.contains("2026") == true); #expect(key.apiKey == "fixture-one-time-key")
        _ = try await client.updateAPIKey(id: "key", update: .init(isActive: false))
    }
    @Test(arguments: ["restore", "match", "notification"])
    func mutatingGETNeverReplaysOnAuthenticationFailure(action: String) async throws {
        AdminHTTPProtocol.state.install { request in
            if request.url!.path.hasSuffix("auth/refresh") { return (200, adminData(#"{"user":{"id":"user","username":"reader","accessToken":"new","refreshToken":"new-refresh"}}"#)) }
            return (401, Data())
        }
        let client = await adminClient()
        do {
            switch action { case "restore": try await client.applyBackup(id: "backup"); case "match": try await client.matchLibrary(id: "lib"); default: try await client.sendNotificationTest(id: "notification") }
            Issue.record("Mutation unexpectedly succeeded")
        } catch ABSError.http(status: 401, message: _) { }
        let path = switch action { case "restore": "/abs/api/backups/backup/apply"; case "match": "/abs/api/libraries/lib/matchall"; default: "/abs/api/notifications/notification/test" }
        #expect(AdminHTTPProtocol.state.count(path) == 1)
    }
    @Test func notificationUpdateCarriesMatchingIDAndSettingsAreDirect() async throws {
        AdminHTTPProtocol.state.install { request in
            let body = try #require(JSONSerialization.jsonObject(with: adminBody(request)) as? [String: Any])
            #expect(body["id"] as? String == "notification"); #expect(body["enabled"] as? Bool == true)
            return (200, adminData(#"{"appriseType":"api","appriseApiUrl":null,"notifications":[],"maxFailedAttempts":5,"maxNotificationQueue":20,"notificationDelay":1000}"#))
        }
        let settings = try await adminClient().updateNotification(id: "notification", update: .init(eventName: "onTest", urls: ["fixture://test"]))
        #expect(settings.notifications.isEmpty)
    }
    @Test func permissionPolicyDoesNotOverrideExplicitAdminDenial() throws {
        let denied = UserAccount(id: "root", username: "root", type: "root")
        #expect(!AdminPolicy.allows(.upload, user: denied)); #expect(!AdminPolicy.allows(.updateContent, user: denied)); #expect(!AdminPolicy.allows(.deleteContent, user: denied))
        #expect(AdminPolicy.allows(.manageServer, user: denied))
        let disabled = UserAccount(id: "admin", username: "disabled", type: "admin", permissions: .init(download: true, update: true, delete: true, upload: true), isActive: false)
        #expect(!AdminPolicy.allows(.manageServer, user: disabled)); #expect(!AdminPolicy.allows(.upload, user: disabled))
    }
    @Test func multipartPreservesBinaryContentAndRejectsHeaderInjection() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        let bytes = Data((0..<(140 * 1024)).map { UInt8($0 % 256) }); try bytes.write(to: input)
        let part = try await MultipartFileBuilder().build(fields: ["library": "lib", "folder": "folder", "title": "书名"], files: [.init(name: "file0", file: .init(localURL: input, filename: "第一章.mp3", mimeType: "audio/mpeg"))])
        defer { try? FileManager.default.removeItem(at: part.url) }
        let multipart = try Data(contentsOf: part.url)
        #expect(multipart.range(of: bytes) != nil)
        #expect(multipart.range(of: Data("name=\"library\"\r\n\r\nlib".utf8)) != nil)
        #expect(multipart.range(of: Data("filename=\"第一章.mp3\"".utf8)) != nil)
        for filename in ["x\r\nInjected: header", "x\rInjected: header", "x\nInjected: header", "x\"Injected", "x\u{0}Injected"] {
            await #expect(throws: AdminFeatureError.invalidUpload) { try await MultipartFileBuilder().build(fields: [:], files: [.init(name: "cover", file: .init(localURL: input, filename: filename))]) }
        }
    }
    @Test func preparedUploadCannotCrossAuthenticationGeneration() async throws {
        AdminHTTPProtocol.state.install { request in
            #expect(request.url?.path == "/abs/logout")
            return (200, Data())
        }
        let client = await adminClient()
        let previousGeneration = await client.authenticationGeneration
        try await client.logout()
        await #expect(throws: ABSError.sessionChanged) {
            try await client.uploadMultipart(path: "api/upload", fileURL: URL(fileURLWithPath: "/unused-fixture"), contentType: "multipart/form-data; boundary=fixture", expectedGeneration: previousGeneration)
        }
        #expect(AdminHTTPProtocol.state.count("/abs/api/upload") == 0)
    }
}
