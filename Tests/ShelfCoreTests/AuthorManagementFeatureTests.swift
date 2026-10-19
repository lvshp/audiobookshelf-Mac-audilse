import Foundation
import Testing
@testable import ShelfCore

private final class AuthorHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { lock.lock(); defer { lock.unlock() }; self.handler = handler }
    func respond(_ request: URLRequest) throws -> (Int, Data) { lock.lock(); let handler = handler; lock.unlock(); return try handler!(request) }
}
private final class AuthorHTTP: URLProtocol, @unchecked Sendable {
    static let state = AuthorHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func authorClient(version: String) async -> ABSClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AuthorHTTP.self]
    let tokens = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Synthetic", baseURL: URL(string: "https://author.fixture/base")!, serverVersion: version), session: URLSession(configuration: config), tokenStore: tokens)
    await tokens.save(.init(accessToken: "fixture-token", userID: "u"), account: client.tokenAccount); return client
}
private func authorBody(_ request: URLRequest) throws -> [String: String] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048); while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; data.append(contentsOf: buffer.prefix(size)) } }
    return try JSONDecoder().decode([String: String].self, from: data)
}
@Suite(.serialized) struct AuthorManagementFeatureTests {
    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"]) func mutationOutcomePreservesMergeTargetAndSparseClear(version: String) async throws {
        AuthorHTTP.state.install { request in
            #expect(request.url?.path == "/base/api/authors/old id" && request.httpMethod == "PATCH")
            let body = try authorBody(request); #expect(body == ["name": "Existing", "description": ""])
            return (200, Data(#"{"author":{"id":"retained","libraryId":"lib","name":"Existing","updatedAt":1730000000000},"merged":true}"#.utf8))
        }
        let result = try await authorClient(version: version).updateAuthorResult(id: "old id", update: .init(name: "Existing", description: ""))
        #expect(result.merged == true && result.updated == nil && result.author.id == "retained")
        #expect(result.author.updatedAt == 1730000000000)
    }
    @Test func legacyAuthorAPIsRemainCompatibleAndRetainNoChangeOutcome() async throws {
        AuthorHTTP.state.install { request in
            #expect(request.httpMethod == "POST" && request.url?.path == "/base/api/authors/a/match")
            let body = try authorBody(request); #expect(body == ["q": "Name", "region": "uk"])
            return (200, Data(#"{"author":{"id":"a","name":"Name","libraryId":"lib"},"updated":false}"#.utf8))
        }
        let client = await authorClient(version: "2.37.1")
        #expect(try await client.matchAuthorResult(id: "a", match: .init(query: "Name", region: "uk")).updated == false)
        #expect(try await client.matchAuthor(id: "a", match: .init(query: "Name", region: "uk")).id == "a")
    }
    @Test func imageMutationVerbsAndBodiesRemainDistinct() async throws {
        AuthorHTTP.state.install { request in
            #expect(request.url?.path == "/base/api/authors/a/image")
            if request.httpMethod == "POST" { let body = try authorBody(request); #expect(body == ["url": "https://images.fixture/a.jpg"]) }
            else { #expect(request.httpMethod == "DELETE") }
            return (200, Data(#"{"author":{"id":"a","name":"Name","libraryId":"lib","imagePath":null},"updated":true}"#.utf8))
        }
        let client = await authorClient(version: "2.26.0")
        #expect(try await client.setAuthorImageResult(id: "a", url: "https://images.fixture/a.jpg").updated == true)
        #expect(try await client.deleteAuthorImageResult(id: "a").author.imagePath == nil)
    }
    @Test func authorAndLibraryOptionalMetadataRemainCacheCompatible() throws {
        let legacy = try JSONDecoder().decode(Author.self, from: Data(#"{"id":"a","name":"Name"}"#.utf8))
        #expect(legacy.updatedAt == nil)
        #expect(try JSONDecoder().decode(Author.self, from: JSONEncoder().encode(legacy)) == legacy)
        let library = try JSONDecoder().decode(LibraryDetails.self, from: Data(#"{"id":"l","name":"Library","mediaType":"book","folders":[],"provider":"audible.uk"}"#.utf8))
        #expect(library.provider == "audible.uk")
        #expect(try JSONDecoder().decode(LibraryDetails.self, from: JSONEncoder().encode(library)) == library)
        #expect(try JSONDecoder().decode(LibraryDetails.self, from: Data(#"{"id":"l","name":"Library","mediaType":"book","folders":[]}"#.utf8)).provider == nil)
    }
    @Test func unsafeLegacyRenameIsFailClosedWithoutDisablingOtherOperations() {
        #expect(!AuthorManagementPolicy.allowsRename(serverVersion: nil))
        #expect(!AuthorManagementPolicy.allowsRename(serverVersion: "2.26.0"))
        #expect(!AuthorManagementPolicy.allowsRename(serverVersion: "2.36.0"))
        #expect(AuthorManagementPolicy.allowsRename(serverVersion: "2.36.1"))
        #expect(AuthorManagementPolicy.allowsRename(serverVersion: "2.37.1"))
        let user = UserAccount(id: "u", username: "reader", permissions: .init(delete: true))
        #expect(AdminPolicy.allows(.deleteContent, user: user))
        #expect(!AdminPolicy.allows(.updateContent, user: user) && !AdminPolicy.allows(.upload, user: user))
    }
    @Test func authorPermissionAndNotFoundFailuresPropagate() async {
        for status in [403, 404, 503] {
            AuthorHTTP.state.install { _ in (status, Data("fixture failure".utf8)) }
            let client = await authorClient(version: "2.37.1")
            do { _ = try await client.matchAuthorResult(id: "a", match: .init(query: "Name")); Issue.record("Author failure unexpectedly succeeded") }
            catch let ABSError.http(actualStatus, _) { #expect(actualStatus == status) }
            catch { Issue.record("Unexpected error type") }
        }
    }
}
