import Foundation
import Testing
@testable import AudilsePlayback

private actor WaitingPlaybackService: PlaybackService {
    private(set) var waiting = false
    private(set) var canceled = false
    private let started: AsyncStream<Bool>
    private let startedSignal: AsyncStream<Bool>.Continuation
    init() {
        let channel = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        started = channel.stream; startedSignal = channel.continuation
    }
    func waitForPreparation() async -> Bool {
        for await value in started { return value }
        return false
    }
    func prepare(media: PlaybackMedia) -> PreparedPlayback {
        .init(media: media, tracks: [.init(index: 0, url: URL(string: "https://shelf.example/hls/session/output.m3u8")!, duration: 10, startOffset: 0)], sessionID: "cancel-smoke", initialPosition: 0)
    }
    func authorize(track: PlaybackTrack) -> PlaybackTrack { track }
    func prepareToSeek(track: PlaybackTrack, localTime: Double) async throws {
        waiting = true
        startedSignal.yield(true); startedSignal.finish()
        do { try await Task.sleep(for: .seconds(60)) }
        catch { canceled = true; throw error }
    }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) { }
    func close(sessionID: String, currentTime: Double, timeListened: Double) { }
}

@Test(.timeLimit(.minutes(1))) @MainActor func stoppingPlaybackCancelsPendingStreamReadiness() async throws {
    let service = WaitingPlaybackService()
    let controller = PlaybackController(service: service)
    let playing = Task { await controller.play(media: .init(itemID: "cancel-book", title: "Cancel", duration: 10)) }
    defer { playing.cancel(); controller.setSystemMediaControlsActive(false) }
    // This tests cancellation during readiness, not how quickly the OS schedules
    // preparation while other media tests are running. The stream is cancellable
    // and buffers the signal even when preparation wins the initial race.
    try #require(await service.waitForPreparation())
    #expect(await service.waiting)
    await controller.stop()
    await playing.value
    #expect(await service.canceled)
    #expect(controller.currentMedia == nil)
    #expect(!controller.isBuffering)
    #expect(controller.timeListening == 0)
    await controller.shutdown()
}
