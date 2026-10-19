import Foundation
import AudilseCore
import Testing
@testable import AudilsePlayback

private actor DiagnosticService: PlaybackService {
    let prepareFailure: Bool
    let authorizeFailure: Bool
    private(set) var deltas: [Double] = []
    private(set) var closing: [Bool] = []
    init(prepareFailure: Bool = false, authorizeFailure: Bool = false) { self.prepareFailure = prepareFailure; self.authorizeFailure = authorizeFailure }
    func prepare(media: PlaybackMedia) throws -> PreparedPlayback {
        if prepareFailure { throw PlaybackFailure.noTracks }
        return .init(media: media, tracks: [.init(index: 0, url: URL(string: "https://synthetic.invalid/audio")!, duration: 30, startOffset: 0)], sessionID: "synthetic-session", initialPosition: 0)
    }
    func authorize(track: PlaybackTrack) throws -> PlaybackTrack {
        if authorizeFailure { throw ABSError.http(status: 403, message: "原消息 %@") }
        return track
    }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) throws {
        deltas.append(timeListened); closing.append(false)
        throw ABSError.notAuthenticated
    }
    func close(sessionID: String, currentTime: Double, timeListened: Double) {
        deltas.append(timeListened); closing.append(true)
    }
}
private func diagnosticSnapshot(_ listened: Double) -> LocalPlaybackSession {
    .init(id: "stable", libraryItemId: "book", duration: 100, currentTime: 20 + listened, startedAt: 1_000, updatedAt: 2_000, timeListening: listened)
}
@Test @MainActor func controllerRetainsTypedPreparationFailureWithoutPlayback() async {
    let controller = PlaybackController(service: DiagnosticService(prepareFailure: true))
    await controller.play(media: .init(itemID: "book", title: "Book"))
    #expect(controller.errorDiagnostic?.code == "playback.noTracks")
    #expect(controller.error == PlaybackFailure.noTracks.localizedDescription)
    #expect(!controller.isPlaybackRequested && !controller.isPlaying && !controller.isBuffering)
    let original = controller.errorDiagnostic
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        await controller.play(media: .init(itemID: "replacement", title: "Replacement"))
    }
    await cancelled.value
    #expect(controller.errorDiagnostic == original)
    await controller.shutdown()
}
@Test @MainActor func controllerAuthorizationFailureKeepsServerArgumentAndStops() async {
    let controller = PlaybackController(service: DiagnosticService(authorizeFailure: true))
    await controller.play(media: .init(itemID: "book", title: "Book"))
    #expect(controller.errorDiagnostic?.code == "abs.http")
    #expect(controller.errorDiagnostic?.arguments == ["403", "原消息 %@"])
    #expect(!controller.isPlaybackRequested && !controller.isPlaying && !controller.isBuffering)
    await controller.shutdown()
}
@Test func reporterPreservesBothTypedRemoteAndLocalFailures() async {
    let service = DiagnosticService()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable", persist: { _ in throw OfflineStorageError.insufficientSpace }, checkpoint: nil, acknowledge: nil)
    let result = await reporter.submit(diagnosticSnapshot(10))
    #expect(result?.code == "playback.localPersistenceFailed")
    #expect(result?.causes.map(\.code) == ["abs.notAuthenticated", "storage.insufficientSpace"])
    #expect(result?.fallbackMessage.contains("本地保存失败") == true)
    #expect(await service.deltas == [10])
}
@Test func typedReporterRecoveryStillUsesCumulativeSnapshotsAndCloseZero() async {
    let service = DiagnosticService()
    let reporter = PlaybackSessionReporter(service: service, remoteSessionID: "stable", persist: { _ in }, checkpoint: nil, acknowledge: nil)
    #expect(await reporter.submit(diagnosticSnapshot(10))?.code == "abs.notAuthenticated")
    #expect(await reporter.submit(diagnosticSnapshot(13))?.code == "playback.savedForRecovery")
    #expect(await reporter.submit(diagnosticSnapshot(14), closing: true)?.code == "playback.savedForRecovery")
    #expect(await service.deltas == [10, 0])
    #expect(await service.closing == [false, true])
    let offline = PlaybackSessionReporter(service: nil, remoteSessionID: nil, persist: { _ in }, checkpoint: { _ in throw OfflineStorageError.unsafePath }, acknowledge: nil)
    #expect(await offline.submit(diagnosticSnapshot(1))?.code == "storage.unsafePath")
}

#if canImport(VLCKit)
@Test func nativeCompatibilityFailuresUseExistingLocalizedDiagnostic() {
    for error in [NativePCMCompatibilityFailure.decoderStartup, .missingSymbol("private-symbol")] {
        let issue = ClientDiagnostic.capture(error)
        #expect(issue.code == "playback.localEngineFailed")
        #expect(issue.arguments.isEmpty && !issue.fallbackMessage.contains("private-symbol"))
    }
}
#endif
