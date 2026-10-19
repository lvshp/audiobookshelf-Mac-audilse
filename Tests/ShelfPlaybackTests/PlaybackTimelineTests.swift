import Foundation
import Testing
@testable import ShelfPlayback

private func track(_ index: Int, _ offset: Double, _ duration: Double) -> PlaybackTrack {
    PlaybackTrack(index: index, url: URL(fileURLWithPath: "/tmp/track-\(index).mp3"), duration: duration, startOffset: offset, isLocal: true)
}

@Test func translatesAbsolutePositionAcrossFiles() throws {
    let timeline = try PlaybackTimeline(tracks: [track(1, 100, 80), track(0, 0, 100), track(2, 180, 20)])
    #expect(timeline.duration == 200)
    #expect(timeline.position(at: 125) == .init(trackIndex: 1, localTime: 25, absoluteTime: 125))
    #expect(timeline.absoluteTime(trackIndex: 2, localTime: 7) == 187)
}

@Test func boundariesAndSeekingStayWithinBook() throws {
    let timeline = try PlaybackTimeline(tracks: [track(0, 0, 100), track(1, 100, 50)])
    #expect(timeline.position(at: 100) == .init(trackIndex: 1, localTime: 0, absoluteTime: 100))
    #expect(timeline.position(at: -30).absoluteTime == 0)
    #expect(timeline.position(at: 900) == .init(trackIndex: 1, localTime: 50, absoluteTime: 150))
    #expect(timeline.position(at: .nan).absoluteTime == 0)
    #expect(timeline.absoluteTime(trackIndex: 9, localTime: 5) == nil)
    #expect(timeline.absoluteTime(trackIndex: 1, localTime: 500) == 150)
}

@Test func chapterEndSelectsFollowingChapter() throws {
    let timeline = try PlaybackTimeline(tracks: [track(0, 0, 200)])
    let chapters = [PlaybackChapter(id: 0, title: "One", start: 0, end: 100), PlaybackChapter(id: 1, title: "Two", start: 100, end: 200)]
    #expect(timeline.chapter(at: 99.9, chapters: chapters)?.id == 0)
    #expect(timeline.chapter(at: 100, chapters: chapters)?.id == 1)
    #expect(timeline.chapter(at: 200, chapters: chapters)?.id == 1)
}

@Test func rejectsInvalidOrOverlappingTracks() {
    #expect(throws: PlaybackFailure.noTracks) { try PlaybackTimeline(tracks: []) }
    #expect(throws: PlaybackFailure.invalidTimeline) { try PlaybackTimeline(tracks: [track(0, 0, -1)]) }
    #expect(throws: PlaybackFailure.invalidTimeline) { try PlaybackTimeline(tracks: [track(0, 0, 20), track(1, 10, 10)]) }
    #expect(throws: PlaybackFailure.invalidTimeline) { try PlaybackTimeline(tracks: [track(0, 0, 20), track(0, 20, 10)]) }
}

@Test func listeningTimeExcludesSeekPauseAndBuffering() {
    var clock = ListeningClock()
    clock.update(monotonicTime: 10, isPlaying: true)
    clock.update(monotonicTime: 15, isPlaying: true)
    // An arbitrary media seek changes no clock input and therefore adds no time.
    #expect(clock.total == 5)
    clock.update(monotonicTime: 15, isPlaying: false)
    clock.update(monotonicTime: 300, isPlaying: false)
    clock.update(monotonicTime: 301, isPlaying: true)
    clock.update(monotonicTime: 304, isPlaying: true)
    #expect(clock.total == 8)
    clock.update(monotonicTime: 304, isPlaying: false)
    clock.update(monotonicTime: 308, isPlaying: true)
    clock.update(monotonicTime: 310, isPlaying: true)
    #expect(clock.total == 10)
}

@Test func listeningStopBoundaryExcludesLaterDrainPollsAndCannotDoubleCount() {
    var clock = ListeningClock()
    clock.update(monotonicTime: 10, isPlaying: true)
    clock.update(monotonicTime: 11, isPlaying: true)
    // The engine stopped consuming at 11.2; the Controller may poll much later.
    clock.update(monotonicTime: 11.2, isPlaying: false)
    let stopped = clock.total
    #expect(abs(stopped - 1.2) < 0.000_001)
    clock.update(monotonicTime: 11.2, isPlaying: false)
    clock.update(monotonicTime: 15, isPlaying: false)
    #expect(clock.total == stopped)
    clock.update(monotonicTime: 20, isPlaying: true)
    clock.update(monotonicTime: 21, isPlaying: true)
    // A delayed stop boundary must not subtract an already accounted interval.
    clock.update(monotonicTime: 20.9, isPlaying: false)
    #expect(clock.total == stopped + 1)
    clock.update(monotonicTime: 21.5, isPlaying: false)
    #expect(clock.total == stopped + 1)
}
