import Foundation
import AudilseCore
#if canImport(VLCKit)
@preconcurrency import VLCKit
#endif

@MainActor
final class LocalCompatibilityEngine {
    static let maximumRate: Float = 10
    #if canImport(VLCKit)
    private let engine = NativePCMCompatibilityEngine()
    func load(_ track: PlaybackTrack, localTime: Double, rate: Float, autoplay: Bool) throws {
        try engine.load(track, localTime: localTime, rate: rate, autoplay: autoplay)
    }
    func tick() { engine.tick() }
    var localTime: Double { engine.localTime }
    var isPlaying: Bool { engine.isPlaying }
    var isListening: Bool { engine.isListening }
    var listeningClockTime: Double { engine.listeningClockTime }
    var isBuffering: Bool { engine.isBuffering }
    var hasEnded: Bool { engine.hasEnded }
    var hasFailed: Bool { engine.hasFailed }
    func play(rate: Float) { engine.play(rate: rate) }
    func pause() { engine.pause() }
    func stop() { engine.stop() }
    func seek(to seconds: Double) { engine.seek(to: seconds) }
    func setRate(_ rate: Float) { engine.setRate(rate) }
    #else
    func load(_ track: PlaybackTrack, localTime: Double, rate: Float, autoplay: Bool) throws {
        throw PlaybackFailure.unsupportedLocalFormat(track.url.pathExtension.uppercased())
    }
    func tick() {}
    var localTime: Double { 0 }
    var isPlaying: Bool { false }
    var isListening: Bool { false }
    var listeningClockTime: Double { ProcessInfo.processInfo.systemUptime }
    var isBuffering: Bool { false }
    var hasEnded: Bool { false }
    var hasFailed: Bool { false }
    func play(rate: Float) {}
    func pause() {}
    func stop() {}
    func seek(to seconds: Double) {}
    func setRate(_ rate: Float) {}
    #endif

    static func needsCompatibility(_ track: PlaybackTrack) -> Bool {
        guard track.isLocal else { return false }
        let supported: Set<String> = ["mp3", "m4b", "m4a", "aac", "aif", "aiff", "wav", "caf", "flac", "mp4", "ac3"]
        return !supported.contains(track.url.pathExtension.lowercased())
    }
}
