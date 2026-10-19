import Foundation
import Testing
@testable import ShelfCore

private func storageTestURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("shelf-storage-test-" + UUID().uuidString).appendingPathComponent("store.sqlite")
}

private func sampleSession(id: String = "s1", itemID: String = "book", update: Double = 2000, position: Double = 100, listening: Double = 40) -> OfflinePlaybackSession {
    OfflinePlaybackSession(id: id, itemID: itemID, startedAt: 1000, updatedAt: update, currentTime: position, timeListening: listening, duration: 600, serverProgressUpdatedAt: 500, serverCurrentTime: 50, serverFinished: false)
}

@Test func storagePersistsAcrossReopenAndSeparatesAccounts() async throws {
    let path = storageTestURL()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let partition = AccountPartition(serverID: UUID(), userID: "alice")
    let otherUser = AccountPartition(serverID: partition.serverID, userID: "bob")
    let otherServer = AccountPartition(serverID: UUID(), userID: "alice")
    let database = try ShelfDatabase(path: path)
    try await database.save(["library"], key: "libraries", partition: partition)
    try await database.enqueue(sampleSession(), partition: partition)
    let reopened = try ShelfDatabase(path: path)
    #expect(try await reopened.load([String].self, key: "libraries", partition: partition) == ["library"])
    #expect(try await reopened.load([String].self, key: "libraries", partition: otherUser) == nil)
    #expect(try await reopened.pendingSessions(partition: otherServer).isEmpty)
    try await reopened.clearCache(partition: partition)
    #expect(try await reopened.load([String].self, key: "libraries", partition: partition) == nil)
    #expect(try await reopened.pendingSessions(partition: partition).count == 1)
}

@Test func storageMergesCumulativeSessionAndAcknowledgesOnlyExactSnapshot() async throws {
    let path = storageTestURL()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let database = try ShelfDatabase(path: path)
    let old = sampleSession()
    let newest = sampleSession(update: 3000, position: 80, listening: 60)
    try await database.enqueue(old, partition: partition)
    try await database.enqueue(newest, partition: partition)
    try await database.enqueue(old, partition: partition)
    #expect(try await database.pendingSessions(partition: partition) == [newest])
    try await database.acknowledge(old, partition: partition)
    #expect(try await database.pendingSessions(partition: partition) == [newest])
    try await database.acknowledge(newest, partition: partition)
    #expect(try await database.pendingSessions(partition: partition).isEmpty)
}

@Test func storageRejectsInvalidSessionAndIdentityChange() async throws {
    let path = storageTestURL()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let database = try ShelfDatabase(path: path)
    try await database.enqueue(sampleSession(), partition: partition)
    await #expect(throws: OfflineStorageError.self) {
        try await database.enqueue(sampleSession(itemID: "other", update: 3000, listening: 60), partition: partition)
    }
    await #expect(throws: OfflineStorageError.self) {
        try await database.enqueue(sampleSession(id: "invalid", position: .nan), partition: partition)
    }
}

@Test func storageResumePreservesEbookFields() async throws {
    let path = storageTestURL()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let database = try ShelfDatabase(path: path)
    let progress = MediaProgress(libraryItemId: "book", currentTime: 20, duration: 100, ebookLocation: "epubcfi(/6/2)", ebookProgress: 0.2)
    try await database.saveResume(progress, partition: partition)
    #expect(try await database.loadResume(itemID: "book", partition: partition) == progress)
    try await database.saveResume(MediaProgress(libraryItemId: "book", currentTime: 40, duration: 100), partition: partition)
    #expect(try await database.loadResume(itemID: "book", partition: partition)?.ebookLocation == "epubcfi(/6/2)")
    #expect(try await database.loadResume(itemID: "book", partition: partition)?.currentTime == 40)
}

@Test func storageFreezesRemoteBaselineFromSessionStart() async throws {
    let path = storageTestURL()
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let database = try ShelfDatabase(path: path)
    var session = LocalPlaybackSession(id: "one", libraryItemId: "book", duration: 600, currentTime: 100, startedAt: 1000, updatedAt: 2000, timeListening: 10)
    try await database.enqueue(session, partition: partition, baseline: MediaProgress(libraryItemId: "book", currentTime: 50, lastUpdate: 500))
    session.currentTime = 120
    session.updatedAt = 3000
    session.timeListening = 30
    try await database.enqueue(session, partition: partition, baseline: MediaProgress(libraryItemId: "book", currentTime: 400, lastUpdate: 2500))
    let saved = try #require(await database.pendingSessions(partition: partition).first)
    #expect(saved.serverCurrentTime == 50)
    #expect(saved.serverProgressUpdatedAt == 500)
    #expect(saved.currentTime == 120)
    #expect(saved.timeListening == 30)
}
