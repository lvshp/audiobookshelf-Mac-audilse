// Compile against the built AudilsePlayback and AudilseCore libraries. This uses
// only temporary generated audio; it never contacts or writes an ABS server.
import Foundation
import AppKit
import AVFoundation
import AudilseCore
import AudilsePlayback

private actor SmokeJournal {
    private var values: [LocalPlaybackSession] = []
    func save(_ session: LocalPlaybackSession) { values.append(session) }
    func snapshots() -> [LocalPlaybackSession] { values }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
enum ShelfAudioSmoke {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                log("PASS: native audio smoke")
                exit(0)
            } catch {
                log("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        // VLCKit dispatches clock/state notifications through the native app
        // run loop. A CLI Task.sleep loop alone does not model the app runtime.
        application.run()
    }

    @MainActor private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-audio-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("silence.wav")
        try writeSilence(to: wav, seconds: 3)
        let journal = SmokeJournal()
        let controller = PlaybackController(persist: { await journal.save($0) }, localProvider: { media in
            guard media.itemID == "queued-local-smoke" else { return nil }
            return PreparedPlayback(media: media, tracks: [.init(index: 0, url: wav, duration: 3, startOffset: 0, isLocal: true)],
                                    sessionID: nil, initialPosition: 1)
        })
        do {
            let media = PlaybackMedia(itemID: "local-wav-smoke", title: "Local audio smoke", duration: 6,
                                      chapters: [.init(id: 0, title: "First", start: 0, end: 3), .init(id: 1, title: "Second", start: 3, end: 6)])
            let tracks = [
                PlaybackTrack(index: 0, url: wav, duration: 3, startOffset: 0, isLocal: true),
                PlaybackTrack(index: 1, url: wav, duration: 3, startOffset: 3, isLocal: true)
            ]
            await controller.playOffline(media: media, tracks: tracks, initialPosition: 2.65)
            try await eventually("AVQueuePlayer did not advance automatically across files", seconds: 4) { controller.position > 3.05 }
            try require(controller.currentChapter?.id == 1, "Chapter did not follow the absolute timeline")
            controller.pause()
            let listeningBeforeSeek = controller.timeListening
            await controller.seek(to: 1.25)
            try require(abs(controller.position - 1.25) < 0.03, "Backward seek did not reach the first file")
            await controller.seek(to: 4)
            try require(abs(controller.position - 4) < 0.03, "Forward seek did not reach the second file")
            try await Task.sleep(for: .milliseconds(250))
            try require(abs(controller.timeListening - listeningBeforeSeek) < 0.2, "Paused seeking added listening time")
            controller.setRate(2)
            controller.setSleepTimer(minutes: 1)
            try require((controller.sleepDeadline?.timeIntervalSinceNow ?? 0) > 58, "Sleep timer was not configured")
            controller.cancelSleepTimer()
            controller.stopAtChapterEnd()
            controller.resume()
            try await eventually("Chapter-end sleep did not pause at the book end", seconds: 4) {
                controller.position >= 5.9 && !controller.isPlaying
            }
            try require(controller.error == nil, controller.error ?? "AVFoundation failed")
            await controller.stop()
            log("PASS: AVFoundation cross-file advance, absolute seek, chapters, rate, sleep and seek-free listening")

            controller.setRate(1)
            controller.enqueue(.init(itemID: "queued-local-smoke", title: "Offline queue", duration: 3))
            await controller.playOffline(media: .init(itemID: "queue-source-smoke", title: "Queue source", duration: 3),
                                         tracks: [.init(index: 0, url: wav, duration: 3, startOffset: 0, isLocal: true)], initialPosition: 2.65)
            try await eventually("The next downloaded book did not use the offline queue provider", seconds: 4) {
                controller.currentMedia?.itemID == "queued-local-smoke" && controller.position >= 1 && controller.isOffline && controller.isPlaying
            }
            await controller.stop()
            log("PASS: offline queue advances through the local provider and restores its checkpoint")

            if let ffmpeg = findFFmpeg() {
                let opus = root.appendingPathComponent("near-silent.opus")
                try await makeCompatibilitySample(using: ffmpeg, destination: opus, codec: "libopus")
                await controller.playOffline(media: .init(itemID: "local-opus-smoke", title: "Local Opus smoke", duration: 8),
                                             tracks: [.init(index: 0, url: opus, duration: 8, startOffset: 0, isLocal: true)])
                try await eventually("VLCKit did not advance through the local Opus file", seconds: 6) {
                    controller.position > 0.3 && controller.isPlaying && !controller.isBuffering
                }
                controller.pause()
                let listened = controller.timeListening
                await controller.seek(to: 3)
                try require(abs(controller.position - 3) < 0.05, "VLCKit seek did not use the book timeline")
                try await Task.sleep(for: .milliseconds(750))
                try require(abs(controller.position - 3) < 0.05, "VLCKit's paused seek position was overwritten by a stale native clock")
                try require(abs(controller.timeListening - listened) < 0.2, "VLCKit seeking added listening time")
                controller.resume()
                await controller.seek(to: 7.4)
                try await eventually("VLCKit did not finish the last compatibility file", seconds: 4) {
                    controller.position >= 7.99 && !controller.isPlaybackRequested
                }
                try await Task.sleep(for: .milliseconds(1_200))
                try require(abs(controller.position - 8) < 0.01, "A completed book's position was overwritten by the terminal native clock")
                controller.resume()
                try await eventually("VLCKit could not replay after the natural book end", seconds: 4) {
                    controller.position > 0 && controller.position < 3 && controller.isPlaying
                }
                await controller.stop()
                await controller.playOffline(media: .init(itemID: "opus-resume-smoke", title: "Opus resume", duration: 8),
                                             tracks: [.init(index: 0, url: opus, duration: 8, startOffset: 0, isLocal: true)], initialPosition: 3)
                controller.pause()
                try await Task.sleep(for: .milliseconds(750))
                try require(abs(controller.position - 3) < 0.05, "VLCKit's initial resume position jumped to an uninitialized clock")
                controller.resume()
                try await eventually("VLCKit did not resume near the restored checkpoint", seconds: 4) {
                    controller.position > 3.3 && controller.position < 6 && controller.isPlaying
                }
                await controller.stop()
                log("PASS: VLCKit local Opus decoding, buffering, seek, natural end and replay")

                let wma = root.appendingPathComponent("near-silent.wma")
                try await makeCompatibilitySample(using: ffmpeg, destination: wma, codec: "wmav2")
                controller.setRate(1)
                let mixed = PlaybackMedia(itemID: "mixed-codec-smoke", title: "Mixed codec smoke", duration: 14,
                                          chapters: [.init(id: 0, title: "WAV", start: 0, end: 3), .init(id: 1, title: "WMA", start: 3, end: 11), .init(id: 2, title: "WAV again", start: 11, end: 14)])
                await controller.playOffline(media: mixed, tracks: [
                    .init(index: 0, url: wav, duration: 3, startOffset: 0, isLocal: true),
                    .init(index: 1, url: wma, duration: 8, startOffset: 3, isLocal: true),
                    .init(index: 2, url: wav, duration: 3, startOffset: 11, isLocal: true)
                ], initialPosition: 2.65)
                try await eventually("AVFoundation did not hand the next WMA file to VLCKit", seconds: 5) {
                    controller.position > 3.3 && controller.currentChapter?.id == 1 && controller.isPlaying
                }
                await controller.seek(to: 10.4)
                try await eventually("VLCKit did not hand the next WAV file back to AVFoundation", seconds: 5) {
                    controller.position > 11.2 && controller.currentChapter?.id == 2 && controller.isPlaying
                }
                try require(controller.error == nil, controller.error ?? "Mixed codec playback failed")
                await controller.stop()
                log("PASS: WMA decoding and automatic AVFoundation → VLCKit → AVFoundation transitions")
            } else {
                log("SKIP: VLCKit sample generation requires ffmpeg (AVFoundation checks still ran)")
            }
            await controller.shutdown()
            let snapshots = await journal.snapshots()
            try require(!snapshots.isEmpty, "No durable offline snapshots were produced")
            for group in Dictionary(grouping: snapshots, by: \.id).values {
                try require(Set(group.map(\.startedAt)).count == 1, "A session's original start timestamp changed")
                try require(zip(group, group.dropFirst()).allSatisfy { $0.timeListening <= $1.timeListening }, "Cumulative listening time decreased")
            }
            log("PASS: \(snapshots.count) durable snapshots retain session identity and cumulative listening time")
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    @MainActor private static func eventually(_ message: String, seconds: Double, condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SmokeFailure(message: message) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SmokeFailure(message: message) }
    }

    private static func log(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }

    private static func writeSilence(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func findFFmpeg() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    private static func makeCompatibilitySample(using executable: URL, destination: URL, codec: String) async throws {
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = executable
            // Very short silent Opus files can finish before VLC publishes its
            // first clock notification. This eight-second tone is at -120 dB.
            process.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-af", "volume=0.000001", "-t", "8", "-c:a", codec, "-y", destination.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        try require(status == 0, "ffmpeg could not generate the local Opus sample")
    }
}
