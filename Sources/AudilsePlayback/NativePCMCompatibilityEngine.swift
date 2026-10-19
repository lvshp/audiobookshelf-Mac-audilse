import Foundation
import Darwin
@preconcurrency import AVFoundation
#if canImport(VLCKit)
@preconcurrency import VLCKit

/// The fixed libVLC audio-output path discards samples above 4×. Its public
/// transcode/smem path decodes at nominal rate; native TimePitch owns playback.
/// All callbacks below are nonisolated. No Swift task, lock, or allocation runs
/// in our player completion callback; VLC's producer is not an audio IO thread.
@MainActor
final class NativePCMCompatibilityEngine {
    static let maximumRate: Float = 10
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var decoder: NativePCMDecoder?
    private var counter = NativePCMPlayedCounter()
    private var refill: Task<Void, Never>?
    private var loadedTrack: PlaybackTrack?
    private var attached = false
    private var wantsToPlay = false
    private var desiredRate: Float = 1
    private var positionBase = 0.0
    private var heldPosition: Double? = 0
    private var ended = false
    private var failed = false
    private var lastPlayedMicroseconds: Int64 = 0
    private var lastAdvanceAt: Double?
    private var drainWatchdog = NativePCMRenderWatchdog()
    private var drainAnchor: AVAudioTime?
    private var drainEpoch: Int64 = 0
    private var drainProcessingSeconds = 0.0
    private var drainPresentationSeconds = 0.0
    private lazy var renderEpoch = NativePCMRenderEpoch(engine: engine)

    func load(_ track: PlaybackTrack, localTime: Double, rate: Float, autoplay: Bool) throws {
        guard track.isLocal, track.url.isFileURL,
              FileManager.default.fileExists(atPath: track.url.path) else { throw PlaybackFailure.invalidLocalFile }
        guard localTime.isFinite, localTime >= 0 else { throw PlaybackFailure.invalidStartPosition }
        stop()
        loadedTrack = track
        positionBase = track.duration > 0 ? min(track.duration, localTime) : localTime
        heldPosition = positionBase
        desiredRate = Self.normalized(rate)
        wantsToPlay = autoplay
        ended = false; failed = false
        lastPlayedMicroseconds = 0; lastAdvanceAt = nil
        counter = NativePCMPlayedCounter()
        if track.duration > 0, positionBase >= track.duration {
            ended = autoplay; wantsToPlay = false; return
        }
        do {
            engine.attach(player); engine.attach(pitch); attached = true
            engine.connect(player, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            pitch.rate = desiredRate; pitch.pitch = 0
            _ = renderEpoch
            decoder = try NativePCMDecoder(path: track.url.path, start: positionBase)
            refill = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            tick()
        } catch {
            stop(); failed = true
            throw error
        }
    }

    func tick() {
        guard let decoder, !failed, !ended else { return }
        let state = decoder.state
        let played = counter.playedMicroseconds
        if wantsToPlay, played > lastPlayedMicroseconds {
            lastAdvanceAt = ProcessInfo.processInfo.systemUptime
        }
        lastPlayedMicroseconds = played
        guard state != 7, !decoder.ring.hasFailed else {
            failed = true; wantsToPlay = false; freezePosition(); player.pause(); return
        }
        // At most 5 seconds are scheduled, in addition to the producer's bounded
        // 5-second ring. Allocation/copy/scheduling happens here on MainActor,
        // never inside the native render or completion callbacks.
        while counter.pending < 250, decoder.ring.bufferedFrames > 0 {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960) else {
                freezePosition(); failed = true; wantsToPlay = false; player.pause(); return
            }
            guard let end = decoder.ring.pop(into: buffer, maximum: 960) else { break }
            counter.enqueue()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack,
                                  completionHandler: nativePCMCompletion(counter, end))
        }
        if wantsToPlay, (!player.isPlaying || !engine.isRunning),
           counter.pending > 0 || (state == 6 && decoder.ring.hasPCM) {
            do {
                prepareAutomaticRestart()
                try engine.start()
                heldPosition = nil
                player.play()
            } catch {
                freezePosition(); failed = true; wantsToPlay = false
            }
        }
        // Player completion advances media progress, but it is not our sole EOF
        // gate. Conservatively drain the downstream graph using measured AU
        // latency and an advancing render clock before reporting track completion.
        if state == 6, !decoder.ring.hasPCM {
            freezePosition(); failed = true; wantsToPlay = false; player.pause(); return
        }
        if state == 6, decoder.ring.bufferedFrames == 0, counter.pending == 0,
           wantsToPlay, nativeDrainHasPresented() {
            freezePosition(); ended = true; wantsToPlay = false; player.pause()
        }
    }

    var localTime: Double {
        let value = heldPosition ?? (positionBase + Double(counter.playedMicroseconds) / 1_000_000)
        if let duration = loadedTrack?.duration, duration > 0 { return min(duration, max(0, value)) }
        return max(0, value)
    }
    var isPlaying: Bool {
        wantsToPlay && player.isPlaying && engine.isRunning &&
        (drainAnchor != nil || (counter.pending > 0 &&
         lastAdvanceAt.map { ProcessInfo.processInfo.systemUptime - $0 < 1.2 } == true)) && !ended && !failed
    }
    // Output draining remains a playing UI state, but cannot keep billing listening time.
    var isListening: Bool {
        wantsToPlay && player.isPlaying && engine.isRunning && counter.pending > 0 &&
        lastAdvanceAt.map { ProcessInfo.processInfo.systemUptime - $0 < 1.2 } == true && !ended && !failed
    }
    var listeningClockTime: Double {
        let now = ProcessInfo.processInfo.systemUptime
        // Close the sampling interval at the last observed consumption, not at
        // the next controller poll after conservative graph draining.
        return !isListening ? min(now, lastAdvanceAt ?? now) : now
    }
    var isBuffering: Bool { wantsToPlay && !isPlaying && !ended && !failed }
    var hasEnded: Bool { ended }
    var hasFailed: Bool { failed }

    func play(rate: Float) {
        resetNativeDrain()
        desiredRate = Self.normalized(rate); pitch.rate = desiredRate
        guard decoder != nil, !failed, !ended else { return }
        wantsToPlay = true; heldPosition = nil
        tick()
    }
    func pause() {
        // Already queued completion callbacks can arrive after pause. Keep a
        // visible durable snapshot until explicit resume, including while loading.
        resetNativeDrain()
        player.pause(); freezePosition(); wantsToPlay = false; lastAdvanceAt = nil
    }
    func stop() {
        resetNativeDrain()
        freezePosition(); wantsToPlay = false; lastAdvanceAt = nil
        loadedTrack = nil
        refill?.cancel(); refill = nil
        // Cancel producer backpressure BEFORE libvlc_stop joins its callbacks.
        counter.cancel(); decoder?.ring.cancel()
        player.stop()
        decoder = nil
        engine.stop()
        if attached {
            engine.disconnectNodeOutput(player); engine.disconnectNodeOutput(pitch)
            engine.detach(player); engine.detach(pitch); attached = false
        }
    }
    func seek(to seconds: Double) {
        guard let track = loadedTrack, seconds.isFinite, seconds >= 0 else { return }
        let autoplay = wantsToPlay
        do { try load(track, localTime: seconds, rate: desiredRate, autoplay: autoplay) }
        catch { failed = true }
    }
    func setRate(_ rate: Float) {
        let next = Self.normalized(rate)
        if next != desiredRate { resetNativeDrain() }
        desiredRate = next; pitch.rate = desiredRate
    }
    private func prepareAutomaticRestart() {
        // Automatic retries must not erase inactivity evidence. Only new
        // render progress can refresh the watchdog across repeated restarts.
        drainAnchor = nil
    }
    private func resetNativeDrain() {
        drainAnchor = nil; drainWatchdog = NativePCMRenderWatchdog()
    }
    private func nativeDrainHasPresented() -> Bool {
        let processing = max(pitch.latency, pitch.auAudioUnit.latency) /
            min(1, Double(desiredRate)) + pitch.auAudioUnit.tailTime
        let presentation = pitch.outputPresentationLatency
        guard processing.isFinite, presentation.isFinite,
              processing >= 0, presentation >= 0 else {
            freezePosition(); failed = true; wantsToPlay = false; player.pause(); return false
        }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let epoch = renderEpoch.value
        let time = pitch.lastRenderTime
        let validClock = time?.isSampleTimeValid == true && time?.isHostTimeValid == true
        // This is a failure timeout for a stalled renderer, not a completion
        // delay. A timeout never reports EOF or advances source progress.
        if drainWatchdog.stalled(sample: validClock ? time?.sampleTime : nil,
                                 host: validClock ? time?.hostTime : nil,
                                 epoch: epoch, now: now,
                                 limit: max(1.2, 2 * (processing + presentation))) {
            freezePosition(); failed = true; wantsToPlay = false; player.pause();
            drainAnchor = nil; return false
        }
        guard engine.isRunning, player.isPlaying, let time, validClock,
              time.sampleRate.isFinite, time.sampleRate > 0 else {
            drainAnchor = nil; return false
        }
        guard let anchor = drainAnchor, drainEpoch == epoch,
              anchor.sampleRate == time.sampleRate,
              time.sampleTime >= anchor.sampleTime, time.hostTime >= anchor.hostTime else {
            drainAnchor = time; drainEpoch = epoch
            drainProcessingSeconds = 0; drainPresentationSeconds = 0; return false
        }
        // Slow rates can retain more output than nominal AU latency. Keep the
        // largest observed bound until a user action or render epoch resets it.
        drainProcessingSeconds = max(drainProcessingSeconds, processing)
        drainPresentationSeconds = max(drainPresentationSeconds, presentation)
        let rendered = Double(time.sampleTime - anchor.sampleTime) / time.sampleRate
        let deadline = AVAudioTime.seconds(forHostTime: anchor.hostTime) +
            drainProcessingSeconds + drainPresentationSeconds
        return time.sampleTime > anchor.sampleTime && rendered >= drainProcessingSeconds && now >= deadline
    }
    private func freezePosition() { heldPosition = localTime }
    private static func normalized(_ rate: Float) -> Float { rate.isFinite ? min(10, max(0.5, rate)) : 1 }

    deinit {
        refill?.cancel(); counter.cancel(); decoder?.ring.cancel()
        player.stop(); engine.stop()
    }
}

/// A renderer can be marked running while its clock no longer advances.
/// Track real sample movement, including an explicit epoch change, and fail
/// after bounded inactivity. Missing clocks do not perpetually reset the timer.
private struct NativePCMRenderWatchdog {
    private var lastSample: Int64?
    private var lastHost: UInt64?
    private var lastEpoch: Int64?
    private var lastProgressAt: Double?
    mutating func stalled(sample: Int64?, host: UInt64?, epoch: Int64,
                          now: Double, limit: Double) -> Bool {
        if lastProgressAt == nil { lastProgressAt = now }
        if let sample, let host {
            if let previousSample = lastSample, let previousHost = lastHost,
               epoch == lastEpoch {
                if sample > previousSample && host > previousHost {
                    lastProgressAt = now
                    lastSample = sample; lastHost = host
                }
            } else {
                // A changed epoch supplies a new baseline, not proof that
                // the renderer has advanced. Repeated starts cannot hide a stall.
                lastSample = sample; lastHost = host; lastEpoch = epoch
            }
        }
        return now - (lastProgressAt ?? now) >= limit
    }
}

/// Configuration notifications only advance an atomic epoch. The MainActor
/// drain gate rejects a clock anchor from a different rendering configuration.
private final class NativePCMRenderEpoch: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private var observer: NSObjectProtocol?
    init(engine: AVAudioEngine) {
        storage.initialize(to: 0)
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            _ = OSAtomicAdd64Barrier(1, self.storage)
        }
    }
    var value: Int64 { OSAtomicAdd64Barrier(0, storage) }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        storage.deinitialize(count: 1); storage.deallocate()
    }
}

/// Immutable function pointers to documented libVLC C APIs. The shipped module
/// exposes Objective-C headers only, so resolve the already linked fixed binary;
/// never inspect a private VLCKit player pointer or load a different library.
private final class NativeLibVLCAPI: @unchecked Sendable {
    typealias New = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
    typealias NewPlayer = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias NewMedia = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> OpaquePointer?
    typealias AddOption = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias SetMedia = @convention(c) (OpaquePointer?, OpaquePointer?) -> Void
    typealias Play = @convention(c) (OpaquePointer?) -> Int32
    typealias State = @convention(c) (OpaquePointer?) -> Int32
    typealias Release = @convention(c) (OpaquePointer?) -> Void
    typealias Clock = @convention(c) () -> Int64
    typealias Identity = @convention(c) () -> UnsafePointer<CChar>?
    typealias EventAttach = @convention(c) (OpaquePointer?, Int32, NativePCMEventCallback?, UnsafeMutableRawPointer?) -> Int32
    typealias EventDetach = @convention(c) (OpaquePointer?, Int32, NativePCMEventCallback?, UnsafeMutableRawPointer?) -> Void
    let create: New, createPlayer: NewPlayer, createMedia: NewMedia, addOption: AddOption
    let setMedia: SetMedia, play: Play, state: State
    let stop: Release, releasePlayer: Release, releaseMedia: Release, release: Release
    let clock: Clock
    let eventManager: NewPlayer, eventAttach: EventAttach, eventDetach: EventDetach
    private let handle: UnsafeMutableRawPointer

    init() throws {
        _ = VLCLibrary.shared()
        guard let path = Bundle(for: VLCLibrary.self).executablePath,
              let handle = dlopen(path, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL) else {
            throw NativePCMCompatibilityFailure.decoderStartup
        }
        self.handle = handle
        var initialized = false
        defer { if !initialized { dlclose(handle) } }
        let version = try Self.symbol("libvlc_get_version", Identity.self, handle: handle)
        let changeset = try Self.symbol("libvlc_get_changeset", Identity.self, handle: handle)
        guard let versionText = version(), let changesetText = changeset(),
              String(cString: versionText) == "3.0.23 Vetinari",
              String(cString: changesetText) == "3.0.23-shelf-copy-drain-input1-0-g536397a" else {
            throw NativePCMCompatibilityFailure.decoderStartup
        }
        create = try Self.symbol("libvlc_new", New.self, handle: handle)
        createPlayer = try Self.symbol("libvlc_media_player_new", NewPlayer.self, handle: handle)
        createMedia = try Self.symbol("libvlc_media_new_path", NewMedia.self, handle: handle)
        addOption = try Self.symbol("libvlc_media_add_option", AddOption.self, handle: handle)
        setMedia = try Self.symbol("libvlc_media_player_set_media", SetMedia.self, handle: handle)
        play = try Self.symbol("libvlc_media_player_play", Play.self, handle: handle)
        state = try Self.symbol("libvlc_media_player_get_state", State.self, handle: handle)
        stop = try Self.symbol("libvlc_media_player_stop", Release.self, handle: handle)
        releasePlayer = try Self.symbol("libvlc_media_player_release", Release.self, handle: handle)
        releaseMedia = try Self.symbol("libvlc_media_release", Release.self, handle: handle)
        release = try Self.symbol("libvlc_release", Release.self, handle: handle)
        clock = try Self.symbol("libvlc_clock", Clock.self, handle: handle)
        eventManager = try Self.symbol("libvlc_media_player_event_manager", NewPlayer.self, handle: handle)
        eventAttach = try Self.symbol("libvlc_event_attach", EventAttach.self, handle: handle)
        eventDetach = try Self.symbol("libvlc_event_detach", EventDetach.self, handle: handle)
        initialized = true
    }
    deinit { dlclose(handle) }
    private static func symbol<T>(_ name: String, _ type: T.Type, handle: UnsafeMutableRawPointer) throws -> T {
        guard let address = dlsym(handle, name) else {
            throw NativePCMCompatibilityFailure.missingSymbol(name)
        }
        return unsafeBitCast(address, to: type)
    }
}

public enum NativePCMCompatibilityFailure: LocalizedError, Sendable {
    case missingSymbol(String)
    case decoderStartup
    public var errorDescription: String? {
        switch self {
        case .missingSymbol(let name): "The bundled audio decoder is missing the required symbol \(name)."
        case .decoderStartup: "The bundled audio decoder could not start."
        }
    }
}

/// Immutable handles; libVLC state/stop APIs are thread-safe. The owning engine
/// confines use to MainActor, and Sendable permits its nonisolated destruction.
private final class NativePCMDecoder: @unchecked Sendable {
    let ring: NativePCMRing
    private let api: NativeLibVLCAPI
    private let instance: OpaquePointer
    private let player: OpaquePointer
    private let context: UnsafeMutableRawPointer
    private let eventManager: OpaquePointer
    private var eventAttached = false
    var state: Int32 { api.state(player) }

    init(path: String, start: Double) throws {
        let api = try NativeLibVLCAPI()
        let options = ["--no-video", "--no-play-and-pause", "--no-sout-video", "--no-sout-spu", "--quiet"]
        let strings = options.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        let pointers = strings.map { UnsafePointer<CChar>($0) as UnsafePointer<CChar>? }
        guard let instance = pointers.withUnsafeBufferPointer({ api.create(Int32($0.count), $0.baseAddress) }) else {
            throw NativePCMCompatibilityFailure.decoderStartup
        }
        guard let player = api.createPlayer(instance) else {
            api.release(instance); throw NativePCMCompatibilityFailure.decoderStartup
        }
        guard let media = path.withCString({ api.createMedia(instance, $0) }) else {
            api.releasePlayer(player); api.release(instance); throw NativePCMCompatibilityFailure.decoderStartup
        }
        guard let eventManager = api.eventManager(player) else {
            api.releaseMedia(media); api.releasePlayer(player); api.release(instance)
            throw NativePCMCompatibilityFailure.decoderStartup
        }
        let ring = NativePCMRing(clock: api.clock)
        let context = Unmanaged.passRetained(ring).toOpaque()
        let pre: NativePCMPrerender = nativePCMPrerender
        let post: NativePCMPostrender = nativePCMPostrender
        let preAddress = unsafeBitCast(pre, to: UInt.self)
        let postAddress = unsafeBitCast(post, to: UInt.self)
        // Boolean sout options use presence semantics: time-sync=0 still enables
        // pacing. no-time-sync is required for faster-than-real-time decoding.
        let sout = ":sout=#transcode{acodec=s16l,channels=2,samplerate=48000}:smem{audio-prerender-callback=\(preAddress),audio-postrender-callback=\(postAddress),audio-data=\(UInt(bitPattern: context)),no-time-sync}"
        sout.withCString { api.addOption(media, $0) }
        if start > 0 { ":start-time=\(start)".withCString { api.addOption(media, $0) } }
        api.setMedia(player, media); api.releaseMedia(media)
        self.api = api; self.instance = instance; self.player = player
        self.ring = ring; self.context = context; self.eventManager = eventManager
        guard api.eventAttach(eventManager, nativePCMPlayingEvent, nativePCMPlaying, context) == 0 else {
            throw NativePCMCompatibilityFailure.decoderStartup
        }
        eventAttached = true
        ring.begin(at: api.clock())
        guard api.play(player) == 0 else { throw NativePCMCompatibilityFailure.decoderStartup }
    }
    deinit {
        ring.cancel()
        // libvlc_stop synchronously joins input/sout teardown. The retained opaque
        // callback context is released only after no callback can still use it.
        api.stop(player)
        if eventAttached { api.eventDetach(eventManager, nativePCMPlayingEvent, nativePCMPlaying, context) }
        api.releasePlayer(player); api.release(instance)
        Unmanaged<NativePCMRing>.fromOpaque(context).release()
    }
}

// libvlc_events.h: MediaPlayerMediaChanged=0x100, then NothingSpecial,
// Opening, Buffering, Playing. This is the fixed public libVLC 3 enum value.
private let nativePCMPlayingEvent: Int32 = 0x104
private typealias NativePCMEventCallback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
private func nativePCMPlaying(_ event: UnsafeRawPointer?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<NativePCMRing>.fromOpaque(context).takeUnretainedValue().startedPlaying()
}
private typealias NativePCMPrerender = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, Int) -> Void
private typealias NativePCMPostrender = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, UInt32, UInt32, UInt32, UInt32, Int, Int64) -> Void
private func nativePCMPrerender(_ context: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, _ size: Int) {
    buffer?.pointee = size > 0 && size <= 8 * 1024 * 1024 ? malloc(size)?.assumingMemoryBound(to: UInt8.self) : nil
    if buffer?.pointee == nil, let context {
        Unmanaged<NativePCMRing>.fromOpaque(context).takeUnretainedValue().fail()
    }
}
private func nativePCMPostrender(_ context: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ channels: UInt32, _ rate: UInt32, _ frames: UInt32, _ bits: UInt32, _ size: Int, _ pts: Int64) {
    defer { free(buffer) }
    guard let context else { return }
    let ring = Unmanaged<NativePCMRing>.fromOpaque(context).takeUnretainedValue()
    guard let buffer, frames > 0, channels == 2, rate == 48_000, bits == 16,
          UInt64(frames) * 4 <= UInt64(max(0, size)) else { ring.fail(); return }
    buffer.withMemoryRebound(to: Int16.self, capacity: Int(frames) * 2) {
        ring.append($0, frames: Int(frames), pts: pts)
    }
}

/// Only the libVLC producer and MainActor scheduler access this ring. Its lock
/// never enters native audio rendering/completion. Multiple producer calls are
/// serialized, so correctness does not assume one libVLC decoder thread.
private final class NativePCMRing: @unchecked Sendable {
    private let producer = NSLock()
    private let gate = NSCondition()
    private let capacity = 240_000
    private let samples = UnsafeMutablePointer<Int16>.allocate(capacity: 480_000)
    private let positions = UnsafeMutablePointer<Int64>.allocate(capacity: 240_000)
    private var read = 0, write = 0, available = 0
    private var canceled = false, failed = false
    private let clock: NativeLibVLCAPI.Clock
    private var beganPlaying = false
    private var minimumPTS: Int64 = 0
    private var discardedPrerollFrames = 0
    private var firstPTS: Int64?
    private var lastPTS: Int64?
    init(clock: @escaping NativeLibVLCAPI.Clock) { self.clock = clock; samples.initialize(repeating: 0, count: 480_000); positions.initialize(repeating: 0, count: 240_000) }
    deinit { samples.deinitialize(count: 480_000); samples.deallocate(); positions.deinitialize(count: 240_000); positions.deallocate() }
    var hasPCM: Bool { gate.lock(); defer { gate.unlock() }; return firstPTS != nil }
    var bufferedFrames: Int { gate.lock(); defer { gate.unlock() }; return available }
    var hasFailed: Bool { gate.lock(); defer { gate.unlock() }; return failed }
    func begin(at pts: Int64) { gate.lock(); minimumPTS = max(minimumPTS, pts); gate.unlock() }
    func startedPlaying() {
        gate.lock(); defer { gate.unlock() }
        guard !beganPlaying else { return }
        // Fixed input.c emits PLAYING after Init and before MainLoop demux.
        // This stronger lower bound also excludes pre-seek timestamps when
        // opening/parsing the local file itself took longer than the seek offset.
        minimumPTS = max(minimumPTS, clock()); beganPlaying = true
    }
    func cancel() { gate.lock(); canceled = true; gate.broadcast(); gate.unlock() }
    func fail() { gate.lock(); failed = true; canceled = true; gate.broadcast(); gate.unlock() }
    func append(_ data: UnsafePointer<Int16>, frames: Int, pts: Int64) {
        // Keep callback batches ordered even when backpressure releases gate.
        producer.lock(); defer { producer.unlock() }
        gate.lock(); defer { gate.unlock() }
        // DecoderFixTs converts sout timestamps to libVLC's monotonic clock.
        // start-time is an input-control operation: a stale pre-seek block can
        // escape before it and carry PTS from the previous clock origin. It can
        // never belong to this generation if it predates its play request.
        // Compare with this fixed boundary, NOT the current clock (paused/full
        // producer buffers can legitimately be delivered much later).
        if !canceled, (!beganPlaying || (pts > 0 && pts < minimumPTS)) { discardedPrerollFrames += frames; return }
        guard !canceled, pts > 0, lastPTS.map({ pts >= $0 }) ?? true else {
            if !canceled { failed = true; canceled = true; gate.broadcast() }; return
        }
        if firstPTS == nil { firstPTS = pts }
        let relative = pts - firstPTS!
        lastPTS = pts
        var offset = 0
        while offset < frames, !canceled {
            while available == capacity, !canceled { gate.wait() }
            guard !canceled else { return }
            let count = min(frames - offset, min(capacity - available, capacity - write))
            samples.advanced(by: write * 2).update(from: data.advanced(by: offset * 2), count: count * 2)
            for index in 0..<count {
                positions[write + index] = relative + Int64(offset + index + 1) * 1_000_000 / 48_000
            }
            write = (write + count) % capacity; available += count; offset += count
        }
    }
    func pop(into buffer: AVAudioPCMBuffer, maximum: Int) -> Int64? {
        gate.lock(); defer { gate.unlock() }
        guard !canceled, available > 0, let channels = buffer.floatChannelData else { return nil }
        let count = min(maximum, available)
        for frame in 0..<count {
            let index = (read + frame) % capacity
            channels[0][frame] = Float(samples[index * 2]) / 32768
            channels[1][frame] = Float(samples[index * 2 + 1]) / 32768
        }
        let end = positions[(read + count - 1) % capacity]
        read = (read + count) % capacity; available -= count
        buffer.frameLength = AVAudioFrameCount(count)
        gate.broadcast()
        return end
    }
}

/// Separate lifetime per load/seek. stop callbacks may still be queued by AV;
/// cancellation rejects their position updates without touching a new source.
private final class NativePCMPlayedCounter: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Int64>.allocate(capacity: 3)
    init() { storage.initialize(repeating: 0, count: 3) }
    deinit { storage.deinitialize(count: 3); storage.deallocate() }
    var playedMicroseconds: Int64 { OSAtomicAdd64Barrier(0, storage) }
    var pending: Int64 { OSAtomicAdd64Barrier(0, storage.advanced(by: 1)) }
    func enqueue() { _ = OSAtomicAdd64Barrier(1, storage.advanced(by: 1)) }
    func cancel() { _ = OSAtomicCompareAndSwap64Barrier(0, 1, storage.advanced(by: 2)) }
    func complete(_ end: Int64) {
        if OSAtomicAdd64Barrier(0, storage.advanced(by: 2)) == 0 {
            var previous = OSAtomicAdd64Barrier(0, storage)
            while end > previous, !OSAtomicCompareAndSwap64Barrier(previous, end, storage) {
                previous = OSAtomicAdd64Barrier(0, storage)
            }
        }
        _ = OSAtomicAdd64Barrier(-1, storage.advanced(by: 1))
    }
}
private func nativePCMCompletion(_ counter: NativePCMPlayedCounter, _ end: Int64) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
    { _ in counter.complete(end) }
}
#endif
