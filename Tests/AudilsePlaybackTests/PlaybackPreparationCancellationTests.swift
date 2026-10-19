import Foundation
import AudilseCore
import Testing
@testable import AudilsePlayback

private actor PreparationGate {
    private(set) var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { released = true; let waiting = continuations; continuations = []; waiting.forEach { $0.resume() } }
}

private actor PreparationService: PlaybackService {
    let prepareGate: PreparationGate?
    let authorizeGate: PreparationGate?
    let closeGate: PreparationGate?
    let initialPosition: Double
    let trackURL: URL
    private(set) var prepareCount = 0
    private(set) var authorizeCount = 0
    private(set) var closed: [(id: String, listened: Double, position: Double)] = []
    init(prepare: PreparationGate? = nil, authorize: PreparationGate? = nil, close: PreparationGate? = nil, initialPosition: Double = 0,
         trackURL: URL = URL(string: "https://invalid.fixture.test/audio")!) {
        prepareGate = prepare; authorizeGate = authorize; closeGate = close
        self.initialPosition = initialPosition
        self.trackURL = trackURL
    }
    func prepare(media: PlaybackMedia) async -> PreparedPlayback {
        prepareCount += 1; await prepareGate?.wait()
        return .init(media: media, tracks: [.init(index: 0, url: trackURL, duration: 20, startOffset: 0, isLocal: trackURL.isFileURL)],
                     sessionID: "session-" + media.itemID, initialPosition: initialPosition)
    }
    func authorize(track: PlaybackTrack) async -> PlaybackTrack { authorizeCount += 1; await authorizeGate?.wait(); return track }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) { }
    func close(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        // A cancelled URLSession cleanup would never reach the server either.
        try Task.checkCancellation()
        await closeGate?.wait()
        try Task.checkCancellation()
        closed.append((sessionID, timeListened, currentTime))
    }
}

@Test @MainActor func cancelledHistoricalPrepareClosesAtOriginalServerPosition() async throws {
    let gate = PreparationGate(), service = PreparationService(prepare: gate, initialPosition: 7)
    let controller = PlaybackController(service: service)
    let task = Task { await controller.play(media: .init(itemID: "history", title: "History"), initialPosition: 90) }
    try await waitPreparation { await gate.entered }
    task.cancel(); await gate.release(); await task.value
    #expect(controller.currentMedia == nil)
    #expect(await service.authorizeCount == 0)
    let closed = await service.closed
    #expect(closed.count == 1 && closed.first?.position == 7 && closed.first?.listened == 0)
    await controller.shutdown()
}

@Test(arguments: [Double.nan, Double.infinity, -1]) @MainActor func invalidHistoricalPositionCannotPrepareOrReplaceQueue(position: Double) async {
    let service = PreparationService(), controller = PlaybackController(service: PreparationService())
    await controller.configure(service: service)
    controller.enqueue(originalQueueItem)
    await controller.play(media: .init(itemID: "history", title: "History"), following: [followingQueueItem], initialPosition: position)
    #expect(await service.prepareCount == 0)
    #expect(controller.currentMedia == nil && controller.queue == [originalQueueItem])
    #expect(controller.errorDiagnostic?.code == "playback.invalidStartPosition")
    await controller.shutdown()
}

private enum PreparationTimeout: Error { case waiting }
@MainActor private func waitPreparation(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard await condition() else { throw PreparationTimeout.waiting }
}
private let originalQueueItem = PlaybackMedia(itemID: "queued-original", title: "Original")
private let followingQueueItem = PlaybackMedia(itemID: "queued-replacement", title: "Replacement")

@Test @MainActor func cancelledEntryLeavesExistingMediaAndQueueUntouched() async throws {
    let gate = PreparationGate(), service = PreparationService(authorize: gate)
    let controller = PlaybackController(service: service)
    controller.enqueue(originalQueueItem)
    let original = Task { await controller.play(media: .init(itemID: "original", title: "Original", duration: 20)) }
    try await waitPreparation { await gate.entered }
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await controller.play(media: .init(itemID: "replacement", title: "Replacement"), following: [followingQueueItem])
        await controller.playOffline(media: .init(itemID: "offline", title: "Offline"), tracks: [], following: [followingQueueItem])
        await controller.playNext()
    }
    await cancelled.value
    #expect(controller.currentMedia?.itemID == "original")
    #expect(controller.queue == [originalQueueItem])
    #expect(await service.closed.isEmpty)
    original.cancel(); await gate.release(); await original.value; await controller.shutdown()
}

@Test @MainActor func cancelledPrepareClosesUnadoptedSessionOutsideCallerCancellation() async throws {
    let gate = PreparationGate(), service = PreparationService(prepare: gate)
    let controller = PlaybackController(service: service); controller.enqueue(originalQueueItem)
    let preparing = Task { await controller.play(media: .init(itemID: "prepared", title: "Prepared"), following: [followingQueueItem]) }
    try await waitPreparation { await gate.entered }
    preparing.cancel(); await gate.release(); await preparing.value
    #expect(controller.currentMedia == nil)
    #expect(controller.queue == [originalQueueItem])
    #expect(controller.error == nil && !controller.isBuffering && !controller.isPlaybackRequested)
    #expect(await service.authorizeCount == 0)
    let closed = await service.closed
    #expect(closed.count == 1 && closed.first?.id == "session-prepared" && closed.first?.listened == 0)
    await controller.shutdown()
}

@Test(arguments: [false, true]) @MainActor func cancelledLocalProviderDoesNotFallThroughOrBegin(prepared: Bool) async throws {
    let gate = PreparationGate(), service = PreparationService()
    let controller = PlaybackController(service: service, localProvider: { media in
        await gate.wait()
        return prepared ? .init(media: media, tracks: [], sessionID: nil, initialPosition: 0) : nil
    })
    controller.enqueue(originalQueueItem)
    let preparing = Task { await controller.play(media: .init(itemID: "local", title: "Local"), following: [followingQueueItem]) }
    try await waitPreparation { await gate.entered }
    preparing.cancel(); await gate.release(); await preparing.value
    #expect(await service.prepareCount == 0)
    #expect(controller.currentMedia == nil && controller.error == nil)
    #expect(controller.queue == [originalQueueItem] && !controller.isBuffering)
    await controller.shutdown()
}

@Test @MainActor func cancelledStopReportDoesNotPrepareOrReplaceQueue() async throws {
    let authorization = PreparationGate(), closing = PreparationGate()
    let service = PreparationService(authorize: authorization, close: closing)
    let controller = PlaybackController(service: service); controller.enqueue(originalQueueItem)
    let original = Task { await controller.play(media: .init(itemID: "original", title: "Original")) }
    try await waitPreparation { await authorization.entered }
    let next = Task { await controller.play(media: .init(itemID: "replacement", title: "Replacement"), following: [followingQueueItem]) }
    try await waitPreparation { await closing.entered }
    next.cancel(); await closing.release(); await next.value
    #expect(await service.prepareCount == 1)
    #expect(controller.currentMedia == nil && controller.queue == [originalQueueItem] && controller.error == nil)
    original.cancel(); await authorization.release(); await original.value; await controller.shutdown()
}

@Test @MainActor func cancelledOldPrepareCannotStopNewGeneration() async throws {
    let prepare = PreparationGate(), authorization = PreparationGate()
    let oldService = PreparationService(prepare: prepare), newService = PreparationService(authorize: authorization)
    let controller = PlaybackController(service: oldService)
    let old = Task { await controller.play(media: .init(itemID: "old", title: "Old")) }
    try await waitPreparation { await prepare.entered }; old.cancel()
    await controller.configure(service: newService)
    let winner = Task { await controller.play(media: .init(itemID: "winner", title: "Winner"), following: [followingQueueItem]) }
    try await waitPreparation { await authorization.entered }
    await prepare.release(); await old.value
    #expect(controller.currentMedia?.itemID == "winner" && controller.isPlaybackRequested)
    #expect(controller.queue == [followingQueueItem] && controller.error == nil)
    #expect(await oldService.closed.count == 1)
    #expect(await newService.closed.isEmpty)
    winner.cancel(); await authorization.release(); await winner.value; await controller.shutdown()
}

@Test @MainActor func cancelledAuthorizationNeverHandsItemToPlayer() async throws {
    let gate = PreparationGate(), service = PreparationService(authorize: gate)
    let controller = PlaybackController(service: service)
    let preparing = Task { await controller.play(media: .init(itemID: "authorizing", title: "Authorizing")) }
    try await waitPreparation { await gate.entered }
    preparing.cancel(); await gate.release(); await preparing.value
    #expect(controller.currentMedia == nil && controller.error == nil && !controller.isPlaybackRequested && !controller.isPlaying)
    #expect(controller.timeListening == 0)
    #expect(await service.closed.count == 1)
    await controller.shutdown()
}

private func silentWAV() throws -> URL {
    let frames = 160_000, byteCount = frames * 2
    var data = Data()
    func text(_ string: String) { data.append(contentsOf: string.utf8) }
    func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    text("RIFF"); u32(UInt32(36 + byteCount)); text("WAVEfmt "); u32(16); u16(1); u16(1)
    u32(8000); u32(16000); u16(2); u16(16); text("data"); u32(UInt32(byteCount)); data.append(Data(count: byteCount))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-cancel-" + UUID().uuidString + ".wav")
    try data.write(to: file); return file
}

private actor HistoricalCheckpointJournal {
    var values: [MediaProgress] = []
    func append(_ value: MediaProgress) { values.append(value) }
}

private actor PreparationCompletionFlag {
    var completed = false
    func finish() { completed = true }
}

@Test(arguments: [false, true], [5.0, 35.0]) @MainActor func historyInitialPositionPrecedesTheFirstDurableCheckpoint(localProvider: Bool, requested: Double) async throws {
    let file = try silentWAV(), journal = HistoricalCheckpointJournal()
    defer { try? FileManager.default.removeItem(at: file) }
    let service = PreparationService(initialPosition: 3, trackURL: file)
    let controller = PlaybackController(service: service, checkpoint: { await journal.append($0) }, localProvider: { media in
        guard localProvider else { return nil }
        return .init(media: media, tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)], sessionID: nil, initialPosition: 3)
    })
    await controller.play(media: .init(itemID: "history-start", title: "History", duration: 20), initialPosition: requested)
    let first = try #require(await journal.values.first)
    #expect(abs(first.currentTime - min(requested, 20)) < 0.05)
    #expect(first.currentTime != 3)
    #expect(await service.prepareCount == (localProvider ? 0 : 1))
    await controller.shutdown()
}

@Test @MainActor func detachedRemoteIdentityRemainsFinalizingUntilOriginalCloseReturns() async throws {
    let authorization = PreparationGate(), closing = PreparationGate()
    let service = PreparationService(authorize: authorization, close: closing)
    let controller = PlaybackController(service: service)
    let preparing = Task { await controller.play(media: .init(itemID: "finalizing", title: "Finalizing")) }
    try await waitPreparation { await authorization.entered }
    let stopping = Task { await controller.stop() }
    try await waitPreparation { await closing.entered }
    #expect(controller.currentRemoteSessionID == nil)
    #expect(controller.finalizingSessionIDs == ["session-finalizing"])
    await closing.release(); await stopping.value
    #expect(controller.finalizingSessionIDs.isEmpty)
    preparing.cancel(); await authorization.release(); await preparing.value
    await controller.shutdown()
}

@Test(arguments: [false, true]) @MainActor func accountTransitionWaitsForPreviouslyDetachedClose(configure: Bool) async throws {
    let authorization = PreparationGate(), closing = PreparationGate(), completion = PreparationCompletionFlag()
    let service = PreparationService(authorize: authorization, close: closing)
    let controller = PlaybackController(service: service)
    let preparing = Task { await controller.play(media: .init(itemID: "transition", title: "Transition")) }
    try await waitPreparation { await authorization.entered }
    let stopping = Task { await controller.stop() }
    try await waitPreparation { await closing.entered }
    controller.enqueue(originalQueueItem)
    let transition = Task {
        if configure { await controller.configure(service: PreparationService()) }
        else { await controller.shutdown() }
        await completion.finish()
    }
    // Give the transition an opportunity to run while the original close remains gated.
    try await Task.sleep(for: .milliseconds(30))
    #expect(!(await completion.completed))
    #expect(controller.finalizingSessionIDs == ["session-transition"])
    let remoteNext = Task { await controller.playNext() }
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.queue == [originalQueueItem])
    #expect(await service.prepareCount == 1)
    remoteNext.cancel()
    await closing.release(); await stopping.value; await transition.value
    #expect(await completion.completed)
    #expect(controller.finalizingSessionIDs.isEmpty)
    preparing.cancel(); await authorization.release(); await preparing.value; await remoteNext.value
    await controller.shutdown()
    await controller.play(media: .init(itemID: "after-shutdown", title: "After shutdown"))
    #expect(controller.currentMedia == nil)
}

@Test @MainActor func cancellationAfterEngineActivationPreservesBackgroundPlaybackDuringReport() async throws {
    let gate = PreparationGate(), file = try silentWAV()
    defer { try? FileManager.default.removeItem(at: file) }
    let controller = PlaybackController(persist: { _ in await gate.wait() })
    let playing = Task { await controller.playOffline(media: .init(itemID: "background", title: "Background", duration: 20),
        tracks: [.init(index: 0, url: file, duration: 20, startOffset: 0, isLocal: true)]) }
    try await waitPreparation { await gate.entered }
    #expect(controller.currentMedia?.itemID == "background" && controller.isPlaybackRequested)
    playing.cancel(); await gate.release(); await playing.value
    #expect(controller.currentMedia?.itemID == "background" && controller.isPlaybackRequested && controller.error == nil)
    try await waitPreparation { controller.position > 0.1 }
    #expect(controller.isPlaying)
    await controller.shutdown()
}
