import Foundation
import Testing
@testable import AudilseCore

private actor ReadingWireServer {
    var progress: MediaProgress
    var patches: [[String: String]] = []
    private var holdFirstPatch: Bool
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(progress: MediaProgress, holdFirstPatch: Bool = false) { self.progress = progress; self.holdFirstPatch = holdFirstPatch }
    func waitForPatch() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { holdFirstPatch = false; releaseWaiter?.resume(); releaseWaiter = nil }
    func respond(_ request: URLRequest) async throws -> Data {
        if request.httpMethod == "PATCH" {
            let fields = try #require(JSONSerialization.jsonObject(with: readingRequestBody(request)) as? [String: Any])
            #expect(Set(fields.keys) == ["ebookLocation", "ebookProgress"])
            let location = try #require(fields["ebookLocation"] as? String)
            let percentage = try #require(fields["ebookProgress"] as? Double)
            patches.append(["location": location])
            progress.ebookLocation = location; progress.ebookProgress = percentage; progress.lastUpdate = (progress.lastUpdate ?? 0) + 1
            didStart = true
            let waiters = startWaiters; startWaiters.removeAll(); for waiter in waiters { waiter.resume() }
            if holdFirstPatch { await withCheckedContinuation { releaseWaiter = $0 } }
            return Data("OK".utf8)
        }
        #expect(request.httpMethod == "GET")
        return try JSONEncoder().encode(progress)
    }
}
private actor ReadingWireRouter {
    var servers: [String: ReadingWireServer] = [:]
    func register(_ server: ReadingWireServer, host: String) { servers[host] = server }
    func respond(_ request: URLRequest) async throws -> Data {
        let server = try #require(servers[request.url!.host!])
        return try await server.respond(request)
    }
}
private final class ReadingWireProtocol: URLProtocol, @unchecked Sendable {
    static let router = ReadingWireRouter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // The fixture owns no mutable instance state; all response state lives
        // in the router actor. Make the asynchronous callback handoff explicit.
        Task { @Sendable [self] in
            do {
                let data = try await Self.router.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
private func readingRequestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
    return result
}
private func readingWireClient(_ server: ReadingWireServer) async -> ABSClient {
    let host = UUID().uuidString.lowercased() + ".test"
    await ReadingWireProtocol.router.register(server, host: host)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ReadingWireProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Reading fixture", baseURL: URL(string: "https://" + host)!, serverVersion: "2.37.1"), session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "fixture", userID: "reader"), account: client.tokenAccount)
    return client
}

@Test func readingSyncPreservesAudioAndAcknowledgesOnlyVerifiedEbookFields() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let server = ReadingWireServer(progress: .init(libraryItemId: "book", currentTime: 300, duration: 600, lastUpdate: 1500, ebookLocation: "2", ebookProgress: 0.1))
    let client = await readingWireClient(server)
    try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "7", progress: 0.6, updatedAt: 2000, baselineLocation: "2", baselineProgress: 0.1, baselineUpdatedAt: 1000), partition: partition)
    #expect(try await repository.synchronize(partition: partition, client: client).isEmpty)
    #expect(try await repository.pending(partition: partition).isEmpty)
    #expect(await server.progress.currentTime == 300)
    #expect(await server.progress.ebookLocation == "7")
}

@Test func readingSyncSerializesCloseCheckpointBehindAnInflightPatch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let server = ReadingWireServer(progress: .init(libraryItemId: "book", lastUpdate: 1000, ebookLocation: "2", ebookProgress: 0.1), holdFirstPatch: true)
    let client = await readingWireClient(server)
    try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "7", progress: 0.6, updatedAt: 2000, baselineLocation: "2", baselineProgress: 0.1, baselineUpdatedAt: 1000), partition: partition)
    let first = Task { try await repository.synchronize(partition: partition, client: client) }
    await server.waitForPatch()
    try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "4", progress: 0.3, updatedAt: 3000), partition: partition)
    let closing = Task { try await repository.synchronize(partition: partition, client: client) }
    await server.release()
    #expect(try await first.value.isEmpty)
    #expect(try await closing.value.isEmpty)
    #expect(await server.patches.map { $0["location"] } == ["7", "4"])
    #expect(try await repository.pending(partition: partition).isEmpty)
}

@Test func readingConflictWaitsForChoiceAndRemoteChoiceNeverChangesAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let server = ReadingWireServer(progress: .init(libraryItemId: "book", currentTime: 300, duration: 600, lastUpdate: 1500, ebookLocation: "9", ebookProgress: 0.8))
    let client = await readingWireClient(server)
    try await repository.checkpoint(.init(itemID: "book", format: .pdf, location: "7", progress: 0.6, updatedAt: 2000, baselineLocation: "2", baselineProgress: 0.1, baselineUpdatedAt: 1000), partition: partition)
    let conflicts = try await repository.synchronize(partition: partition, client: client)
    let conflict = try #require(conflicts.first)
    #expect(await server.patches.isEmpty)
    try await repository.resolve(conflict, useLocal: false, partition: partition, client: client)
    #expect(try await repository.position(itemID: "book", partition: partition)?.location == "9")
    #expect(try await repository.pending(partition: partition).isEmpty)
    #expect(await server.progress.currentTime == 300)
}
