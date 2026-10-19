import Foundation
import Testing
@testable import ShelfCore

private struct ExportFixture: Sendable { var body = Data([1, 2, 3, 4]); var status = 200; var length: String? = "4" }
private final class ExportWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: ExportFixture] = [:]
    private var requests: [String: URLRequest] = [:]
    func install(_ fixture: ExportFixture, url: URL) { lock.lock(); defer { lock.unlock() }; fixtures[url.absoluteString] = fixture }
    func respond(_ request: URLRequest) -> ExportFixture? { lock.lock(); defer { lock.unlock() }; requests[request.url!.absoluteString] = request; return fixtures[request.url!.absoluteString] }
    func request(_ url: URL) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return requests[url.absoluteString] }
}
private final class ExportWireProtocol: URLProtocol, @unchecked Sendable {
    static let state = ExportWireState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.state.respond(request), let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        var headers = ["Content-Type": "application/octet-stream"]
        if let length = fixture.length { headers["Content-Length"] = length }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct ExportEnvironment {
    let client: ABSClient
    let partition: AccountPartition
    let session: URLSession
    let url: URL
    let file = MediaFile(ino: "ino 9", metadata: .init(filename: "extra.pdf", size: 4))
    init(fixture: ExportFixture = .init()) async throws {
        let profile = ServerProfile(name: "Original export fixture", baseURL: URL(string: "https://" + UUID().uuidString.lowercased() + ".test/proxy/")!, userID: "reader", serverVersion: "2.37.1")
        partition = .init(serverID: profile.id, userID: "reader")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExportWireProtocol.self]
        session = URLSession(configuration: config)
        let store = MemoryTokenStore()
        client = ABSClient(profile: profile, session: session, tokenStore: store)
        await store.save(.init(accessToken: "fixture-only", userID: "reader"), account: client.tokenAccount)
        url = try ServerEndpoint(baseURL: profile.baseURL).url(path: "api/items/book%209/file/ino%209/download")
        ExportWireProtocol.state.install(fixture, url: url)
    }
}
private func exportRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-original-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func libraryFileExportSavesOriginalWithBearerAndProxyPrefix() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let env = try await ExportEnvironment()
    let target = root.appendingPathComponent("chosen.pdf")
    try await LibraryFileExporter(session: env.session).export(itemID: "book 9", file: env.file, partition: env.partition, client: env.client, destination: target, progress: { _ in })
    #expect(try Data(contentsOf: target) == Data([1, 2, 3, 4]))
    #expect(ExportWireProtocol.state.request(env.url)?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
    #expect(ExportWireProtocol.state.request(env.url)?.httpShouldHandleCookies == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["chosen.pdf"])
    #expect((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func libraryFileExportReplacesOnlyAfterCompleteDownload() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let env = try await ExportEnvironment(); let target = root.appendingPathComponent("chosen.pdf")
    try Data([8]).write(to: target)
    try await LibraryFileExporter(session: env.session).export(itemID: "book 9", file: env.file, partition: env.partition, client: env.client, destination: target, progress: { _ in }, authorizeCommit: { let original = try Data(contentsOf: target); #expect(original == Data([8])) })
    #expect(try Data(contentsOf: target) == Data([1, 2, 3, 4]))
}

@Test(arguments: [401, 403, 404, 500]) func libraryFileExportFailurePreservesExistingDestination(status: Int) async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let env = try await ExportEnvironment(fixture: .init(status: status)); let target = root.appendingPathComponent("chosen.pdf")
    try Data([8]).write(to: target)
    await #expect(throws: LibraryFileExportError.self) { try await LibraryFileExporter(session: env.session).export(itemID: "book 9", file: env.file, partition: env.partition, client: env.client, destination: target, progress: { _ in }) }
    #expect(try Data(contentsOf: target) == Data([8]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["chosen.pdf"])
}

@Test func libraryFileExportCancellationAndAccountRetirementNeverPublishTarget() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let cancelled = try await ExportEnvironment(); let target = root.appendingPathComponent("chosen.pdf")
    await #expect(throws: CancellationError.self) { try await LibraryFileExporter(session: cancelled.session).export(itemID: "book 9", file: cancelled.file, partition: cancelled.partition, client: cancelled.client, destination: target, progress: { _ in }, authorizeCommit: { throw CancellationError() }) }
    let retired = try await ExportEnvironment()
    await #expect(throws: ABSError.self) { try await LibraryFileExporter(session: retired.session).export(itemID: "book 9", file: retired.file, partition: retired.partition, client: retired.client, destination: target, progress: { _ in }, authorizeCommit: { await retired.client.retireForServerRestore() }) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func libraryFileExportRejectsChangedDestinationAndSymlink() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let env = try await ExportEnvironment(); let target = root.appendingPathComponent("chosen.pdf")
    try Data([8]).write(to: target)
    await #expect(throws: LibraryFileExportError.self) { try await LibraryFileExporter(session: env.session).export(itemID: "book 9", file: env.file, partition: env.partition, client: env.client, destination: target, progress: { _ in }, authorizeCommit: { try Data([7, 7]).write(to: target) }) }
    #expect(try Data(contentsOf: target) == Data([7, 7]))
    let symlink = root.appendingPathComponent("link.pdf")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    await #expect(throws: LibraryFileExportError.self) { try await LibraryFileExporter(session: env.session).export(itemID: "book 9", file: env.file, partition: env.partition, client: env.client, destination: symlink, progress: { _ in }) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
}

@Test func libraryFileExportChecksUnknownLengthAndAllowsKnownEmptyAttachment() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let wrong = try await ExportEnvironment(fixture: .init(body: Data([1, 2]), length: nil)); let target = root.appendingPathComponent("chosen.pdf")
    await #expect(throws: OfflineStorageError.self) { try await LibraryFileExporter(session: wrong.session).export(itemID: "book 9", file: wrong.file, partition: wrong.partition, client: wrong.client, destination: target, progress: { _ in }) }
    let empty = try await ExportEnvironment(fixture: .init(body: Data(), length: "0"))
    let file = MediaFile(ino: "ino 9", metadata: .init(filename: "empty.txt", size: 0))
    try await LibraryFileExporter(session: empty.session).export(itemID: "book 9", file: file, partition: empty.partition, client: empty.client, destination: target, progress: { _ in })
    #expect(try Data(contentsOf: target).isEmpty)
}

@Test func selectedOriginalDownloadsTheRequestedFileAndReopensItOfflineWithoutMainProgress() async throws {
    let root = try exportRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let env = try await ExportEnvironment()
    let endpoint = try ServerEndpoint(baseURL: await env.client.profile.baseURL)
    let primaryURL = try endpoint.url(path: "api/items/book%209/ebook")
    let selectedURL = try endpoint.url(path: "api/items/book%209/ebook/ino%209")
    ExportWireProtocol.state.install(.init(body: Data([9, 8, 7, 6])), url: primaryURL)
    ExportWireProtocol.state.install(.init(), url: selectedURL)
    let repository = try ReadingRepository(rootDirectory: root, session: env.session)
    var item = LibraryItem(id: "book 9", libraryId: "library", media: .init(ebookFile: .init(ino: "primary", metadata: .init(filename: "main.pdf", size: 4))))
    item.libraryFiles = [env.file]
    let primary = try await repository.original(item: item, partition: env.partition, client: env.client)
    let selected = try await repository.original(item: item, fileIno: env.file.ino, partition: env.partition, client: env.client)
    #expect(try Data(contentsOf: primary.1) == Data([9, 8, 7, 6]))
    #expect(try Data(contentsOf: selected.1) == Data([1, 2, 3, 4]))
    #expect(primary.1 != selected.1)
    #expect(ExportWireProtocol.state.request(selectedURL)?.httpShouldHandleCookies == false)
    #expect(item.media.ebookFile?.ino == "primary")
    let reopened = try ReadingRepository(rootDirectory: root)
    let offlinePrimary = try await reopened.original(item: item, partition: env.partition, client: nil)
    let offlineSelected = try await reopened.original(item: item, fileIno: env.file.ino, partition: env.partition, client: nil)
    #expect(offlinePrimary.1 == primary.1)
    #expect(offlineSelected.1 == selected.1)
    try await reopened.checkpoint(.init(itemID: item.id, format: .pdf, location: "2", progress: 0.5), fileIno: env.file.ino, partition: env.partition)
    #expect(try await reopened.synchronize(partition: env.partition, client: env.client).isEmpty)
    #expect(try await reopened.position(itemID: item.id, partition: env.partition) == nil)
    #expect(ExportWireProtocol.state.request(try endpoint.url(path: "api/me/progress/book%209")) == nil)
}
