import Foundation
import Testing
@testable import AudilseCore

@Test func confirmedProgressSurvivesReopenWithoutReplacingLocalResumeOrPendingBaseline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-confirmed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("db.sqlite")
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let pending = OfflinePlaybackSession(id: "offline", itemID: "book", startedAt: 2000, updatedAt: 3000, currentTime: 30, timeListening: 30, duration: 180)
    try await database.enqueue(pending, partition: partition)
    try await database.saveResume(.init(libraryItemId: "book", currentTime: 30, duration: 180, lastUpdate: 3000), partition: partition)
    let confirmed = MediaProgress(libraryItemId: "book", currentTime: 180, duration: 180, isFinished: true, lastUpdate: 1000, ebookLocation: "server-cfi", ebookProgress: 0.4)
    try await database.saveConfirmedProgress(confirmed, partition: partition)
    let reopened = try ShelfDatabase(path: path)
    #expect(try await reopened.confirmedProgress(itemID: "book", partition: partition) == confirmed)
    #expect(try await reopened.loadResume(itemID: "book", partition: partition)?.currentTime == 30)
    #expect(try await reopened.pendingSessions(partition: partition) == [pending])
    let remote = SyncProgressSnapshot(itemID: "book", currentTime: 180, duration: 180, isFinished: true, updatedAt: 1000)
    #expect(OfflineSyncPolicy.conflicts(local: pending, remote: remote))
}

@Test func confirmedProgressRejectsUnknownTimestampAndKeepsMonotonicPerAccountMediaSnapshots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-confirmed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let original = MediaProgress(libraryItemId: "book", currentTime: 80, duration: 180, lastUpdate: 4000)
    try await database.saveConfirmedProgress(original, partition: partition)
    for timestamp in [3999.0, 4000.0] {
        let result = try await database.saveConfirmedProgress(.init(libraryItemId: "book", currentTime: 10, duration: 180, lastUpdate: timestamp), partition: partition)
        #expect(result == original)
    }
    await #expect(throws: OfflineStorageError.invalidSession) {
        try await database.saveConfirmedProgress(.init(libraryItemId: "book", currentTime: 99), partition: partition)
    }
    for invalid in [Double.nan, Double.infinity, -1] {
        await #expect(throws: OfflineStorageError.invalidSession) {
            try await database.saveConfirmedProgress(.init(libraryItemId: "book", currentTime: invalid, lastUpdate: 5000), partition: partition)
        }
        await #expect(throws: OfflineStorageError.invalidSession) {
            try await database.saveConfirmedProgress(.init(libraryItemId: "book", lastUpdate: invalid), partition: partition)
        }
    }
    let episode = MediaProgress(libraryItemId: "book", episodeId: "episode", currentTime: 7, duration: 180, lastUpdate: 3)
    try await database.saveConfirmedProgress(episode, partition: partition)
    #expect(try await database.confirmedProgress(itemID: "book", partition: partition) == original)
    #expect(try await database.confirmedProgress(itemID: "book", episodeID: "episode", partition: partition) == episode)
    #expect(try await database.confirmedProgress(partition: .init(serverID: partition.serverID, userID: "other")).isEmpty)
    #expect(try await database.confirmedProgress(partition: .init(serverID: UUID(), userID: partition.userID)).isEmpty)
}

@Test func confirmedCompletedBaselineAllowsOfflineReplayButStillDetectsRemoteAudioChange() {
    let pending = OfflinePlaybackSession(id: "offline", itemID: "book", startedAt: 2000, updatedAt: 3000, currentTime: 30, timeListening: 30, duration: 180, serverProgressUpdatedAt: 1000, serverCurrentTime: 180, serverFinished: true)
    let unchanged = SyncProgressSnapshot(itemID: "book", currentTime: 180, duration: 180, isFinished: true, updatedAt: 1000)
    let changed = SyncProgressSnapshot(itemID: "book", currentTime: 80, duration: 180, isFinished: false, updatedAt: 4000)
    #expect(!OfflineSyncPolicy.conflicts(local: pending, remote: unchanged))
    #expect(OfflineSyncPolicy.conflicts(local: pending, remote: changed))
}

@Test func confirmedProgressHonorsCacheEvictionAndServerRestoreBarrier() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-confirmed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let confirmed = MediaProgress(libraryItemId: "book", currentTime: 80, duration: 180, lastUpdate: 4000)
    try await database.saveConfirmedProgress(confirmed, partition: partition)
    try await database.clearCache(partition: partition)
    #expect(try await database.confirmedProgress(partition: partition).isEmpty)
    try await database.saveConfirmedProgress(confirmed, partition: partition)
    let batch = try ServerRestoreBatch(canonicalBaseURL: "https://fixture.invalid", profileIDs: [partition.serverID], origin: .requested)
    _ = try await database.beginServerRestore(batch)
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await database.confirmedProgress(partition: partition) }
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await database.confirmedProgress(itemID: "book", partition: partition) }
    await #expect(throws: ServerRestoreArchiveError.pendingRestore) { try await database.saveConfirmedProgress(confirmed, partition: partition) }
    _ = try await database.archiveForServerRestore(batchID: batch.id)
    #expect(try await database.archiveSnapshot(batchID: batch.id).entries.contains { $0.rowKey.hasPrefix("confirmed-progress:") })
}

@Test func downloadResumeAdoptionRechecksConfirmedPendingAndLocalCheckpointAtomically() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-confirmed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let response = MediaProgress(libraryItemId: "podcast", episodeId: "episode", currentTime: 50, duration: 180, lastUpdate: 100)
    let confirmed = MediaProgress(libraryItemId: "podcast", episodeId: "episode", currentTime: 100, duration: 180, lastUpdate: 200)
    try await database.saveConfirmedProgress(confirmed, partition: partition)
    #expect(try await database.saveDownloadedResume(response, partition: partition) == confirmed)
    let checkpoint = MediaProgress(libraryItemId: "podcast", episodeId: "episode", currentTime: 80, duration: 180, lastUpdate: 300)
    try await database.saveResume(checkpoint, partition: partition)
    #expect(try await database.saveDownloadedResume(response, partition: partition) == nil)
    #expect(try await database.loadResume(itemID: "podcast", episodeID: "episode", partition: partition) == checkpoint)
    try await database.enqueue(.init(id: "new-pending", itemID: "podcast", episodeID: "episode", startedAt: 300, updatedAt: 400, currentTime: 33, timeListening: 3, duration: 180), partition: partition)
    let newer = MediaProgress(libraryItemId: "podcast", episodeId: "episode", currentTime: 120, duration: 180, lastUpdate: 500)
    try await database.saveConfirmedProgress(newer, partition: partition)
    #expect(try await database.saveDownloadedResume(newer, partition: partition) == nil)
    #expect(try await database.loadResume(itemID: "podcast", episodeID: "episode", partition: partition) == checkpoint)
    #expect(try await database.confirmedProgress(itemID: "podcast", episodeID: "episode", partition: partition) == newer)
}
