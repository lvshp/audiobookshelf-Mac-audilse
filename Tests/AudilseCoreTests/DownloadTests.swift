import Foundation
import Testing
@testable import AudilseCore

@Test func downloadPathsRejectTraversalAndSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-download-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["../outside", "/tmp/outside", "a/../../outside", "a//b", "a\\b", "a/\u{0}b"] {
        #expect(throws: OfflineStorageError.self) { try DownloadPaths.safeURL(relativePath: path, root: root) }
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
    #expect(throws: OfflineStorageError.self) { try DownloadPaths.safeURL(relativePath: "escape/outside", root: root) }
    #expect(try DownloadPaths.safeURL(relativePath: "account/book/1.m4b", root: root).path.hasPrefix(root.path + "/"))
}

@Test func downloadReadyRequiresEveryUnchangedOriginalFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-download-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let track = DownloadTrack(ino: "1", title: "Chapter", filename: "book.m4b", contentURL: URL(string: "https://example.com/audio")!, duration: 600, startOffset: 0, expectedBytes: 4)
    var file = DownloadFile(track: track, localRelativePath: "1.m4b")
    file.bytesWritten = 4
    file.completed = true
    let record = DownloadRecord(itemID: "book", title: "Book", files: [file], state: .ready)
    try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("1.m4b"))
    #expect(try DownloadPaths.validatedTracks(record: record, root: root).count == 1)
    try Data([1, 2]).write(to: root.appendingPathComponent("1.m4b"))
    #expect(throws: OfflineStorageError.self) { try DownloadPaths.validatedTracks(record: record, root: root) }
    let incomplete = DownloadRecord(itemID: "book", title: "Book", files: [file], state: .paused)
    #expect(throws: OfflineStorageError.self) { try DownloadPaths.validatedTracks(record: incomplete, root: root) }
}

@MainActor @Test func downloadRestorePausesInterruptedTransfers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-download-restore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "a/../../b")
    let track = DownloadTrack(ino: "1", title: "Chapter", filename: "../../book.mp3", contentURL: URL(string: "https://example.com/audio")!, duration: 20, startOffset: 0)
    try await database.saveDownload(DownloadRecord(itemID: "book", title: "Book", files: [DownloadFile(track: track, localRelativePath: "safe/1.mp3")], state: .downloading), partition: partition)
    let manager = DownloadManager(database: database, rootDirectory: root.appendingPathComponent("files"))
    try await manager.restore(partition: partition)
    #expect(manager.records.first?.state == .paused)
    #expect(partition.directoryName.split(separator: "/").count == 2)
}

private struct DownloadHTTPFixture: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class DownloadProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: DownloadHTTPFixture] = [:]
    private var requests: [String: URLRequest] = [:]
    func install(_ fixture: DownloadHTTPFixture, key: String) { lock.lock(); defer { lock.unlock() }; fixtures[key] = fixture }
    func fixture(for request: URLRequest) -> DownloadHTTPFixture? {
        lock.lock(); defer { lock.unlock() }
        let key = request.url!.absoluteString
        requests[key] = request
        return fixtures[key]
    }
    func request(key: String) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return requests[key] }
}

private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = DownloadProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.state.fixture(for: request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func downloadTransferResumesOriginalBytesWithFreshAuthorization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-range-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent("audio.partial")
    try Data([0, 1, 2, 3]).write(to: partial)
    let url = URL(string: "https://download.example/" + UUID().uuidString)!
    DownloadURLProtocol.state.install(DownloadHTTPFixture(status: 206, headers: ["Content-Range": "bytes 4-9/10", "Content-Length": "6", "ETag": "version-1"], body: Data([4, 5, 6, 7, 8, 9])), key: url.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadURLProtocol.self]
    let engine = DownloadTransfer(session: URLSession(configuration: configuration))
    var request = URLRequest(url: url)
    request.setValue("Bearer fresh", forHTTPHeaderField: "Authorization")
    let result = try await engine.run(request: request, partialURL: partial, expectedBytes: 10, validator: "version-1", progress: { _, _, _ in })
    #expect(result.size == 10)
    #expect(try Data(contentsOf: partial) == Data(0...9))
    #expect(DownloadURLProtocol.state.request(key: url.absoluteString)?.value(forHTTPHeaderField: "Range") == "bytes=4-")
    #expect(DownloadURLProtocol.state.request(key: url.absoluteString)?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
}

@Test func downloadServerIgnoringRangeRestartsFileWithoutDuplicatingBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-range-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent("audio.partial")
    try Data([99, 99]).write(to: partial)
    let url = URL(string: "https://download.example/" + UUID().uuidString)!
    DownloadURLProtocol.state.install(DownloadHTTPFixture(status: 200, headers: ["Content-Length": "4", "ETag": "new-version"], body: Data([1, 2, 3, 4])), key: url.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadURLProtocol.self]
    let engine = DownloadTransfer(session: URLSession(configuration: configuration))
    let result = try await engine.run(request: URLRequest(url: url), partialURL: partial, expectedBytes: 4, validator: "old-version", progress: { _, _, _ in })
    #expect(result.size == 4)
    #expect(try Data(contentsOf: partial) == Data([1, 2, 3, 4]))
}

@Test func downloadCompletePartialRejectsChangedValidatorOn416() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-range-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent("audio.partial")
    try Data([0, 1, 2, 3]).write(to: partial)
    let url = URL(string: "https://download.example/" + UUID().uuidString)!
    DownloadURLProtocol.state.install(DownloadHTTPFixture(status: 416, headers: ["Content-Range": "bytes */4", "ETag": "new-version"], body: Data()), key: url.absoluteString)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadURLProtocol.self]
    let engine = DownloadTransfer(session: URLSession(configuration: configuration))
    await #expect(throws: DownloadTransferError.self) {
        try await engine.run(request: URLRequest(url: url), partialURL: partial, expectedBytes: 4, validator: "old-version", progress: { _, _, _ in })
    }
}

private actor DownloadAuthorizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor @Test func downloadAccountSwitchCannotPublishOldAuthorizationResult() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-account-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite"))
    let a = AccountPartition(serverID: UUID(), userID: "alice")
    let b = AccountPartition(serverID: a.serverID, userID: "bob")
    let track = DownloadTrack(ino: "1", title: "Chapter", filename: "chapter.mp3", contentURL: URL(string: "https://example.com/audio")!, duration: 20, startOffset: 0)
    let manager = DownloadManager(database: database, rootDirectory: root.appendingPathComponent("files"))
    try await manager.restore(partition: a)
    let gate = DownloadAuthorizationGate()
    let oldOperation = Task {
        try await manager.start(partition: a, itemID: "same-id", title: "Alice Book", tracks: [track]) { url in
            await gate.wait()
            return URLRequest(url: url)
        }
    }
    while !(await gate.entered) { await Task.yield() }
    try await manager.restore(partition: b)
    await gate.release()
    await #expect(throws: OfflineStorageError.self) { try await oldOperation.value }
    #expect(manager.partition == b)
    #expect(manager.records.isEmpty)
    #expect(try await database.downloads(partition: b).isEmpty)
    #expect(try await database.downloads(partition: a).first?.title == "Alice Book")
}
