import Foundation
import Testing
import AudilseCore

private final class ReadingAuthorizationHTTP: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        private var saved = false
        func reset() { lock.lock(); defer { lock.unlock() }; methods = []; saved = false }
        func response(_ request: URLRequest) -> Data {
            lock.lock(); defer { lock.unlock() }
            let method = request.httpMethod ?? "GET"
            methods.append(method)
            if method == "PATCH" { saved = true; return Data("{}".utf8) }
            if saved { return Data(#"{"libraryItemId":"book","currentTime":17,"duration":40,"lastUpdate":2,"ebookLocation":"2","ebookProgress":0.3333333333333333}"#.utf8) }
            return Data(#"{"libraryItemId":"book","currentTime":17,"duration":40,"lastUpdate":1}"#.utf8)
        }
        func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return methods }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "reading-authorization.fixture", url.path == "/api/me/progress/book" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let data = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor ReadingAuthorizationCounter {
    private var count = 0
    func current() -> Int { count }
    func authorize(revokeAt: Int) throws {
        count += 1
        if count == revokeAt { throw CancellationError() }
    }
}

@Suite(.serialized) struct ReadingAuthorizationTests {
    private func fixture() async throws -> (URL, ReadingRepository, AccountPartition, ABSClient) {
        ReadingAuthorizationHTTP.state.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-authorize-" + UUID().uuidString)
        let repository = try ReadingRepository(rootDirectory: root)
        let profile = ServerProfile(name: "Reading authorization", baseURL: URL(string: "https://reading-authorization.fixture")!, userID: "reader")
        let partition = AccountPartition(serverID: profile.id, userID: "reader")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadingAuthorizationHTTP.self]
        let tokens = MemoryTokenStore()
        let client = ABSClient(profile: profile, session: URLSession(configuration: configuration), tokenStore: tokens)
        await tokens.save(.init(accessToken: "synthetic-only", userID: "reader"), account: client.tokenAccount)
        try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "2", progress: 1.0 / 3.0, baselineUpdatedAt: 1), partition: partition)
        return (root, repository, partition, client)
    }

    @Test func existingDefaultCallerStillVerifiesAndAcknowledges() async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await repository.synchronize(partition: partition, client: client).isEmpty)
        #expect(ReadingAuthorizationHTTP.state.requests() == ["GET", "PATCH", "GET"])
        #expect(try await repository.pending(partition: partition).isEmpty)
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == "2")
    }

    @Test(arguments: [1, 4, 5, 6]) func revocationStopsTheNextStageAndKeepsCheckpointPending(revokeAt: Int) async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = ReadingAuthorizationCounter()
        await #expect(throws: CancellationError.self) {
            try await repository.synchronize(partition: partition, client: client, authorize: { try await counter.authorize(revokeAt: revokeAt) })
        }
        let expected = revokeAt == 1 ? [] : revokeAt == 4 ? ["GET"] : revokeAt == 5 ? ["GET", "PATCH"] : ["GET", "PATCH", "GET"]
        #expect(ReadingAuthorizationHTTP.state.requests() == expected)
        #expect(try await repository.pending(partition: partition).count == 1)
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == "2")
    }

    @Test(arguments: [true, false]) func existingDefaultConflictCallerKeepsItsBehavior(useLocal: Bool) async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try #require(await repository.position(itemID: "book", partition: partition))
        let conflict = ReadingConflict(local: local, remote: .init(libraryItemId: "book", lastUpdate: 1, ebookLocation: "1", ebookProgress: 0))
        try await repository.resolve(conflict, useLocal: useLocal, partition: partition, client: client)
        #expect(ReadingAuthorizationHTTP.state.requests() == (useLocal ? ["GET", "PATCH", "GET"] : ["GET"]))
        #expect(try await repository.pending(partition: partition).isEmpty)
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == (useLocal ? "2" : "1"))
    }

    @Test(arguments: [1, 3, 4, 5]) func conflictRevocationStopsBeforeTheNextStage(revokeAt: Int) async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try #require(await repository.position(itemID: "book", partition: partition))
        let conflict = ReadingConflict(local: local, remote: .init(libraryItemId: "book", lastUpdate: 1))
        let counter = ReadingAuthorizationCounter()
        await #expect(throws: CancellationError.self) {
            try await repository.resolve(conflict, useLocal: true, partition: partition, client: client,
                                         authorize: { try await counter.authorize(revokeAt: revokeAt) })
        }
        let expected = revokeAt == 1 ? [] : revokeAt == 3 ? ["GET"] : revokeAt == 4 ? ["GET", "PATCH"] : ["GET", "PATCH", "GET"]
        #expect(ReadingAuthorizationHTTP.state.requests() == expected)
        #expect(try await repository.pending(partition: partition).count == 1)
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == "2")
    }

    @Test func remoteConflictChoicePreservesAChangedLocalCheckpoint() async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try #require(await repository.position(itemID: "book", partition: partition))
        let conflict = ReadingConflict(local: local, remote: .init(libraryItemId: "book", lastUpdate: 1, ebookLocation: "1", ebookProgress: 0))
        let counter = ReadingAuthorizationCounter()
        try await repository.resolve(conflict, useLocal: false, partition: partition, client: client, authorize: {
            try await counter.authorize(revokeAt: 100)
            if await counter.current() == 3 {
                try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "3", progress: 2.0 / 3.0, baselineUpdatedAt: 1), partition: partition)
            }
        })
        #expect(ReadingAuthorizationHTTP.state.requests() == ["GET"])
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == "3")
        #expect(try await repository.pending(partition: partition).count == 1)
    }

    @Test func remoteConflictChoiceCannotReplaceLocalAfterRevocation() async throws {
        let (root, repository, partition, client) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try #require(await repository.position(itemID: "book", partition: partition))
        let conflict = ReadingConflict(local: local, remote: .init(libraryItemId: "book", lastUpdate: 1, ebookLocation: "1", ebookProgress: 0))
        let counter = ReadingAuthorizationCounter()
        await #expect(throws: CancellationError.self) {
            try await repository.resolve(conflict, useLocal: false, partition: partition, client: client,
                                         authorize: { try await counter.authorize(revokeAt: 3) })
        }
        #expect(ReadingAuthorizationHTTP.state.requests() == ["GET"])
        #expect(try await repository.position(itemID: "book", partition: partition)?.location == "2")
        #expect(try await repository.pending(partition: partition).count == 1)
    }
}
