import Foundation
import GRDB
import ShelfCore
import Testing
@testable import ShelfPlayback

private actor QuitJournal {
    var checkpointFails = false, journalFails = false
    var attempts = 0
    var attemptedSnapshots: [LocalPlaybackSession] = []
    var snapshots: [LocalPlaybackSession] = []
    var checkpoints: [MediaProgress] = []
    var gate: QuitGate?
    func fail(checkpoint: Bool, journal: Bool) { checkpointFails = checkpoint; journalFails = journal }
    func setGate(_ gate: QuitGate) { self.gate = gate }
    func checkpoint(_ value: MediaProgress) throws {
        if checkpointFails { throw OfflineStorageError.insufficientSpace }
        checkpoints.append(value)
    }
    func save(_ value: LocalPlaybackSession) async throws {
        attempts += 1; attemptedSnapshots.append(value)
        if let gate { self.gate = nil; await gate.wait() }
        if journalFails { throw OfflineStorageError.insufficientSpace }
        snapshots.append(value)
    }
}

private actor QuitGate {
    var entered = false, released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered = true; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor QuitService: PlaybackService {
    var syncFails = false, closeFails = false
    var closes: [Double] = []
    var syncs: [Double] = []
    var authorization: QuitGate?, closing: QuitGate?, syncing: QuitGate?
    let file: URL?
    init(file: URL? = nil, authorization: QuitGate? = nil, closing: QuitGate? = nil) {
        self.file = file; self.authorization = authorization; self.closing = closing
    }
    func setSyncGate(_ gate: QuitGate) { syncing = gate }
    func fail(sync: Bool = false, close: Bool = false) { syncFails = sync; closeFails = close }
    func prepare(media: PlaybackMedia) -> PreparedPlayback {
        .init(media: media, tracks: [.init(index: 0, url: file ?? URL(string: "https://synthetic.invalid/audio")!,
            duration: 20, startOffset: 0, isLocal: file != nil)], sessionID: "quit-session", initialPosition: 3)
    }
    func authorize(track: PlaybackTrack) async -> PlaybackTrack { await authorization?.wait(); return track }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        await syncing?.wait()
        syncs.append(timeListened); if syncFails { throw URLError(.notConnectedToInternet) }
    }
    func close(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        closes.append(timeListened); await closing?.wait()
        if closeFails { throw URLError(.notConnectedToInternet) }
    }
}

private func quitSnapshot() -> LocalPlaybackSession {
    .init(id: "quit-session", libraryItemId: "quit-book", duration: 20, currentTime: 8, startedAt: 1_000, updatedAt: 2_000, timeListening: 4)
}

@Test(arguments: [false, true], [false, true]) func quitReceiptSeparatesCheckpointFromCumulativeDurability(checkpointFails: Bool, journalFails: Bool) async {
    let journal = QuitJournal(); await journal.fail(checkpoint: checkpointFails, journal: journalFails)
    let reporter = PlaybackSessionReporter(service: nil, remoteSessionID: nil, persist: { try await journal.save($0) },
        checkpoint: { try await journal.checkpoint($0) }, acknowledge: nil)
    let receipt = await reporter.finalizeForQuit(quitSnapshot())
    #expect(receipt.sessionID == "quit-session" && !receipt.remoteCumulativeConfirmed)
    #expect(receipt.checkpointSaved == !checkpointFails)
    #expect(receipt.cumulativeSnapshotSaved == !journalFails && receipt.mayQuit == !journalFails)
    #expect((receipt.diagnostic == nil) == (!checkpointFails && !journalFails))
}

@Test(arguments: [false, true]) func missingJournalCallbackCannotMakeOfflineQuitDurable(checkpointProvided: Bool) async {
    let reporter = PlaybackSessionReporter(service: nil, remoteSessionID: nil, persist: nil,
        checkpoint: checkpointProvided ? { @Sendable _ in } : nil, acknowledge: nil)
    let receipt = await reporter.finalizeForQuit(quitSnapshot())
    #expect(!receipt.mayQuit && !receipt.cumulativeSnapshotSaved && !receipt.remoteCumulativeConfirmed)
    #expect(receipt.checkpointSaved == checkpointProvided)
    #expect(receipt.diagnostic?.code == "playback.finalSnapshotNotDurable")
}

@Test func confirmedFinalDeltaRemainsSafeAfterAcknowledgementFailureWithoutReplay() async {
    let service = QuitService()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { _ in throw OfflineStorageError.insufficientSpace }, checkpoint: { _ in throw OfflineStorageError.insufficientSpace },
        acknowledge: { _ in throw OfflineStorageError.insufficientSpace })
    let first = await reporter.finalizeForQuit(quitSnapshot())
    let repeated = await reporter.finalizeForQuit(quitSnapshot())
    #expect(first.mayQuit && repeated.mayQuit && first.remoteCumulativeConfirmed && repeated.remoteCumulativeConfirmed)
    #expect(!first.cumulativeSnapshotSaved && first.diagnostic != nil)
    #expect(await service.closes == [4])
}

@Test func uncertainSyncAndConfirmedCloseZeroStillRequireDurableCumulativeRecovery() async {
    let service = QuitService(), journal = QuitJournal()
    await service.fail(sync: true); await journal.fail(checkpoint: false, journal: true)
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { try await journal.save($0) }, checkpoint: { try await journal.checkpoint($0) }, acknowledge: nil)
    #expect(await reporter.submit(quitSnapshot()) != nil)
    let failed = await reporter.finalizeForQuit(quitSnapshot())
    #expect(!failed.mayQuit && failed.checkpointSaved && !failed.remoteCumulativeConfirmed)
    await journal.fail(checkpoint: false, journal: false)
    let retry = await reporter.finalizeForQuit(quitSnapshot())
    #expect(retry.mayQuit && retry.cumulativeSnapshotSaved && !retry.remoteCumulativeConfirmed)
    let syncs = await service.syncs, closes = await service.closes
    #expect(syncs == [4] && closes == [0])
    #expect(await journal.snapshots == [quitSnapshot()])
}

@Test func failedRemoteCloseWithDurableJournalAllowsOfflineQuit() async {
    let service = QuitService(), journal = QuitJournal(); await service.fail(close: true)
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { try await journal.save($0) }, checkpoint: nil, acknowledge: nil)
    let receipt = await reporter.finalizeForQuit(quitSnapshot())
    #expect(receipt.mayQuit && receipt.cumulativeSnapshotSaved && !receipt.remoteCumulativeConfirmed)
    #expect(receipt.diagnostic != nil && !receipt.checkpointSaved)
}

@Test func externallyClosedSessionStillRequiresItsLocalCumulativeSnapshot() async {
    let service = QuitService(), journal = QuitJournal(); await journal.fail(checkpoint: false, journal: true)
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { try await journal.save($0) }, checkpoint: nil, acknowledge: nil)
    await reporter.markRemoteSessionClosed()
    #expect(!(await reporter.finalizeForQuit(quitSnapshot())).mayQuit)
    await journal.fail(checkpoint: false, journal: false)
    #expect((await reporter.finalizeForQuit(quitSnapshot())).mayQuit)
    let closes = await service.closes, syncs = await service.syncs
    #expect(closes.isEmpty && syncs.isEmpty)
}

private func quitWAV() throws -> URL {
    let byteCount = 320_000
    var bytes = Data()
    func word(_ value: UInt16) { var x = value.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) } }
    func long(_ value: UInt32) { var x = value.littleEndian; withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) } }
    bytes.append(contentsOf: "RIFF".utf8); long(UInt32(36 + byteCount)); bytes.append(contentsOf: "WAVEfmt ".utf8)
    long(16); word(1); word(1); long(8000); long(16000); word(2); word(16)
    bytes.append(contentsOf: "data".utf8); long(UInt32(byteCount)); bytes.append(Data(count: byteCount))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-quit-" + UUID().uuidString + ".wav")
    try bytes.write(to: file); return file
}

private enum QuitTimeout: Error { case waiting }
@MainActor private func quitWait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard await predicate() else { throw QuitTimeout.waiting }
}

@Test @MainActor func failedExplicitQuitFreezesOneSnapshotAndCanRetryWithoutReplacement() async throws {
    let file = try quitWAV(), journal = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) }, checkpoint: { try await journal.checkpoint($0) })
    let media = PlaybackMedia(itemID: "quit-book", title: "Quit", duration: 20)
    let tracks: [PlaybackTrack] = [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)]
    await controller.playOffline(media: media, tracks: tracks, initialPosition: 3)
    let id = try #require(controller.currentSessionID)
    await journal.fail(checkpoint: true, journal: true)
    let failed = await controller.shutdownForQuit(), position = controller.position, listened = controller.timeListening
    let frozen = try #require(await journal.attemptedSnapshots.last)
    if frozen.currentTime != position || frozen.timeListening != listened {
        print("QUIT_FREEZE_DIFFERENCE snapshotID=\(frozen.id) visibleID=\(id) snapshotPosition=\(frozen.currentTime) visiblePosition=\(position) snapshotListening=\(frozen.timeListening) visibleListening=\(listened)")
    }
    #expect(frozen.id == id)
    #expect(frozen.currentTime == position)
    #expect(frozen.timeListening == listened)
    #expect(!failed.mayQuit && failed.sessionID == id)
    #expect(controller.currentMedia == media && controller.errorDiagnostic != nil && !controller.isPlaybackRequested)
    controller.resume(); await controller.stop(); await controller.configure(service: nil)
    await controller.playOffline(media: .init(itemID: "replacement", title: "Replacement"), tracks: tracks)
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.currentMedia == media && controller.currentSessionID == id && !controller.isPlaying)
    #expect(controller.position == position && controller.timeListening == listened)
    await journal.fail(checkpoint: false, journal: false)
    let retry = await controller.shutdownForQuit()
    #expect(retry.mayQuit && retry.sessionID == id && controller.currentMedia == nil)
    let final = try #require(await journal.snapshots.last)
    #expect(final == frozen)
    #expect(final.id == id)
    #expect(final.currentTime == position)
    #expect(final.timeListening == listened)
}

@Test @MainActor func concurrentExplicitQuitsShareOneFinalization() async throws {
    let file = try quitWAV(), journal = QuitJournal(), gate = QuitGate()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) })
    await controller.playOffline(media: .init(itemID: "coalesced", title: "Coalesced", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    await journal.setGate(gate)
    let first = Task { await controller.shutdownForQuit() }
    try await quitWait { await gate.entered }
    let second = Task { await controller.shutdownForQuit() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.currentMedia != nil)
    await gate.release()
    let firstReceipt = await first.value, secondReceipt = await second.value
    #expect(firstReceipt.mayQuit && secondReceipt.mayQuit)
    #expect(await journal.snapshots.count == 2)
    #expect(controller.currentMedia == nil)
}

private actor QuitCompletion { var done = false; func finish() { done = true } }
@Test @MainActor func explicitQuitDrainsPreviouslyDetachedOrdinaryStopAndBlocksNewPlayback() async throws {
    let authorization = QuitGate(), closing = QuitGate(), completion = QuitCompletion()
    let service = QuitService(authorization: authorization, closing: closing)
    let controller = PlaybackController(service: service)
    let preparing = Task { await controller.play(media: .init(itemID: "draining", title: "Draining", duration: 20)) }
    try await quitWait { await authorization.entered }
    let stopping = Task { await controller.stop() }
    try await quitWait { await closing.entered }
    let quitting = Task { let result = await controller.shutdownForQuit(); await completion.finish(); return result }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await completion.done) && controller.finalizingSessionIDs == ["quit-session"])
    await controller.play(media: .init(itemID: "replacement", title: "Replacement"))
    #expect(controller.currentMedia == nil)
    await closing.release(); await stopping.value
    #expect(await quitting.value.mayQuit)
    #expect(controller.finalizingSessionIDs.isEmpty)
    await authorization.release(); await preparing.value
    let closes = await service.closes
    #expect(controller.currentMedia == nil && closes.count == 1)
}

@Test @MainActor func quitDuringManagementFlushIsRetryableWithoutDetachingActiveReporter() async throws {
    let authorization = QuitGate(), syncing = QuitGate()
    let service = QuitService(authorization: authorization)
    let controller = PlaybackController(service: service)
    let preparing = Task { await controller.play(media: .init(itemID: "management", title: "Management", duration: 20)) }
    try await quitWait { await authorization.entered }
    await service.setSyncGate(syncing)
    let mutation = Task { try await controller.prepareServerSessionMutation(sessionID: "quit-session") }
    try await quitWait { await syncing.entered }
    let quitting = Task { await controller.shutdownForQuit() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.currentSessionID == "quit-session")
    await syncing.release()
    let rejected = await quitting.value
    #expect(!rejected.mayQuit)
    #expect(try await mutation.value)
    #expect((await controller.shutdownForQuit()).mayQuit)
    #expect(await service.closes.isEmpty)
    await authorization.release(); await preparing.value
}

@Test @MainActor func ordinaryStopFailureSurvivesQuitAndRetriesFrozenSnapshot() async throws {
    let file = try quitWAV(), journal = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) }, checkpoint: { try await journal.checkpoint($0) })
    await controller.playOffline(media: .init(itemID: "stopped", title: "Stopped", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)], initialPosition: 5)
    let id = try #require(controller.currentSessionID)
    await journal.fail(checkpoint: true, journal: true)
    await controller.stop()
    #expect(controller.currentMedia == nil && controller.finalizingSessionIDs == [id])
    let frozen = try #require(await journal.attemptedSnapshots.last)
    #expect(!(await controller.shutdownForQuit()).mayQuit)
    await journal.fail(checkpoint: false, journal: false)
    #expect((await controller.shutdownForQuit()).mayQuit)
    #expect(controller.finalizingSessionIDs.isEmpty)
    let saved = try #require(await journal.snapshots.last)
    #expect(saved == frozen && saved.id == id && saved.currentTime >= 5)
    #expect(await journal.attemptedSnapshots.dropFirst().allSatisfy { $0 == frozen })
}

@Test(arguments: [false, true]) @MainActor func failedFinalizationBlocksReplacementAndKeepsOriginalPersistence(configure: Bool) async throws {
    let file = try quitWAV(), old = QuitJournal(), replacement = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await old.save($0) })
    let tracks: [PlaybackTrack] = [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)]
    await controller.playOffline(media: .init(itemID: "original", title: "Original", duration: 20), tracks: tracks)
    let id = try #require(controller.currentSessionID)
    await old.fail(checkpoint: false, journal: true)
    if configure { await controller.configure(service: nil, persist: { try await replacement.save($0) }) }
    await controller.playOffline(media: .init(itemID: "replacement", title: "Replacement", duration: 20), tracks: tracks)
    #expect(controller.currentMedia == nil && controller.finalizingSessionIDs == [id])
    #expect(await replacement.snapshots.isEmpty)
    await old.fail(checkpoint: false, journal: false)
    await controller.playOffline(media: .init(itemID: "replacement", title: "Replacement", duration: 20), tracks: tracks)
    #expect(controller.currentMedia?.itemID == "replacement" && controller.finalizingSessionIDs.isEmpty)
    #expect(await old.snapshots.contains { $0.id == id })
    #expect(await replacement.snapshots.isEmpty)
    await controller.shutdown()
}

@Test @MainActor func adoptedPrepareCancelledAfterStopDoesNotCloseTwice() async throws {
    let authorization = QuitGate(), service = QuitService()
    let gatedService = QuitService(authorization: authorization)
    let controller = PlaybackController(service: gatedService)
    let preparing = Task { await controller.play(media: .init(itemID: "adopted", title: "Adopted", duration: 20)) }
    try await quitWait { await authorization.entered }
    await controller.stop()
    preparing.cancel(); await authorization.release(); await preparing.value
    #expect(await gatedService.closes.count == 1)
    await controller.configure(service: service)
    await controller.shutdown()
}

@Test @MainActor func failedOrdinaryShutdownAndConcurrentQuitKeepOneRetryBundle() async throws {
    let file = try quitWAV(), journal = QuitJournal(), gate = QuitGate()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) })
    await controller.playOffline(media: .init(itemID: "shutdown", title: "Shutdown", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    let id = try #require(controller.currentSessionID)
    await journal.fail(checkpoint: false, journal: true); await journal.setGate(gate)
    let stopping = Task { await controller.shutdown() }
    try await quitWait { await gate.entered }
    let quitting = Task { await controller.shutdownForQuit() }
    try await Task.sleep(for: .milliseconds(20))
    await gate.release(); await stopping.value
    #expect(!(await quitting.value).mayQuit)
    #expect(await journal.attempts == 2)
    #expect(controller.finalizingSessionIDs == [id])
    await journal.fail(checkpoint: false, journal: false)
    #expect((await controller.shutdownForQuit()).mayQuit)
    #expect(await journal.attempts == 3)
    #expect(controller.finalizingSessionIDs.isEmpty)
}

@Test @MainActor func failedNextTrackFinalizationKeepsQueueForRetry() async throws {
    let file = try quitWAV(), journal = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(service: QuitService(file: file), persist: { try await journal.save($0) })
    await controller.playOffline(media: .init(itemID: "queue-original", title: "Original", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    let next = PlaybackMedia(itemID: "queue-next", title: "Next", duration: 20)
    controller.enqueue(next)
    await journal.fail(checkpoint: false, journal: true)
    await controller.playNext()
    #expect(controller.queue == [next] && controller.currentMedia == nil)
    await journal.fail(checkpoint: false, journal: false)
    await controller.playNext()
    #expect(controller.currentMedia == next && controller.queue.isEmpty)
    #expect((await controller.shutdownForQuit()).mayQuit)
}

@Test @MainActor func nextTrackUsesLiveQueueAfterDurabilityAwait() async throws {
    let file = try quitWAV(), journal = QuitJournal(), gate = QuitGate()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(service: QuitService(file: file), persist: { try await journal.save($0) })
    await controller.playOffline(media: .init(itemID: "live-original", title: "Original", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    let removed = PlaybackMedia(itemID: "removed", title: "Removed", duration: 20)
    let desired = PlaybackMedia(itemID: "desired", title: "Desired", duration: 20)
    let later = PlaybackMedia(itemID: "later", title: "Later", duration: 20)
    controller.enqueue(removed); controller.enqueue(desired)
    await journal.setGate(gate)
    let advancing = Task { await controller.playNext() }
    try await quitWait { await gate.entered }
    controller.removeFromQueue(at: IndexSet(integer: 0)); controller.enqueue(later)
    await gate.release(); await advancing.value
    #expect(controller.currentMedia == desired && controller.queue == [later])
    #expect((await controller.shutdownForQuit()).mayQuit)
}

@Test @MainActor func transferredFailureOutlivesControllerAndNeverUsesReplacementPersistence() async throws {
    let file = try quitWAV(), original = QuitJournal(), replacement = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    var player: PlaybackController? = PlaybackController(persist: { try await original.save($0) })
    await player!.playOffline(media: .init(itemID: "retired", title: "Retired", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    await original.fail(checkpoint: false, journal: true)
    await player!.stop()
    let frozen = try #require(await original.attemptedSnapshots.last)
    let handles = player!.detachForRecovery(); player = nil
    #expect(handles.count == 1)
    let handle = try #require(handles.first)
    await handle.retireToLocalRecovery()
    #expect(!(await handle.finalize()).mayQuit)
    let newPlayer = PlaybackController(persist: { try await replacement.save($0) })
    await original.fail(checkpoint: false, journal: false)
    #expect((await handle.finalize()).cumulativeSnapshotSaved)
    #expect(await original.snapshots.last == frozen)
    #expect(await replacement.snapshots.isEmpty)
    await newPlayer.shutdown()
}

@Test @MainActor func retirementWhileCloseIsSuspendedSuppressesLateAcknowledgement() async throws {
    let gate = QuitGate(), journal = QuitJournal()
    let closingService = QuitService(closing: gate)
    let acknowledgements = QuitJournal()
    let reporter = PlaybackSessionReporter(service: closingService, remoteSessionID: "quit-session",
        persist: { try await journal.save($0) }, checkpoint: nil, acknowledge: { _ in try await acknowledgements.save(quitSnapshot()) })
    let handle = PlaybackRecoveryHandle(snapshot: quitSnapshot(), reporter: reporter)
    let finalizing = Task { await handle.finalize() }
    try await quitWait { await gate.entered }
    await handle.retireToLocalRecovery()
    await gate.release()
    let receipt = await finalizing.value
    #expect(receipt.cumulativeSnapshotSaved && !receipt.remoteCumulativeConfirmed)
    #expect(await acknowledgements.snapshots.isEmpty)
    #expect(await closingService.closes == [4])
    #expect((await handle.finalize()).cumulativeSnapshotSaved)
    #expect(await journal.attempts == 1)
}

@Test @MainActor func retiredHandleRequiresLocalSnapshotEvenAfterConfirmedRemoteClose() async throws {
    let service = QuitService(), journal = QuitJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { try await journal.save($0) }, checkpoint: nil, acknowledge: nil)
    let handle = PlaybackRecoveryHandle(snapshot: quitSnapshot(), reporter: reporter)
    #expect((await handle.finalize()).remoteCumulativeConfirmed)
    await journal.fail(checkpoint: false, journal: true)
    await handle.retireToLocalRecovery()
    #expect(!(await handle.finalize()).mayQuit)
    await journal.fail(checkpoint: false, journal: false)
    #expect((await handle.finalize()).cumulativeSnapshotSaved)
    #expect(await service.closes == [4])
}

@MainActor private final class RecoveryAttribution {
    var baseline = MediaProgress(libraryItemId: "attributed", currentTime: 11, lastUpdate: 1000)
    var deviceID = "original-device"
}

@Test @MainActor func realSQLiteTransferredSnapshotFreezesBaselineAndDeviceAtSessionAdoption() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-recovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try quitWAV(); defer { try? FileManager.default.removeItem(at: file) }
    let path = root.appendingPathComponent("Shelf.sqlite"), attribution = RecoveryAttribution()
    let database = try ShelfDatabase(path: path)
    let partition = AccountPartition(serverID: UUID(), userID: "original")
    let sql = try DatabaseQueue(path: path.path)
    try await sql.write { try $0.execute(sql: "CREATE TRIGGER fail_pending BEFORE INSERT ON offlineSession BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END") }
    var controller: PlaybackController? = PlaybackController(persistenceFactory: { _ in
        let baseline = attribution.baseline, deviceID = attribution.deviceID
        return { snapshot, ownAcknowledgement in
            var attributed = snapshot; attributed.deviceInfo = .init(deviceId: deviceID)
            try await database.enqueue(attributed, partition: partition, baseline: baseline, ownAcknowledgement: ownAcknowledgement)
        }
    })
    await controller!.playOffline(media: .init(itemID: "attributed", title: "Attributed", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    attribution.baseline = .init(libraryItemId: "attributed", currentTime: 99, lastUpdate: 9000)
    attribution.deviceID = "replacement-device"
    let handles = controller!.detachForRecovery(); controller = nil
    let handle = try #require(handles.first)
    await handle.retireToLocalRecovery()
    #expect(!(await handle.finalize()).mayQuit)
    try await sql.write { try $0.execute(sql: "DROP TRIGGER fail_pending") }
    #expect((await handle.finalize()).cumulativeSnapshotSaved)
    let row = try #require(try await database.pendingSessions(partition: partition).first)
    #expect(row.serverCurrentTime == 11 && row.serverProgressUpdatedAt == 1000)
    let payload = try JSONDecoder().decode(LocalPlaybackSession.self, from: #require(row.sessionPayload))
    #expect(payload.deviceInfo.deviceId == "original-device")
    #expect(try await database.pendingSessions(partition: .init(serverID: partition.serverID, userID: "replacement")).isEmpty)
}

@Test @MainActor func realSQLiteRetiredRecoveryHonorsCollectingAndSealedEpochs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-recovery-restore-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("Shelf.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "original")
    let batch = try await database.beginServerRestore(.init(canonicalBaseURL: "https://synthetic.invalid/", profileIDs: [partition.serverID], origin: .observed))
    func handle() -> PlaybackRecoveryHandle {
        PlaybackRecoveryHandle(snapshot: quitSnapshot(), reporter: PlaybackSessionReporter(service: nil, remoteSessionID: nil,
            persist: { try await database.enqueue($0, partition: partition) }, checkpoint: { try await database.saveResume($0, partition: partition) }, acknowledge: nil))
    }
    let collecting = handle(); await collecting.retireToLocalRecovery()
    #expect((await collecting.finalize()).cumulativeSnapshotSaved)
    let receipt = try await database.archiveForServerRestore(batchID: batch.id)
    #expect(receipt.counts["shelf.offlineSession"] == 1)
    let late = handle(); await late.retireToLocalRecovery()
    #expect(!(await late.finalize()).mayQuit)
    let archived = try await database.archiveSnapshot(batchID: batch.id)
    #expect(archived.entries.filter { $0.category == "shelf.offlineSession" }.count == 1)
}

@Test @MainActor func realSQLiteRetirementDuringAcknowledgementPreservesCollectingSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-recovery-ack-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ShelfDatabase(path: root.appendingPathComponent("Shelf.sqlite"))
    let partition = AccountPartition(serverID: UUID(), userID: "original"), service = QuitService(), ack = QuitGate()
    try await database.enqueue(quitSnapshot(), partition: partition)
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "quit-session",
        persist: { try await database.enqueue($0, partition: partition) }, checkpoint: nil,
        acknowledge: { id in await ack.wait(); try await database.removePendingSession(id: id, partition: partition) })
    let handle = PlaybackRecoveryHandle(snapshot: quitSnapshot(), reporter: reporter)
    let closing = Task { await handle.finalize() }
    try await quitWait { await ack.entered }
    let batch = try await database.beginServerRestore(.init(canonicalBaseURL: "https://synthetic.invalid/", profileIDs: [partition.serverID], origin: .observed))
    await handle.retireToLocalRecovery(); await ack.release()
    #expect((await closing.value).cumulativeSnapshotSaved)
    let archive = try await database.archiveForServerRestore(batchID: batch.id)
    #expect(archive.counts["shelf.offlineSession"] == 1)
    #expect(await service.closes == [4])
}

@Test @MainActor func voluntaryTransitionCheckpointCanRetryAndControllerRemainsReusable() async throws {
    let file = try quitWAV(), journal = QuitJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) })
    let tracks: [PlaybackTrack] = [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)]
    await controller.playOffline(media: .init(itemID: "old-account", title: "Old", duration: 20), tracks: tracks)
    await journal.fail(checkpoint: false, journal: true)
    #expect(!(await controller.checkpointForTransition()).mayQuit)
    #expect(controller.currentMedia == nil && !controller.finalizingSessionIDs.isEmpty)
    await journal.fail(checkpoint: false, journal: false)
    #expect((await controller.checkpointForTransition()).mayQuit)
    // Authentication may now fail/cancel; the original account keeps its player.
    await controller.playOffline(media: .init(itemID: "still-old-account", title: "Still old", duration: 20), tracks: tracks)
    #expect(controller.currentMedia?.itemID == "still-old-account")
    #expect((await controller.shutdownForQuit()).mayQuit)
}

@Test @MainActor func suspendedQuitKeepsEngineObservationsAndTickerOutsideFrozenSnapshot() async throws {
    let file = try quitWAV(), journal = QuitJournal(), gate = QuitGate()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { try await journal.save($0) }, checkpoint: { try await journal.checkpoint($0) })
    await controller.playOffline(media: .init(itemID: "slow-quit", title: "Slow quit", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)], initialPosition: 3)
    await journal.fail(checkpoint: true, journal: true); await journal.setGate(gate)
    let quitting = Task { await controller.shutdownForQuit() }
    try await quitWait { await gate.entered }
    let frozen = try #require(await journal.attemptedSnapshots.last)
    // Cross the real controller's 500 ms tick while the final journal is suspended.
    try await Task.sleep(for: .milliseconds(650))
    if controller.position != frozen.currentTime || controller.timeListening != frozen.timeListening {
        print("SUSPENDED_QUIT_DIFFERENCE snapshotID=\(frozen.id) visibleID=\(controller.currentSessionID ?? "nil") snapshotPosition=\(frozen.currentTime) visiblePosition=\(controller.position) snapshotListening=\(frozen.timeListening) visibleListening=\(controller.timeListening)")
    }
    #expect(controller.currentSessionID == frozen.id)
    #expect(controller.position == frozen.currentTime)
    #expect(controller.timeListening == frozen.timeListening)
    #expect(!controller.isPlaying)
    await gate.release()
    #expect(!(await quitting.value).mayQuit)
    await journal.fail(checkpoint: false, journal: false)
    #expect((await controller.shutdownForQuit()).mayQuit)
    #expect(await journal.snapshots.last == frozen)
}

#if canImport(VLCKit)
@Test @MainActor func compatibilityPausedEndRetainsQueueAndResumeRestartsBeforeDurableQuit() async throws {
    // A local WAV payload with an unsupported extension exercises the real
    // compatibility route without adding a binary fixture or audible output.
    let original = try quitWAV()
    let file = original.deletingPathExtension().appendingPathExtension("wma")
    try FileManager.default.moveItem(at: original, to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let journal = QuitJournal()
    let controller = PlaybackController(persist: { try await journal.save($0) })
    let first = PlaybackMedia(itemID: "compatibility-first", title: "First", duration: 20)
    let next = PlaybackMedia(itemID: "compatibility-next", title: "Next", duration: 20)
    await controller.playOffline(media: first, tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)])
    controller.pause(); controller.enqueue(next)
    await controller.seek(to: 20)
    // Cross the real 500 ms Controller ticker that previously consumed the queue.
    try await Task.sleep(for: .milliseconds(650))
    #expect(controller.currentMedia == first && controller.queue == [next])
    #expect(controller.position == 20 && !controller.isPlaybackRequested)
    controller.resume()
    try await quitWait { controller.isPlaying && controller.position > 0 && controller.position < 10 }
    #expect(controller.currentMedia == first && controller.queue == [next])
    controller.pause()
    let position = controller.position, listening = controller.timeListening
    try await Task.sleep(for: .milliseconds(650))
    #expect(controller.position == position && controller.timeListening == listening)
    let receipt = await controller.shutdownForQuit()
    #expect(receipt.mayQuit)
    let final = await journal.snapshots.last
    #expect(final?.currentTime == position && final?.timeListening == listening)
}
#endif
