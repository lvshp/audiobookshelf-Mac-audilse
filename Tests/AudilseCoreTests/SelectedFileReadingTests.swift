import Foundation
import GRDB
import Testing
@testable import AudilseCore

@Test func selectedFileReadingSeparatesFilesAccountsAndMainProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-selected-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let a = AccountPartition(serverID: UUID(), userID: "alice")
    let b = AccountPartition(serverID: a.serverID, userID: "bob")
    let c = AccountPartition(serverID: UUID(), userID: "alice")
    let main = ReadingCheckpoint(itemID: "book", format: .pdf, location: "3", progress: 0.2, updatedAt: 1000)
    let first = ReadingCheckpoint(itemID: "book", format: .pdf, location: "7", progress: 0.6, updatedAt: 2000)
    let second = ReadingCheckpoint(itemID: "book", format: .epub, location: "cfi-2", progress: 0.1, updatedAt: 2000)
    try await repository.checkpoint(main, partition: a)
    try await repository.checkpoint(first, fileIno: "pdf-ino", partition: a)
    try await repository.checkpoint(second, fileIno: "epub-ino", partition: a)
    let reopened = try ReadingRepository(rootDirectory: root)
    #expect(try await reopened.position(itemID: "book", partition: a) == main)
    #expect(try await reopened.pending(partition: a) == [main])
    #expect(try await reopened.position(itemID: "book", fileIno: "pdf-ino", partition: a) == first)
    #expect(try await reopened.position(itemID: "book", fileIno: "epub-ino", partition: a) == second)
    #expect(try await reopened.position(itemID: "book", fileIno: "pdf-ino", partition: b) == nil)
    #expect(try await reopened.position(itemID: "book", fileIno: "pdf-ino", partition: c) == nil)
    #expect(try await reopened.position(itemID: "another-book", fileIno: "pdf-ino", partition: a) == nil)
}

@Test func selectedFileCheckpointRejectsStaleWritesAndNeverBecomesPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-selected-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let latest = ReadingCheckpoint(itemID: "book", format: .epub, location: "backwards", progress: 0.1, updatedAt: 3000)
    try await repository.checkpoint(latest, fileIno: "extra", partition: partition)
    try await repository.checkpoint(.init(itemID: "book", format: .epub, location: "old", progress: 0.7, updatedAt: 2000), fileIno: "extra", partition: partition)
    #expect(try await repository.position(itemID: "book", fileIno: "extra", partition: partition) == latest)
    #expect(try await repository.pending(partition: partition).isEmpty)
    await #expect(throws: ReadingError.self) { try await repository.checkpoint(latest, fileIno: "", partition: partition) }
}

@Test func selectedOriginalCacheIsPerFileAndMigratesTheExistingPrimaryCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-selected-reading-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    let old = CachedEbook(itemID: "book", ino: "primary", format: .pdf, filename: "primary.pdf", relativePath: "primary.pdf", bytes: 4)
    let queue = try DatabaseQueue(path: root.appendingPathComponent("Reading.sqlite").path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("reading-v1") { db in
        for name in ["ebookFile", "readingPosition"] {
            try db.create(table: name) { t in
                t.column("serverID", .text).notNull(); t.column("userID", .text).notNull(); t.column("itemID", .text).notNull()
                t.column("payload", .blob).notNull(); t.column("pending", .boolean).notNull().defaults(to: false)
                t.primaryKey(["serverID", "userID", "itemID"])
            }
        }
    }
    migrator.registerMigration("reading-v2-server-restore-archive", migrate: RestoreArchiveSQL.migrate)
    try migrator.migrate(queue)
    try await queue.write { db in
        try db.execute(sql: "INSERT INTO ebookFile VALUES (?,?,?,?,0)", arguments: [partition.serverID.uuidString, partition.userID, "book", try JSONEncoder().encode(old)])
    }
    try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("primary.pdf"))
    let repository = try ReadingRepository(rootDirectory: root)
    var item = LibraryItem(id: "book", libraryId: "library", media: .init(ebookFile: .init(ino: "primary", metadata: .init(filename: "primary.pdf", size: 4))))
    item.libraryFiles = [.init(ino: "extra", metadata: .init(filename: "extra.pdf", size: 2))]
    let cached = try await repository.original(item: item, partition: partition, client: nil)
    #expect(cached.0 == old)
    #expect(try await repository.cachedFile(itemID: "book", fileIno: "extra", partition: partition) == nil)
    await #expect(throws: ReadingError.self) { try await repository.original(item: item, fileIno: "extra", partition: partition, client: nil) }
    await #expect(throws: ReadingError.self) { try await repository.original(item: item, fileIno: "missing", partition: partition, client: nil) }
}

@Test func selectedReadingIsExcludedFromTheServerRestoreArchive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-selected-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    try await repository.checkpoint(.init(itemID: "book", format: .epub, location: "main", progress: 0.2), partition: partition)
    try await repository.checkpoint(.init(itemID: "book", format: .epub, location: "extra", progress: 0.3), fileIno: "extra", partition: partition)
    let batch = try ServerRestoreBatch(canonicalBaseURL: "https://fixture.test/", profileIDs: [partition.serverID], origin: .requested)
    _ = try await repository.beginServerRestore(batch)
    _ = try await repository.archiveForServerRestore(batch: batch)
    let archive = try await repository.archiveSnapshot(batchID: batch.id)
    #expect(archive.entries.count == 1)
    let db = try DatabaseQueue(path: root.appendingPathComponent("Reading.sqlite").path)
    #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM selectedReadingPosition") } == 1)
}
