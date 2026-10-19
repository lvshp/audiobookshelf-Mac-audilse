import Foundation
import Testing
@testable import AudilseCore

private actor FakeSyncRemote: OfflineSyncRemote {
    var saved: SyncProgressSnapshot?
    var uploaded: [OfflinePlaybackSession] = []
    var failUpload = false

    init(progress: SyncProgressSnapshot?) { saved = progress }
    func progress(itemID: String, episodeID: String?) async throws -> SyncProgressSnapshot? { saved }
    func upload(_ session: OfflinePlaybackSession) async throws {
        if failUpload { throw URLError(.notConnectedToInternet) }
        uploaded.append(session)
        if saved == nil { saved = SyncProgressSnapshot(itemID: session.itemID, currentTime: session.currentTime, duration: session.duration, isFinished: false, updatedAt: session.updatedAt) }
        saved?.currentTime = session.currentTime
    }
    func setAudioPosition(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        saved?.currentTime = currentTime
        saved?.duration = duration
        saved?.isFinished = isFinished
    }
    func uploads() -> [OfflinePlaybackSession] { uploaded }
    func setFailure() { failUpload = true }
}

private func syncSession(id: String, update: Double, position: Double) -> OfflinePlaybackSession {
    OfflinePlaybackSession(id: id, itemID: "book", startedAt: 1000, updatedAt: update, currentTime: position, timeListening: 10, duration: 600, serverProgressUpdatedAt: 500, serverCurrentTime: 50, serverFinished: false)
}

@Test func managementLeasePreventsHistoryUploadAndOnlyItsOwnerCanReleaseIt() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-sync-lease-" + UUID().uuidString).appendingPathComponent("db.sqlite")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try ShelfDatabase(path: path), partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.enqueue(syncSession(id: "history", update: 3000, position: 100), partition: partition)
    let remote = FakeSyncRemote(progress: nil), coordinator = SyncCoordinator(database: database)
    let lease = UUID()
    try await coordinator.reserveSessionMutation(id: lease, partition: partition)
    await #expect(throws: OfflineSyncError.alreadyRunning) { try await coordinator.synchronize(partition: partition, remote: remote) }
    await coordinator.finishSessionMutation(id: UUID())
    await #expect(throws: OfflineSyncError.alreadyRunning) { try await coordinator.reserveSessionMutation(id: UUID(), partition: partition) }
    let otherPartition = AccountPartition(serverID: UUID(), userID: "another-user")
    #expect(try await coordinator.synchronize(partition: otherPartition, remote: remote).uploaded == 0)
    #expect(await remote.uploads().isEmpty)
    #expect(try await database.pendingSessions(partition: partition).count == 1)
    await coordinator.finishSessionMutation(id: lease)
    #expect(try await coordinator.synchronize(partition: partition, remote: remote).uploaded == 1)
}

@Test func syncNewestHistoryFirstAndRestoresLatestPosition() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-sync-test-" + UUID().uuidString).appendingPathComponent("db.sqlite")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.enqueue(syncSession(id: "old", update: 2000, position: 200), partition: partition)
    try await database.enqueue(syncSession(id: "new", update: 3000, position: 100), partition: partition)
    let remote = FakeSyncRemote(progress: SyncProgressSnapshot(itemID: "book", currentTime: 50, duration: 600, isFinished: false, updatedAt: 500, ebookLocation: "cfi", ebookProgress: 0.2))
    let coordinator = SyncCoordinator(database: database)
    let report = try await coordinator.synchronize(partition: partition, remote: remote)
    #expect(report.uploaded == 2)
    #expect(await remote.uploads().map(\.id) == ["new", "old"])
    #expect(try await remote.progress(itemID: "book", episodeID: nil)?.currentTime == 100)
    #expect(try await remote.progress(itemID: "book", episodeID: nil)?.ebookLocation == "cfi")
    #expect(try await database.pendingSessions(partition: partition).isEmpty)
}

@Test func syncConflictsPauseAllHistoryUntilExplicitChoice() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-sync-test-" + UUID().uuidString).appendingPathComponent("db.sqlite")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.enqueue(syncSession(id: "one", update: 3000, position: 100), partition: partition)
    let remote = FakeSyncRemote(progress: SyncProgressSnapshot(itemID: "book", currentTime: 400, duration: 600, isFinished: false, updatedAt: 2500))
    let coordinator = SyncCoordinator(database: database)
    let report = try await coordinator.synchronize(partition: partition, remote: remote)
    #expect(report.conflicts.count == 1)
    #expect(await remote.uploads().isEmpty)
    #expect(try await database.pendingSessions(partition: partition).count == 1)
    try await coordinator.resolve(try #require(report.conflicts.first), choice: .remote, partition: partition, remote: remote)
    #expect(try await remote.progress(itemID: "book", episodeID: nil)?.currentTime == 400)
    #expect(try await database.pendingSessions(partition: partition).isEmpty)
    #expect(try await database.conflicts(partition: partition).isEmpty)
}

@Test func syncNetworkFailureRetainsOriginalHistory() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-sync-test-" + UUID().uuidString).appendingPathComponent("db.sqlite")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    let session = syncSession(id: "one", update: 3000, position: 100)
    try await database.enqueue(session, partition: partition)
    let remote = FakeSyncRemote(progress: nil)
    await remote.setFailure()
    await #expect(throws: URLError.self) { try await SyncCoordinator(database: database).synchronize(partition: partition, remote: remote) }
    #expect(try await database.pendingSessions(partition: partition) == [session])
}

@Test func ebookOnlyUpdatesDoNotConflictAndBackwardSeekIsRetained() {
    let session = syncSession(id: "one", update: 3000, position: 20)
    let remote = SyncProgressSnapshot(itemID: "book", currentTime: 50, duration: 600, isFinished: false, updatedAt: 2500, ebookLocation: "new-cfi", ebookProgress: 0.7)
    #expect(!OfflineSyncPolicy.conflicts(local: session, remote: remote))
    #expect(OfflineSyncPolicy.ordered([session, syncSession(id: "older", update: 2000, position: 500)]).first?.currentTime == 20)
}

@Test func downloadRangeParserRejectsInvalidServerRanges() {
    #expect(DownloadTransfer.contentRange("bytes 4-9/10")?.start == 4)
    #expect(DownloadTransfer.contentRange("bytes 4-9/10")?.total == 10)
    #expect(DownloadTransfer.contentRange("bytes */10") == nil)
    #expect(DownloadTransfer.contentRange("items 4-9/10") == nil)
    #expect(DownloadTransfer.contentRange("bytes 10-11/10") == nil)
}

@Test func syncDoesNotUploadStillOpenRemoteSessionJournal() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-sync-test-" + UUID().uuidString).appendingPathComponent("db.sqlite")
    defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "user")
    try await database.enqueue(syncSession(id: "active", update: 3000, position: 100), partition: partition)
    let remote = FakeSyncRemote(progress: nil)
    let report = try await SyncCoordinator(database: database).synchronize(partition: partition, remote: remote, excludingSessionIDs: ["active"])
    #expect(report.uploaded == 0)
    #expect(await remote.uploads().isEmpty)
    #expect(try await database.pendingSessions(partition: partition).count == 1)
}
