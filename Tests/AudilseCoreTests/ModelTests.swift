import Foundation
import Testing
@testable import AudilseCore

struct ModelTests {
    @Test(arguments: [#"{"id":"reader-226","username":"reader","type":"user","createdAt":1700000000123}"#,
                      #"{"id":"reader-237","username":"reader","type":"user","isActive":true,"createdAt":1700000000123,"permissions":{}}"#])
    func accountCreationDateUsesFixedReleaseMilliseconds(payload: String) throws {
        let account = try JSONDecoder().decode(UserAccount.self, from: Data(payload.utf8))
        #expect(account.createdAt == 1_700_000_000_123)
        #expect(try JSONDecoder().decode(UserAccount.self, from: JSONEncoder().encode(account)).createdAt == account.createdAt)
        #expect(UserAccount(id: "reader", username: "reader").createdAt == nil)
    }
    @Test func sparseModelsDecodeWithoutErasingIdentity() throws {
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(#"{"id":"item","libraryId":"library","media":{"metadata":{"title":"Book","series":["Series"]},"duration":null}}"#.utf8))
        #expect(item.title == "Book"); #expect(item.media.duration == 0); #expect(item.media.metadata.series.first?.name == "Series")
        #expect(item.updatedAt == nil)
        let updated = try JSONDecoder().decode(LibraryItem.self, from: Data(#"{"id":"item","updatedAt":1729000000123}"#.utf8))
        #expect(updated.updatedAt == 1_729_000_000_123)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LibraryItem.self, from: Data(#"{"media":{}}"#.utf8)) }
    }
    @Test func progressKeepsAudioAndReadingFields() throws {
        let p = MediaProgress(libraryItemId: "book", currentTime: 12, duration: 100, progress: 0.12, lastUpdate: 1_000, ebookLocation: "epubcfi(/6/2)", ebookProgress: 0.5)
        let decoded = try JSONDecoder().decode(MediaProgress.self, from: JSONEncoder().encode(p))
        #expect(decoded == p)
    }
    @Test func basePathAndTraversalValidation() throws {
        let endpoint = try ServerEndpoint(baseURL: URL(string: "https://example.test//abs///?ignored=1")!)
        #expect(endpoint.baseURL.absoluteString == "https://example.test/abs/")
        #expect(try endpoint.url(path: "/abs/api/items") == URL(string: "https://example.test/abs/api/items")!)
        for path in ["../secrets", "/api/%2e%2e/secrets", "//evil.test/secret", "/api/%252e%252e/secrets", "/api/%2f..%2fsecret"] {
            #expect(throws: (any Error).self) { try endpoint.url(path: path) }
        }
    }
    @Test func versionComparisonIsNumeric() {
        #expect(ServerVersion("2.37.1") > ServerVersion("2.9.9"))
        #expect(ServerCapabilities(version: "v2.26.0").isSupported)
        #expect(!ServerCapabilities(version: "2.25.9").isSupported)
    }
    @Test func permissionsDefaultToDenied() throws {
        let user = try JSONDecoder().decode(UserAccount.self, from: Data(#"{"id":"user","username":"reader"}"#.utf8))
        #expect(!user.isAdmin); #expect(!user.permissions.download); #expect(!user.permissions.update)
    }
    @Test func tokenExpiryUsesJWTExpWithoutTrustingPayloadForAuthentication() {
        let payload = Data(#"{"exp":1000}"#.utf8).base64EncodedString()
        #expect(AuthTokens(accessToken: "header.\(payload).signature").expiresAt == Date(timeIntervalSince1970: 1_000))
        #expect(AuthTokens(accessToken: "legacytoken").expiresAt == nil)
    }
    @Test @MainActor func realtimeRetainsPrimitiveEventPayloads() throws {
        let string = try #require(ABSRealtimeClient.encodePayload("stream-id"))
        #expect(try JSONDecoder().decode(String.self, from: string) == "stream-id")
        let number = try #require(ABSRealtimeClient.encodePayload(42))
        #expect(try JSONDecoder().decode(Int.self, from: number) == 42)
        let object = try #require(ABSRealtimeClient.encodePayload(["id": "stream-id"]))
        #expect(try JSONDecoder().decode([String: String].self, from: object) == ["id": "stream-id"])
    }
}
