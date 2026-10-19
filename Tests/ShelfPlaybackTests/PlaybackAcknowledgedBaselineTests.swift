import Foundation
import Testing
import ShelfCore
@testable import ShelfPlayback

private actor AcknowledgedBaselineRemote: PlaybackService, OfflineSyncRemote {
    var failSync = false
    var saved: SyncProgressSnapshot
    var closes: [Double] = []
    var uploaded = 0
    init(position: Double = 10) {
        saved = .init(itemID: "ack-book", currentTime: position, duration: 100, isFinished: false, updatedAt: 1000)
    }
    func disconnect() { failSync = true }
    func setForeignPosition(_ position: Double) { saved.currentTime = position; saved.updatedAt = 2500 }
    func prepare(media: PlaybackMedia) throws -> PreparedPlayback { throw ABSError.sessionChanged }
    func authorize(track: PlaybackTrack) -> PlaybackTrack { track }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) throws {
        if failSync { throw URLError(.notConnectedToInternet) }
        saved.currentTime = currentTime; saved.updatedAt = 2000
    }
    func close(sessionID: String, currentTime: Double, timeListened: Double) {
        closes.append(timeListened); saved.currentTime = currentTime; saved.updatedAt = 3000
    }
    func progress(itemID: String, episodeID: String?) -> SyncProgressSnapshot? { saved }
    func upload(_ session: OfflinePlaybackSession) { uploaded += 1 }
    func setAudioPosition(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool) {
        saved.currentTime = currentTime; saved.duration = duration; saved.isFinished = isFinished
    }
}

private func acknowledgedSnapshot(_ position: Double, time: Double = 2000) -> LocalPlaybackSession {
    .init(id: "ack-session", libraryItemId: "ack-book", duration: 100, currentTime: position,
          startedAt: 1000, updatedAt: time, timeListening: position - 10)
}

private func acknowledgedDatabase() throws -> (ShelfDatabase, URL, AccountPartition) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-own-ack-" + UUID().uuidString)
    return (try ShelfDatabase(path: root.appendingPathComponent("db.sqlite")), root, .init(serverID: UUID(), userID: "synthetic"))
}

@Test(arguments: [false, true], [false, true])
func sameSessionOwnAcknowledgementPreventsOnlySelfConflict(hasBaseline: Bool, foreignChange: Bool) async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AcknowledgedBaselineRemote()
    let baseline: MediaProgress? = hasBaseline ? .init(libraryItemId: "ack-book", currentTime: 10, duration: 100, lastUpdate: 1000) : nil
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "ack-session", persist: nil, checkpoint: nil,
        acknowledge: { try await database.removePendingSession(id: $0, partition: partition) },
        recoveryPersist: { try await database.enqueue($0, partition: partition, baseline: baseline, ownAcknowledgement: $1) })
    #expect(await reporter.submit(acknowledgedSnapshot(30)) == nil)
    await service.disconnect()
    #expect(await reporter.submit(acknowledgedSnapshot(50, time: 3000)) != nil)
    let pending = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(pending.serverProgressUpdatedAt == baseline?.lastUpdate)
    #expect(pending.ownAcknowledgement?.currentTime == 30)
    if foreignChange { await service.setForeignPosition(70) }
    let report = try await SyncCoordinator(database: database).synchronize(partition: partition, remote: service)
    #expect(report.conflicts.count == (foreignChange ? 1 : 0))
    #expect(report.uploaded == (foreignChange ? 0 : 1))
}

@Test func acknowledgedBaselineSurvivesLocalAckFailureAndFreezesFirstPending() async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AcknowledgedBaselineRemote()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "ack-session", persist: nil, checkpoint: nil,
        acknowledge: { _ in throw OfflineStorageError.insufficientSpace },
        recoveryPersist: { try await database.enqueue($0, partition: partition, ownAcknowledgement: $1) })
    #expect(await reporter.submit(acknowledgedSnapshot(30)) != nil)
    #expect(await reporter.submit(acknowledgedSnapshot(50, time: 3000)) != nil)
    let first = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(first.ownAcknowledgement?.currentTime == 30)
    // A later caller/cache must not rebase an already pending recovery chain.
    try await database.enqueue(acknowledgedSnapshot(60, time: 4000), partition: partition,
        baseline: .init(libraryItemId: "ack-book", currentTime: 70, lastUpdate: 9000),
        ownAcknowledgement: .init(session: acknowledgedSnapshot(70)))
    let saved = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(saved.ownAcknowledgement == first.ownAcknowledgement)
    #expect(saved.serverProgressUpdatedAt == nil)
    #expect(saved.currentTime == 60)
    #expect(!OfflineSyncPolicy.conflicts(local: saved, remote: await service.progress(itemID: "ack-book", episodeID: nil)))
}

@Test(arguments: [false, true]) func ambiguousCloseZeroNeverBecomesOwnAcknowledgement(priorSuccess: Bool) async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AcknowledgedBaselineRemote()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "ack-session", persist: nil, checkpoint: nil, acknowledge: nil,
        recoveryPersist: { try await database.enqueue($0, partition: partition, ownAcknowledgement: $1) })
    if priorSuccess { #expect(await reporter.submit(acknowledgedSnapshot(30)) == nil) }
    await service.disconnect()
    _ = await reporter.submit(acknowledgedSnapshot(50, time: 3000))
    let receipt = await reporter.finalizeForQuit(acknowledgedSnapshot(60, time: 4000))
    let pending = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(await service.closes == [0])
    #expect(pending.ownAcknowledgement?.currentTime == (priorSuccess ? 30 : nil))
    #expect(!receipt.remoteCumulativeConfirmed && receipt.cumulativeSnapshotSaved)
}

@Test func successfulCloseEvidenceSurvivesLocalAcknowledgementFailure() async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AcknowledgedBaselineRemote()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "ack-session", persist: nil, checkpoint: nil,
        acknowledge: { _ in throw OfflineStorageError.insufficientSpace },
        recoveryPersist: { try await database.enqueue($0, partition: partition, ownAcknowledgement: $1) })
    let snapshot = acknowledgedSnapshot(30)
    _ = await reporter.finalizeForQuit(snapshot)
    _ = await reporter.finalizeForQuit(snapshot)
    let pending = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(pending.ownAcknowledgement?.currentTime == 30)
    #expect(await service.closes == [20])
}

@Test func acknowledgedBaselineProtectsServerFinishedFlagAndAccountIsolation() async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let ack = PlaybackSyncAcknowledgement(session: acknowledgedSnapshot(99))
    let snapshot = acknowledgedSnapshot(50, time: 3000)
    try await database.enqueue(snapshot, partition: partition, ownAcknowledgement: ack)
    let other = AccountPartition(serverID: partition.serverID, userID: "other")
    try await database.enqueue(snapshot, partition: other)
    let pending = try #require(try await database.pendingSessions(partition: partition).first)
    let otherPending = try #require(try await database.pendingSessions(partition: other).first)
    #expect(otherPending.ownAcknowledgement == nil)
    let finished = SyncProgressSnapshot(itemID: "ack-book", currentTime: 99, duration: 100, isFinished: true, updatedAt: 2000)
    #expect(OfflineSyncPolicy.conflicts(local: pending, remote: finished))
    // Own evidence belongs only in local journal metadata, never the ABS upload body.
    let wire = try #require(pending.sessionPayload)
    #expect(!String(decoding: wire, as: UTF8.self).contains("ownAcknowledgement"))
    let roundTrip = try JSONDecoder().decode(OfflinePlaybackSession.self, from: JSONEncoder().encode(pending))
    #expect(roundTrip.ownAcknowledgement == ack)
    var wrongIdentity = snapshot; wrongIdentity.id = "other-session"
    await #expect(throws: OfflineStorageError.invalidSession) {
        try await database.enqueue(wrongIdentity, partition: partition, ownAcknowledgement: ack)
    }
}

@Test(arguments: [false, true], [false, true])
func acknowledgedRecoveryChainSurvivesSQLiteReopen(hasBaseline: Bool, foreignChange: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-ack-reopen-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("db.sqlite")
    let partition = AccountPartition(serverID: UUID(), userID: "synthetic")
    let baseline: MediaProgress? = hasBaseline ? .init(libraryItemId: "ack-book", currentTime: 10, duration: 100, lastUpdate: 1000) : nil
    let service = AcknowledgedBaselineRemote()
    do {
        let original = try ShelfDatabase(path: path)
        let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "ack-session", persist: nil, checkpoint: nil,
            acknowledge: { try await original.removePendingSession(id: $0, partition: partition) },
            recoveryPersist: { try await original.enqueue($0, partition: partition, baseline: baseline, ownAcknowledgement: $1) })
        #expect(await reporter.submit(acknowledgedSnapshot(30)) == nil)
        await service.disconnect()
        #expect(await reporter.submit(acknowledgedSnapshot(50, time: 3000)) != nil)
    }
    // Construct a new store and a new offline reporter: no in-memory ownAck survives.
    let reopened = try ShelfDatabase(path: path)
    let newReporter = PlaybackSessionReporter(service: nil, remoteSessionID: nil, persist: nil, checkpoint: nil, acknowledge: nil,
        recoveryPersist: { try await reopened.enqueue($0, partition: partition, baseline: baseline, ownAcknowledgement: $1) })
    let next = LocalPlaybackSession(id: "next-offline", libraryItemId: "ack-book", duration: 100, currentTime: 60,
                                    startedAt: 4000, updatedAt: 5000, timeListening: 10)
    #expect(await newReporter.submit(next) == nil)
    let rows = try await reopened.pendingSessions(partition: partition)
    #expect(rows.count == 2)
    #expect(rows.first(where: { $0.id == next.id })?.ownAcknowledgement == nil)
    #expect(rows.first(where: { $0.id == "ack-session" })?.ownAcknowledgement?.sessionID == "ack-session")
    if foreignChange { await service.setForeignPosition(70) }
    let report = try await SyncCoordinator(database: reopened).synchronize(partition: partition, remote: service)
    #expect(report.uploaded == (foreignChange ? 0 : 2))
    #expect(report.conflicts.count == (foreignChange ? 1 : 0))
    #expect(try await reopened.pendingSessions(partition: partition).count == (foreignChange ? 2 : 0))
}

@Test(arguments: [false, true]) func acknowledgedRecoveryChainCannotCrossAccountOrEpisode(otherAccount: Bool) async throws {
    let (database, root, partition) = try acknowledgedDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let baseline = MediaProgress(libraryItemId: "ack-book", currentTime: 10, duration: 100, lastUpdate: 1000)
    var old = acknowledgedSnapshot(50, time: 3000)
    var acknowledged = acknowledgedSnapshot(30)
    if !otherAccount { old.episodeId = "other-episode"; acknowledged.episodeId = "other-episode" }
    let originPartition = otherAccount ? AccountPartition(serverID: partition.serverID, userID: "other") : partition
    try await database.enqueue(old, partition: originPartition, baseline: baseline, ownAcknowledgement: .init(session: acknowledged))
    let next = LocalPlaybackSession(id: "new-offline", libraryItemId: "ack-book", duration: 100, currentTime: 60,
                                    startedAt: 4000, updatedAt: 5000, timeListening: 10)
    try await database.enqueue(next, partition: partition, baseline: baseline)
    let remote = AcknowledgedBaselineRemote(position: 30)
    await remote.setForeignPosition(30)
    let report = try await SyncCoordinator(database: database).synchronize(partition: partition, remote: remote)
    #expect(report.conflicts.contains(where: { $0.local.id == next.id }))
    #expect(try await database.pendingSessions(partition: partition).contains(where: { $0.id == next.id }))
}
