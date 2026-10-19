import Foundation
import Testing
@testable import ShelfCore

private final class KeyEditHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func record(_ request: URLRequest) { lock.withLock { values.append(request) } }
    var requests: [URLRequest] { lock.withLock { values } }
}
private final class KeyEditHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let state = KeyEditHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        let data = Data(#"{"apiKey":{"id":"key","name":"Immutable name","userId":"another","isActive":true}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func keyEditBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}

private func keyFixture(active: Bool = true, expiresAt: String? = nil, userID: String = "user", updatedAt: String = "2026-01-01") throws -> APIKeyRecord {
    let data = try JSONSerialization.data(withJSONObject: ["id": "key", "name": "Immutable name", "userId": userID, "isActive": active, "expiresAt": expiresAt as Any? ?? NSNull(), "updatedAt": updatedAt])
    return try JSONDecoder().decode(APIKeyRecord.self, from: data)
}

struct APIKeyEditingTests {
    @Test func actualIdentityPatchIsVersionGatedAndNeverWritesJWTNameOrExpiry() async throws {
        let before = KeyEditHTTPProtocol.state.requests.count
        for version in ["2.26.0", "2.36.1", "2.37.1"] {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [KeyEditHTTPProtocol.self]
            let tokens = MemoryTokenStore()
            let client = ABSClient(profile: .init(name: "Synthetic key edit", baseURL: URL(string: "https://key-edit.fixture.test/abs")!, serverVersion: version), session: URLSession(configuration: configuration), tokenStore: tokens)
            await tokens.save(.init(accessToken: "synthetic-key-edit", userID: "admin"), account: client.tokenAccount)
            if version == "2.37.1" {
                #expect(try await client.updateAPIKey(id: "key", update: .init(userId: "another")).userId == "another")
            } else {
                await #expect(throws: AdminFeatureError.self) { try await client.updateAPIKey(id: "key", update: .init(userId: "another")) }
            }
        }
        let requests = Array(KeyEditHTTPProtocol.state.requests.dropFirst(before))
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "PATCH"); #expect(request.url?.host == "key-edit.fixture.test")
        #expect(request.url?.path == "/abs/api/api-keys/key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key-edit")
        let json = try #require(JSONSerialization.jsonObject(with: keyEditBody(request)) as? [String: String])
        #expect(json == ["userId": "another"])
    }
    @Test func lifetimeAcceptsCustomWholeSecondsAndFractionalUnitsWithoutTruncation() {
        #expect(APIKeyEditingPolicy.lifetime(value: 1, unit: .seconds) == 1)
        #expect(APIKeyEditingPolicy.lifetime(value: 0.5, unit: .minutes) == 30)
        #expect(APIKeyEditingPolicy.lifetime(value: 1.25, unit: .hours) == 4500)
        #expect(APIKeyEditingPolicy.lifetime(value: 0.5, unit: .days) == 43200)
        for invalid in [0.0, -1, 0.5, .infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            #expect(APIKeyEditingPolicy.lifetime(value: invalid, unit: .seconds) == nil)
        }
        #expect(APIKeyEditingPolicy.lifetime(value: 0.001, unit: .minutes) == nil)
    }
    @Test func existingKeyPatchHasOnlyChangedIdentityAndActivation() throws {
        let encoder = JSONEncoder()
        let identity = try #require(JSONSerialization.jsonObject(with: encoder.encode(APIKeyUpdate(userId: "another"))) as? [String: String])
        #expect(identity == ["userId": "another"])
        let active = try #require(JSONSerialization.jsonObject(with: encoder.encode(APIKeyUpdate(isActive: false))) as? [String: Bool])
        #expect(active == ["isActive": false])
        let creation = APIKeyDraft(name: "Custom", userId: "user", expiresIn: APIKeyEditingPolicy.lifetime(value: 0.5, unit: .minutes))
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(creation)) as? [String: Any])
        #expect(json["expiresIn"] as? Double == 30)
        #expect(json["expiresAt"] == nil)
    }
    @Test func rootIdentityAndExpiredInactiveKeysFollowOfficialRestrictions() throws {
        #expect(!APIKeyEditingPolicy.mayAssign(userType: "root", administratorType: "admin"))
        #expect(APIKeyEditingPolicy.mayAssign(userType: "root", administratorType: "root"))
        #expect(APIKeyEditingPolicy.mayAssign(userType: "user", administratorType: "admin"))
        #expect(!APIKeyEditingPolicy.mayAssign(userType: "user", administratorType: "user"))
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(!APIKeyEditingPolicy.mayEnable(try keyFixture(active: false, expiresAt: "2000-01-01T00:00:00.000Z"), now: now))
        #expect(APIKeyEditingPolicy.mayEnable(try keyFixture(active: true, expiresAt: "2000-01-01T00:00:00Z"), now: now))
        #expect(APIKeyEditingPolicy.mayEnable(try keyFixture(active: false), now: now))
        #expect(!APIKeyEditingPolicy.mayEnable(try keyFixture(active: false, expiresAt: "invalid"), now: now))
    }
    @Test func confirmationSnapshotDetectsReassignedRevokedOrReplacedTargetKey() throws {
        let original = try keyFixture()
        #expect(APIKeyEditingPolicy.unchanged(original, since: original))
        #expect(!APIKeyEditingPolicy.unchanged(try keyFixture(userID: "another"), since: original))
        #expect(!APIKeyEditingPolicy.unchanged(try keyFixture(active: false), since: original))
        #expect(!APIKeyEditingPolicy.unchanged(try keyFixture(updatedAt: "2026-01-02"), since: original))
        #expect(!APIKeyEditingPolicy.unchanged(try keyFixture(expiresAt: "2030-01-01T00:00:00Z"), since: original))
    }
}
