import Foundation
import Testing
@testable import ShelfPlayback

private actor WaitingPlaybackService: PlaybackService {
    private(set) var waiting = false
    private(set) var canceled = false
    func prepare(media: PlaybackMedia) -> PreparedPlayback {
        .init(media: media, tracks: [.init(index: 0, url: URL(string: "https://shelf.example/hls/session/output.m3u8")!, duration: 10, startOffset: 0)], sessionID: "cancel-smoke", initialPosition: 0)
    }
    func authorize(track: PlaybackTrack) -> PlaybackTrack { track }
    func prepareToSeek(track: PlaybackTrack, localTime: Double) async throws {
        waiting = true
        do { try await Task.sleep(for: .seconds(60)) }
        catch { canceled = true; throw error }
    }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) { }
    func close(sessionID: String, currentTime: Double, timeListened: Double) { }
}

@Test @MainActor func stoppingPlaybackCancelsPendingStreamReadiness() async throws {
    let service = WaitingPlaybackService()
    let controller = PlaybackController(service: service)
    let playing = Task { await controller.play(media: .init(itemID: "cancel-book", title: "Cancel", duration: 10)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await service.waiting), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await service.waiting)
    await controller.stop()
    await playing.value
    #expect(await service.canceled)
    #expect(controller.currentMedia == nil)
    #expect(!controller.isBuffering)
    #expect(controller.timeListening == 0)
    await controller.shutdown()
}
