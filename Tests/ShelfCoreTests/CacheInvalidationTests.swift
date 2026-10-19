import Foundation
import GRDB
import Testing
@testable import ShelfCore

@Suite struct CacheInvalidationTests {
    @Test func failedEvictionCannotReviveOldMetadataAndSuccessfulRetryUnblocksOnlyItsAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-cache-invalidation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Shelf.sqlite")
        let database = try ShelfDatabase(path: path)
        let partition = AccountPartition(serverID: UUID(), userID: "synthetic-user")
        let otherUser = AccountPartition(serverID: partition.serverID, userID: "other-user")
        let otherServer = AccountPartition(serverID: UUID(), userID: partition.userID)
        for scope in [partition, otherUser, otherServer] {
            try await database.save("old metadata", key: "item.book", partition: scope)
        }
        try await database.retryFailedCacheInvalidation(partition: partition)
        #expect(try await database.load(String.self, key: "item.book", partition: partition) == "old metadata")
        let resume = MediaProgress(libraryItemId: "book", currentTime: 42, duration: 100)
        try await database.saveResume(resume, partition: partition)
        let session = OfflinePlaybackSession(id: "queued", itemID: "book", startedAt: 1, updatedAt: 2,
                                            currentTime: 42, timeListening: 1, duration: 100)
        try await database.enqueue(session, partition: partition)
        let download = DownloadRecord(itemID: "book", title: "Original", files: [], state: .ready)
        try await database.saveDownload(download, partition: partition)
        let sql = try DatabaseQueue(path: path.path)
        try await sql.write {
            try $0.execute(sql: "CREATE TRIGGER reject_cache_eviction BEFORE DELETE ON cachedValue BEGIN SELECT RAISE(ABORT,'synthetic cache failure'); END")
        }

        await #expect(throws: DatabaseError.self) { try await database.clearCache(partition: partition) }
        await #expect(throws: DatabaseError.self) { try await database.retryFailedCacheInvalidation(partition: partition) }
        #expect(try await database.load(String.self, key: "item.book", partition: partition) == nil)
        #expect(try await database.load(String.self, key: "item.book", partition: otherUser) == "old metadata")
        #expect(try await database.load(String.self, key: "item.book", partition: otherServer) == "old metadata")
        #expect(try await database.loadResume(itemID: "book", partition: partition) == resume)
        #expect(try await database.pendingSessions(partition: partition) == [session])
        #expect(try await database.downloads(partition: partition) == [download])
        // SQLite rolled the failed DELETE back. The missing load result is the
        // safety barrier, not accidental removal of the stale physical row.
        let oldRows = try await sql.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cachedValue WHERE key='item.book'") }
        #expect(oldRows == 3)
        try await database.save("new but blocked", key: "item.fresh", partition: partition)
        #expect(try await database.load(String.self, key: "item.fresh", partition: partition) == nil)

        try await sql.write { try $0.execute(sql: "DROP TRIGGER reject_cache_eviction") }
        try await database.retryFailedCacheInvalidation(partition: otherUser)
        #expect(try await database.load(String.self, key: "item.book", partition: otherUser) == "old metadata")
        #expect(try await database.load(String.self, key: "item.book", partition: partition) == nil)
        try await database.retryFailedCacheInvalidation(partition: partition)
        try await database.save("fresh metadata", key: "item.book", partition: partition)
        #expect(try await database.load(String.self, key: "item.book", partition: partition) == "fresh metadata")
        #expect(try await database.load(String.self, key: "item.book", partition: otherServer) == "old metadata")
        // Resume positions are user state, not stale book metadata. They and
        // the independent queued sessions/downloads survive successful retry.
        #expect(try await database.loadResume(itemID: "book", partition: partition) == resume)
        #expect(try await database.pendingSessions(partition: partition) == [session])
        #expect(try await database.downloads(partition: partition) == [download])
    }
}
