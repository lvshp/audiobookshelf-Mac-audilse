import Foundation
import ShelfCore
import Testing
@testable import ShelfPlayback

private actor ReporterSyncGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor MockPlaybackService: PlaybackService {
    struct Event: Equatable, Sendable {
        var closing: Bool
        var position: Double
        var listened: Double
    }
    var events: [Event] = []
    var failNext = false
    let gate: ReporterSyncGate?
    init(gate: ReporterSyncGate? = nil) { self.gate = gate }
    func prepare(media: PlaybackMedia) async throws -> PreparedPlayback { throw PlaybackFailure.noTracks }
    func authorize(track: PlaybackTrack) async throws -> PlaybackTrack { track }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        events.append(Event(closing: false, position: currentTime, listened: timeListened))
        await gate?.wait()
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
    }
    func close(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        events.append(Event(closing: true, position: currentTime, listened: timeListened))
    }
    func setFailure() { failNext = true }
}

private actor MemoryJournal {
    var saved: [LocalPlaybackSession] = []
    var acknowledged: [String] = []
    func save(_ snapshot: LocalPlaybackSession) { saved.append(snapshot) }
    func ack(_ id: String) { acknowledged.append(id) }
}

private func snapshot(position: Double, listened: Double, updatedAt: Double = 2_000) -> LocalPlaybackSession {
    LocalPlaybackSession(id: "stable-id", libraryItemId: "book-id", duration: 1_000,
                         currentTime: position, startedAt: 1_000, updatedAt: updatedAt, timeListening: listened)
}

@Test func onlineReporterSendsDeltasIncludingClose() async {
    let service = MockPlaybackService()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id", persist: nil, checkpoint: nil, acknowledge: nil)
    #expect(await reporter.submit(snapshot(position: 100, listened: 5)) == nil)
    // A seek to 900 seconds adds no listening time.
    #expect(await reporter.submit(snapshot(position: 900, listened: 5)) == nil)
    #expect(await reporter.submit(snapshot(position: 903, listened: 8), closing: true) == nil)
    let events = await service.events
    #expect(events == [.init(closing: false, position: 100, listened: 5), .init(closing: false, position: 900, listened: 0), .init(closing: true, position: 903, listened: 3)])
}

@Test func offlineReporterPreservesOriginalIdentityAndTimestamps() async {
    let journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: nil, remoteSessionID: nil,
                                           persist: { await journal.save($0) }, checkpoint: nil, acknowledge: nil)
    let original = snapshot(position: 20, listened: 10, updatedAt: 1_500)
    #expect(await reporter.submit(original) == nil)
    #expect(await reporter.submit(original, closing: true) == nil)
    #expect(await journal.saved == [original, original])
}

@Test func failedOnlineSyncNeverResendsUncertainDeltaAndPersistsCumulativeRecovery() async {
    let service = MockPlaybackService()
    let journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id",
                                           persist: { await journal.save($0) }, checkpoint: nil,
                                           acknowledge: { await journal.ack($0) })
    await service.setFailure()
    let original = snapshot(position: 20, listened: 10)
    #expect(await reporter.submit(original) != nil)
    #expect(await journal.saved == [original])
    #expect(await reporter.submit(snapshot(position: 23, listened: 13)) != nil)
    _ = await reporter.submit(snapshot(position: 24, listened: 14), closing: true)
    let events = await service.events
    #expect(events.map(\.listened) == [10, 0])
    #expect(events.last?.closing == true)
    #expect(await journal.saved.map(\.timeListening) == [10, 13, 14])
    #expect(await journal.acknowledged.isEmpty)
}

@Test func managementFlushDoesNotCloseOrRecreateJournalAfterConfirmedSync() async {
    let service = MockPlaybackService(), journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id", persist: { await journal.save($0) }, checkpoint: nil,
                                           acknowledge: { await journal.ack($0) })
    #expect(await reporter.submit(snapshot(position: 10, listened: 2)) == nil)
    #expect(await reporter.flushForServerMutation(snapshot(position: 13, listened: 5)) == nil)
    _ = await reporter.submit(snapshot(position: 14, listened: 6), closing: true)
    let events = await service.events
    #expect(events == [.init(closing: false, position: 10, listened: 2), .init(closing: false, position: 13, listened: 3)])
    #expect(await journal.saved.isEmpty)
    #expect(await journal.acknowledged == ["stable-id", "stable-id"])
}

@Test func uncertainManagementFlushRetainsRecoveryAndCannotDetach() async {
    let service = MockPlaybackService(), journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id", persist: { await journal.save($0) }, checkpoint: nil, acknowledge: nil)
    await service.setFailure()
    #expect(await reporter.flushForServerMutation(snapshot(position: 10, listened: 2)) != nil)
    #expect(await reporter.flushForServerMutation(snapshot(position: 10, listened: 2)) != nil)
    _ = await reporter.submit(snapshot(position: 11, listened: 3), closing: true)
    #expect(await service.events.map(\.listened) == [2, 0])
    #expect(await journal.saved.last?.currentTime == 11)
}

@Test func remotelyClosedReporterPreservesCumulativeSnapshotWithoutAnotherRemoteWrite() async {
    let service = MockPlaybackService(), journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id", persist: { await journal.save($0) }, checkpoint: nil,
                                           acknowledge: { await journal.ack($0) })
    #expect(await reporter.submit(snapshot(position: 10, listened: 2)) == nil)
    #expect(await reporter.preserveAfterRemoteClosure(snapshot(position: 13, listened: 5)) == nil)
    _ = await reporter.submit(snapshot(position: 13, listened: 5), closing: true)
    #expect(await service.events.count == 1)
    #expect(await journal.saved.last?.currentTime == 13)
    #expect(await journal.saved.last?.timeListening == 5)
    #expect(await journal.acknowledged == ["stable-id"])
}

@Test func remoteCloseDuringManagementFlushPreventsDetachAndLateAcknowledgement() async throws {
    let gate = ReporterSyncGate(), service = MockPlaybackService(gate: gate), journal = MemoryJournal()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable-id", persist: { await journal.save($0) }, checkpoint: nil,
                                           acknowledge: { await journal.ack($0) })
    let flush = Task { await reporter.flushForServerMutation(snapshot(position: 10, listened: 2)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    await reporter.markRemoteSessionClosed()
    let preserve = Task { await reporter.preserveAfterRemoteClosure(snapshot(position: 13, listened: 5)) }
    await gate.release()
    #expect(await flush.value?.code == "abs.sessionChanged")
    #expect(await preserve.value == nil)
    #expect(await service.events.count == 1)
    #expect(await journal.acknowledged.isEmpty)
    #expect(await journal.saved.last?.currentTime == 13)
    #expect(await journal.saved.last?.timeListening == 5)
}
