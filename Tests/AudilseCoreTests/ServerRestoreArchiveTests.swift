import Foundation
import GRDB
import Testing
@testable import AudilseCore

private func restoreRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("shelf-restore-archive-" + UUID().uuidString) }
private func restoreSession(_ id: String = "session", time: Double = 20) -> OfflinePlaybackSession {
    .init(id: id, itemID: "book", startedAt: 1000, updatedAt: 2000 + time, currentTime: time, timeListening: time, duration: 600)
}
private func restoreBatch(_ ids: [UUID], address: String = "https://example.test/compat/") throws -> ServerRestoreBatch {
    try .init(canonicalBaseURL: address, profileIDs: ids, origin: .requested)
}
private func finishRestore(_ database: ShelfDatabase, _ reader: ReadingRepository, batch: ServerRestoreBatch) async throws -> ServerRestoreBatch {
    _ = try await database.archiveForServerRestore(batchID: batch.id)
    let receipt = try await reader.archiveForServerRestore(batch: batch)
    _ = try await database.markRestoreAwaitingReconnect(batchID: batch.id, readingReceipt: receipt)
    let completed = try await database.completeServerRestore(batchID: batch.id)
    try await reader.completeServerRestore(batch: completed)
    return completed
}

@Test func restoreGateIsDurableAndCanonicalEndpointFindsUnlistedProfile() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Shelf.sqlite")
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let database = try ShelfDatabase(path: path)
    try await database.save(["old"], key: "libraries", partition: partition)
    let proposed = try restoreBatch([partition.serverID], address: "https://EXAMPLE.test:443/compat")
    let batch = try await database.beginServerRestore(proposed)
    #expect(batch.canonicalBaseURL == "https://example.test/compat/")
    let reopened = try ShelfDatabase(path: path)
    #expect(try await reopened.pendingServerRestores() == [batch])
    #expect(try await reopened.restoreGuard(profileID: UUID(), canonicalBaseURL: "https://example.test/compat")?.id == batch.id)
    #expect(try await reopened.restoreGuard(profileID: UUID(), canonicalBaseURL: "https://other.test/compat") == nil)
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await reopened.load([String].self, key: "libraries", partition: partition) }
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await database.clearCache(partition: partition) }
    #expect(throws: ServerRestoreArchiveError.self) { try restoreBatch([partition.serverID], address: "https://example.test/?token=secret") }
    #expect(throws: ServerRestoreArchiveError.self) { try ServerRestoreBatch(canonicalBaseURL: "https://example.test", profileIDs: [], origin: .requested) }
}

@Test func restoreArchivesEveryUserAndProfileExactlyButKeepsDownloadRecords() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Shelf.sqlite")
    let database = try ShelfDatabase(path: path)
    let first = AccountPartition(serverID: UUID(), userID: "alice")
    let sameProfile = AccountPartition(serverID: first.serverID, userID: "bob")
    let second = AccountPartition(serverID: UUID(), userID: "alice")
    let other = AccountPartition(serverID: UUID(), userID: "alice")
    for partition in [first, sameProfile, second, other] {
        try await database.saveResume(.init(libraryItemId: "book", currentTime: 19), partition: partition)
        try await database.enqueue(restoreSession(), partition: partition)
        try await database.saveConflict(.init(local: restoreSession(), remote: .init(itemID: "book", currentTime: 30, duration: 600, isFinished: false, updatedAt: 4000)), partition: partition)
        try await database.saveDownload(.init(itemID: "book", title: "Original", files: [], state: .ready), partition: partition)
    }
    let raw = Data([0, 255, 3, 10, 0, 7])
    let sql = try DatabaseQueue(path: path.path)
    try await sql.write { db in try db.execute(sql: "INSERT INTO cachedValue VALUES (?,?,?,?,?)", arguments: [first.serverID.uuidString, "future-user", "unknown-schema", raw, 42.5]) }
    let batch = try await database.beginServerRestore(restoreBatch([first.serverID, second.serverID]))
    let receipt = try await database.archiveForServerRestore(batchID: batch.id)
    #expect(receipt.counts == ["shelf.cachedValue": 4, "shelf.offlineSession": 3, "shelf.syncConflict": 3])
    let snapshot = try await database.archiveSnapshot(batchID: batch.id)
    let preserved = try #require(snapshot.entries.first { $0.rowKey == "unknown-schema" })
    #expect(preserved.payload == raw && preserved.updatedAt == 42.5 && preserved.userID == "future-user")
    #expect(Set(snapshot.entries.map(\.profileID)) == [first.serverID, second.serverID])
    for partition in [first, sameProfile, second] {
        #expect(try await database.downloads(partition: partition).count == 1)
        await #expect(throws: ServerRestoreArchiveError.retiredSource) { try await database.enqueue(restoreSession("late"), partition: partition) }
        await #expect(throws: ServerRestoreArchiveError.retiredSource) { try await database.acknowledge(restoreSession(), partition: partition) }
    }
    #expect(try await database.pendingSessions(partition: other).count == 1)
    #expect(try await database.conflicts(partition: other).count == 1)
    #expect(try await database.loadResume(itemID: "book", partition: other)?.currentTime == 19)
    #expect(try await database.archiveForServerRestore(batchID: batch.id) == receipt)
}

@Test func restoreReadingArchivesAcknowledgedAndFutureRowsPreservingKindleAndOriginals() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("Shelf.sqlite"))
    let readingRoot = root.appendingPathComponent("Reading")
    let reader = try ReadingRepository(rootDirectory: readingRoot)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let other = AccountPartition(serverID: UUID(), userID: "reader")
    for format in EbookFormat.allCases {
        try await reader.checkpoint(.init(itemID: format.rawValue, format: format, location: "chapter-9", progress: 0.7), partition: partition)
    }
    try await reader.checkpoint(.init(itemID: "other", format: .pdf, location: "2", progress: 0.2), partition: other)
    let sql = try DatabaseQueue(path: readingRoot.appendingPathComponent("Reading.sqlite").path)
    let opaque = Data("{\"format\":\"future-format\",\"unknown\":[1,2,3]}".utf8)
    let fileData = Data("original-file".utf8)
    let original = readingRoot.appendingPathComponent("original.pdf"); try fileData.write(to: original)
    let descriptor = CachedEbook(itemID: "pdf", ino: "ino", format: .pdf, filename: "original.pdf", relativePath: "original.pdf", bytes: Int64(fileData.count))
    try await sql.write { db in
        try db.execute(sql: "UPDATE readingPosition SET pending=0 WHERE itemID='pdf'")
        try db.execute(sql: "INSERT INTO readingPosition VALUES (?,?,?,?,?)", arguments: [partition.serverID.uuidString, partition.userID, "future", opaque, true])
        try db.execute(sql: "INSERT INTO ebookFile VALUES (?,?,?,?,?)", arguments: [partition.serverID.uuidString, partition.userID, "pdf", try JSONEncoder().encode(descriptor), false])
    }
    let batch = try await database.beginServerRestore(restoreBatch([partition.serverID]))
    _ = try await reader.beginServerRestore(batch)
    _ = try await finishRestore(database, reader, batch: batch)
    let archive = try await reader.archiveSnapshot(batchID: batch.id)
    #expect(archive.entries.count == 5)
    #expect(archive.entries.first { $0.rowKey == "pdf" }?.pending == false)
    #expect(archive.entries.first { $0.rowKey == "future" }?.payload == opaque)
    #expect(try await reader.cachedFile(itemID: "pdf", partition: partition) == descriptor)
    #expect(try Data(contentsOf: await reader.validFile(descriptor)) == fileData)
    let fresh = try ReadingRepository(rootDirectory: readingRoot)
    #expect(try await fresh.position(itemID: "mobi", partition: partition)?.location == "chapter-9")
    #expect(try await fresh.position(itemID: "azw3", partition: partition)?.progress == 0.7)
    #expect(try await fresh.position(itemID: "pdf", partition: partition) == nil)
    #expect(try await fresh.position(itemID: "other", partition: other)?.location == "2")
    await #expect(throws: ServerRestoreArchiveError.retiredSource) { try await reader.position(itemID: "mobi", partition: partition) }
}

@Test func restoreCollectsFinalCheckpointsAndCrashReconcilesWithoutRequeue() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Shelf.sqlite"); let readingRoot = root.appendingPathComponent("Reading")
    let database = try ShelfDatabase(path: path); let reader = try ReadingRepository(rootDirectory: readingRoot)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.saveResume(.init(libraryItemId: "book", currentTime: 10, ebookLocation: "old"), partition: partition)
    try await reader.checkpoint(.init(itemID: "ebook", format: .epub, location: "old", progress: 0.1, updatedAt: 1000), partition: partition)
    let batch = try await database.beginServerRestore(restoreBatch([partition.serverID]))
    _ = try await reader.beginServerRestore(batch)
    try await database.saveResume(.init(libraryItemId: "book", currentTime: 40), partition: partition)
    try await database.enqueue(restoreSession(time: 40), partition: partition)
    try await reader.checkpoint(.init(itemID: "ebook", format: .epub, location: "final", progress: 0.4, updatedAt: 2000), partition: partition)
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await reader.pending(partition: partition) }
    let audio = try await database.archiveForServerRestore(batchID: batch.id)
    // Simulate interruption after the main transaction, before the reading transaction.
    let reopened = try ShelfDatabase(path: path); let reopenedReader = try ReadingRepository(rootDirectory: readingRoot)
    #expect(try await reopened.archiveForServerRestore(batchID: batch.id) == audio)
    let reading = try await reopenedReader.archiveForServerRestore(batch: batch)
    _ = try await reopened.markRestoreAwaitingReconnect(batchID: batch.id, readingReceipt: reading)
    let json = try await reopened.exportServerRestoreArchive(batchID: batch.id, readingArchive: reopenedReader.archiveSnapshot(batchID: batch.id))
    let exported = try JSONDecoder().decode(ServerRestoreArchiveSnapshot.self, from: json)
    let resume = try #require(exported.entries.first { $0.rowKey.hasPrefix("resume:") })
    #expect(try JSONDecoder().decode(MediaProgress.self, from: resume.payload).currentTime == 40)
    #expect(try JSONDecoder().decode(MediaProgress.self, from: resume.payload).ebookLocation == "old")
    #expect(try JSONDecoder().decode(ReadingCheckpoint.self, from: #require(exported.entries.first { $0.category == "reading.readingPosition" }).payload).location == "final")
    #expect(exported.receipts.count == 2)
    let completed = try await reopened.completeServerRestore(batchID: batch.id)
    // Simulate interruption between main completion and the reading completion.
    let freshBeforeReconcile = try ReadingRepository(rootDirectory: readingRoot)
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await freshBeforeReconcile.position(itemID: "ebook", partition: partition) }
    #expect(try await reopened.serverRestoreArchives() == [completed])
    try await freshBeforeReconcile.completeServerRestore(batch: completed)
    try await freshBeforeReconcile.completeServerRestore(batch: completed)
    #expect(try await freshBeforeReconcile.position(itemID: "ebook", partition: partition) == nil)
    let fresh = try ShelfDatabase(path: path)
    #expect(try await fresh.pendingSessions(partition: partition).isEmpty)
    #expect(try await fresh.loadResume(itemID: "book", partition: partition) == nil)
    try await fresh.saveResume(.init(libraryItemId: "book", currentTime: 5), partition: partition)
    await #expect(throws: ServerRestoreArchiveError.retiredSource) { try await database.saveResume(.init(libraryItemId: "book", currentTime: 500), partition: partition) }
    #expect(try await fresh.loadResume(itemID: "book", partition: partition)?.currentTime == 5)
    #expect(try await fresh.pendingServerRestores().isEmpty)
}

@Test func restoreSameEndpointUnionSealsOnlyNewProfilesWithoutReopeningOldOnes() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Shelf.sqlite"); let readingRoot = root.appendingPathComponent("Reading")
    let database = try ShelfDatabase(path: path); let reader = try ReadingRepository(rootDirectory: readingRoot)
    let first = AccountPartition(serverID: UUID(), userID: "user"); let second = AccountPartition(serverID: UUID(), userID: "user")
    for part in [first, second] {
        try await database.enqueue(restoreSession(), partition: part)
        try await reader.checkpoint(.init(itemID: "ebook", format: .pdf, location: "first", progress: 0.1), partition: part)
    }
    let batch = try await database.beginServerRestore(restoreBatch([first.serverID])); _ = try await reader.beginServerRestore(batch)
    _ = try await database.archiveForServerRestore(batchID: batch.id)
    let firstReading = try await reader.archiveForServerRestore(batch: batch)
    _ = try await database.markRestoreAwaitingReconnect(batchID: batch.id, readingReceipt: firstReading)
    let merged = try await database.beginServerRestore(restoreBatch([second.serverID], address: "https://EXAMPLE.test:443/compat"))
    #expect(merged.id == batch.id && merged.state == .collecting && Set(merged.profileIDs) == [first.serverID, second.serverID])
    _ = try await reader.beginServerRestore(merged)
    let reopened = try ShelfDatabase(path: path); let reopenedReader = try ReadingRepository(rootDirectory: readingRoot)
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await reopened.enqueue(restoreSession("late-first"), partition: first) }
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await reopenedReader.checkpoint(.init(itemID: "ebook", format: .pdf, location: "bad", progress: 0.9), partition: first) }
    try await database.enqueue(restoreSession("final-second"), partition: second)
    try await reader.checkpoint(.init(itemID: "ebook", format: .pdf, location: "second-final", progress: 0.6), partition: second)
    await #expect(throws: ServerRestoreArchiveError.incompleteArchive) { try await database.markRestoreAwaitingReconnect(batchID: batch.id, readingReceipt: firstReading) }
    _ = try await finishRestore(database, reader, batch: merged)
    #expect(try await database.archiveSnapshot(batchID: batch.id).entries.filter { $0.category == "shelf.offlineSession" }.count == 3)
    #expect(try await reader.archiveSnapshot(batchID: batch.id).entries.count == 2)
    let invalidExtension = try ServerRestoreBatch(id: batch.id, canonicalBaseURL: batch.canonicalBaseURL, profileIDs: merged.profileIDs + [UUID()], origin: .requested)
    await #expect(throws: ServerRestoreArchiveError.scopeChanged) { try await database.beginServerRestore(invalidExtension) }
}

@Test func restoreArchiveTransactionRollsBackCopyDeletionAndEpochTogether() async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("Shelf.sqlite"); let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.save(["old"], key: "library", partition: partition)
    try await database.enqueue(restoreSession(), partition: partition)
    let batch = try await database.beginServerRestore(restoreBatch([partition.serverID]))
    let sql = try DatabaseQueue(path: path.path)
    try await sql.write { try $0.execute(sql: "CREATE TRIGGER reject_session BEFORE INSERT ON serverRestoreArchiveRow WHEN NEW.category='shelf.offlineSession' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
    await #expect(throws: (any Error).self) { try await database.archiveForServerRestore(batchID: batch.id) }
    #expect(try await sql.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cachedValue") } == 1)
    #expect(try await sql.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM offlineSession") } == 1)
    #expect(try await database.archiveSnapshot(batchID: batch.id).entries.isEmpty)
    // The durable barrier remains; a final checkpoint is still permitted because retirement rolled back.
    try await database.enqueue(restoreSession(time: 30), partition: partition)
    try await sql.write { try $0.execute(sql: "DROP TRIGGER reject_session") }
    #expect(try await database.archiveForServerRestore(batchID: batch.id).counts["shelf.offlineSession"] == 1)
}

private actor RestoreWire {
    let holdMethod: String
    var entered = false
    var requests: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    init(holdMethod: String) { self.holdMethod = holdMethod }
    func release() { continuation?.resume(); continuation = nil }
    func respond(_ request: URLRequest) async throws -> Data {
        guard request.url?.host?.hasSuffix(".restore.test") == true, request.url?.path == "/api/me/progress/book", ["GET", "PATCH"].contains(request.httpMethod ?? "") else { throw URLError(.unsupportedURL) }
        let method = request.httpMethod!; requests.append(method)
        if method == holdMethod && !entered { entered = true; await withCheckedContinuation { continuation = $0 } }
        if method == "PATCH" { return Data("OK".utf8) }
        return try JSONEncoder().encode(MediaProgress(libraryItemId: "book", lastUpdate: 1000, ebookLocation: "old", ebookProgress: 0.1))
    }
}
private actor RestoreWireRouter {
    var wires: [String: RestoreWire] = [:]
    func register(_ wire: RestoreWire, host: String) { wires[host] = wire }
    func respond(_ request: URLRequest) async throws -> Data {
        guard let host = request.url?.host, let wire = wires[host] else { throw URLError(.unsupportedURL) }
        return try await wire.respond(request)
    }
}
private final class RestoreWireProtocol: URLProtocol, @unchecked Sendable {
    static let router = RestoreWireRouter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @Sendable [self] in
            do {
                let data = try await Self.router.respond(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
private func restoreWireClient(_ wire: RestoreWire) async -> ABSClient {
    let host = UUID().uuidString.lowercased() + ".restore.test"
    await RestoreWireProtocol.router.register(wire, host: host)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RestoreWireProtocol.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Restore fixture", baseURL: URL(string: "https://" + host)!, serverVersion: "2.37.1"), session: URLSession(configuration: config), tokenStore: store)
    await store.save(.init(accessToken: "synthetic", userID: "user"), account: client.tokenAccount)
    return client
}

@Test(arguments: ["GET", "PATCH"]) func restoreRejectsLateReadingNetworkResultsBeforeMoreWrites(held: String) async throws {
    let root = restoreRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let reader = try ReadingRepository(rootDirectory: root.appendingPathComponent("Reading"))
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await reader.checkpoint(.init(itemID: "book", format: .pdf, location: "new", progress: 0.6, updatedAt: 2000, baselineLocation: "old", baselineProgress: 0.1, baselineUpdatedAt: 1000), partition: partition)
    let wire = RestoreWire(holdMethod: held); let client = await restoreWireClient(wire)
    let syncing = Task { try await reader.synchronize(partition: partition, client: client) }
    for _ in 0..<100 { if await wire.entered { break }; try await Task.sleep(for: .milliseconds(20)) }
    try #require(await wire.entered)
    let batch = try restoreBatch([partition.serverID]); _ = try await reader.beginServerRestore(batch)
    _ = try await reader.archiveForServerRestore(batch: batch)
    await wire.release()
    await #expect(throws: ServerRestoreArchiveError.retiredSource) { try await syncing.value }
    #expect(await wire.requests == (held == "GET" ? ["GET"] : ["GET", "PATCH"]))
    let archived = try #require(await reader.archiveSnapshot(batchID: batch.id).entries.first)
    #expect(archived.pending == true)
    #expect(try JSONDecoder().decode(ReadingCheckpoint.self, from: archived.payload).location == "new")
}
