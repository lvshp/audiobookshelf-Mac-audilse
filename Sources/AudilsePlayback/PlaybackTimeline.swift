import Foundation

/// All positions exposed to the rest of the application are seconds measured
/// from the beginning of the book, regardless of the number of audio files.
public struct PlaybackTimeline: Sendable {
    public struct Position: Equatable, Sendable {
        public var trackIndex: Int
        public var localTime: Double
        public var absoluteTime: Double
    }

    public let tracks: [PlaybackTrack]
    public let duration: Double

    public init(tracks: [PlaybackTrack]) throws {
        guard !tracks.isEmpty else { throw PlaybackFailure.noTracks }
        let ordered = tracks.sorted { $0.startOffset == $1.startOffset ? $0.index < $1.index : $0.startOffset < $1.startOffset }
        guard Set(ordered.map(\.index)).count == ordered.count,
              ordered.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.startOffset.isFinite && $0.startOffset >= 0 }),
              zip(ordered, ordered.dropFirst()).allSatisfy({ $0.startOffset + $0.duration <= $1.startOffset + 0.1 }) else {
            throw PlaybackFailure.invalidTimeline
        }
        self.tracks = ordered
        self.duration = ordered.last!.startOffset + ordered.last!.duration
    }

    public func position(at absoluteTime: Double) -> Position {
        let target = absoluteTime.isFinite ? min(max(absoluteTime, 0), duration) : 0
        // At a file boundary, select the following file; the very end remains
        // the final file's end. For tiny metadata gaps, advance to the next file.
        let track = tracks.first(where: { target < $0.startOffset + $0.duration }) ?? tracks.last!
        let local = min(max(target - track.startOffset, 0), track.duration)
        return Position(trackIndex: track.index, localTime: local, absoluteTime: track.startOffset + local)
    }

    public func absoluteTime(trackIndex: Int, localTime: Double) -> Double? {
        guard let track = tracks.first(where: { $0.index == trackIndex }) else { return nil }
        let local = localTime.isFinite ? min(max(localTime, 0), track.duration) : 0
        return track.startOffset + local
    }

    public func chapter(at absoluteTime: Double, chapters: [PlaybackChapter]) -> PlaybackChapter? {
        let ordered = chapters.sorted { $0.start < $1.start }
        return ordered.last(where: { absoluteTime >= $0.start && absoluteTime < $0.end })
            ?? (absoluteTime >= duration ? ordered.last : nil)
    }
}

/// Measures monotonic wall time while audio is actually advancing. It does not
/// derive listening duration from media position, so skips and speed changes are
/// handled without distorting listening statistics.
public struct ListeningClock: Sendable {
    public private(set) var total: Double = 0
    private var lastTick: Double?

    public init() {}

    public mutating func update(monotonicTime: Double, isPlaying: Bool) {
        guard monotonicTime.isFinite else { return }
        if let previous = lastTick {
            total += max(0, monotonicTime - previous)
        }
        lastTick = isPlaying ? monotonicTime : nil
    }

    public mutating func reset() { total = 0; lastTick = nil }
}
