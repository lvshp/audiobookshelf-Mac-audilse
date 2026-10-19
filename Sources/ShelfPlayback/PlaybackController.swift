import Foundation
import Observation
@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
@preconcurrency import AppKit
import ShelfCore

@MainActor @Observable
public final class PlaybackController {
    public private(set) var currentMedia: PlaybackMedia?
    public private(set) var position = 0.0
    public private(set) var rate: Float = 1
    public private(set) var requestedRate: Float = 1
    public private(set) var minimumRate: Float = 0.5
    public private(set) var maximumRate: Float = 10
    public var isRateLimited: Bool { abs(rate - requestedRate) > 0.0001 }
    public var onRemoteRateChange: (@MainActor @Sendable (Float) -> Void)?
    public private(set) var isPlaying = false
    public private(set) var isBuffering = false
    public private(set) var isPlaybackRequested = false {
        didSet { updatePlaybackActivity() }
    }
    public private(set) var errorDiagnostic: ClientDiagnostic?
    public var error: String? { errorDiagnostic?.fallbackMessage }
    public private(set) var syncDiagnostic: ClientDiagnostic?
    public var syncError: String? { syncDiagnostic?.fallbackMessage }
    public private(set) var sleepDeadline: Date?
    public private(set) var sleepAtChapterEnd = false
    public private(set) var queue: [PlaybackMedia] = []
    public private(set) var finalizingSessionIDs: Set<String> = []
    public var duration: Double { timeline?.duration ?? currentMedia?.duration ?? 0 }
    public var chapters: [PlaybackChapter] { currentMedia?.chapters ?? [] }
    public var currentChapter: PlaybackChapter? { timeline?.chapter(at: position, chapters: chapters) }
    public var isOffline: Bool { currentMedia != nil && remoteSessionID == nil }
    public var currentSessionID: String? { localSessionID }
    public var currentRemoteSessionID: String? { remoteSessionID }
    public var timeListening: Double { listeningClock.total }

    @ObservationIgnored private var service: (any PlaybackService)?
    @ObservationIgnored private var persistenceFactory: PlaybackPersistenceFactory?
    @ObservationIgnored private var persist: PlaybackPersistence?
    @ObservationIgnored private var checkpoint: PlaybackCheckpoint?
    @ObservationIgnored private var acknowledge: PlaybackAcknowledgement?
    @ObservationIgnored private var localProvider: PlaybackLocalProvider?
    @ObservationIgnored private var reporter: PlaybackSessionReporter?
    @ObservationIgnored private var player = AVQueuePlayer()
    @ObservationIgnored private var compatibility: LocalCompatibilityEngine?
    @ObservationIgnored private var timeline: PlaybackTimeline?
    @ObservationIgnored private var itemTracks: [ObjectIdentifier: PlaybackTrack] = [:]
    @ObservationIgnored private var currentTrack: PlaybackTrack?
    @ObservationIgnored private var stateObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    private static weak var systemMediaOwner: PlaybackController?
    @ObservationIgnored private(set) var systemMediaControlToken: UUID?
    @ObservationIgnored private var remoteTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var sleepTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var resourceLoaders: [ObjectIdentifier: PlaybackResourceLoader] = [:]
    @ObservationIgnored private var hlsProxies: [ObjectIdentifier: HLSStreamProxy] = [:]
    @ObservationIgnored private var itemTimeOffsets: [ObjectIdentifier: Double] = [:]
    @ObservationIgnored private var hlsCancellation: Task<Void, Never>?
    @ObservationIgnored private var startingHLSProxy: HLSStreamProxy?
    @ObservationIgnored private var nativeTimeOffset = 0.0
    public var ownsSystemMediaControls: Bool { Self.systemMediaOwner === self && systemMediaControlToken != nil }
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var jumpForwardAmount = 30.0
    @ObservationIgnored private var jumpBackwardAmount = 15.0
    @ObservationIgnored private var remoteRateStep = 0.1
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var pendingLoad: UUID?
    @ObservationIgnored private var readinessTask: Task<Void, Error>?
    @ObservationIgnored private var readinessID: UUID?
    @ObservationIgnored private var seekGeneration = UUID()
    @ObservationIgnored private var localSessionID: String?
    @ObservationIgnored private var remoteSessionID: String?
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private var lastUpdatedAt = 0.0
    @ObservationIgnored private var listeningClock = ListeningClock()
    @ObservationIgnored private var playbackActivity: NSObjectProtocol?
    @ObservationIgnored private var lastReportTime = 0.0
    @ObservationIgnored private var chapterSleepPosition: Double?
    @ObservationIgnored private var retriedTrack: Int?
    @ObservationIgnored private var retryListeningBaseline = 0.0
    @ObservationIgnored private var nowPlayingArtwork: MPMediaItemArtwork?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var shouldResumeAfterWake = false
    @ObservationIgnored private var hasFinished = false
    @ObservationIgnored private var serverMutationBarrierCount = 0
    @ObservationIgnored private var lifecycleTransitionCount = 0
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var finalizations: [UUID: PlaybackRecoveryHandle] = [:]
    private final class PreparationOwnership { var adopted = false }
    @ObservationIgnored private var pendingQuit: PlaybackRecoveryHandle?
    @ObservationIgnored private var quitTask: Task<PlaybackQuitReceipt, Never>?
    private var blocksPlaybackActions: Bool { serverMutationBarrierCount > 0 || lifecycleTransitionCount > 0 || isShutDown || pendingQuit != nil }

    public init(ownsSystemMediaControls: Bool = true, service: (any PlaybackService)? = nil, persist: PlaybackPersistence? = nil,
                checkpoint: PlaybackCheckpoint? = nil, didSynchronize: PlaybackAcknowledgement? = nil,
                localProvider: PlaybackLocalProvider? = nil, persistenceFactory: PlaybackPersistenceFactory? = nil) {
        self.service = service; self.persist = persist; self.checkpoint = checkpoint; self.acknowledge = didSynchronize
        self.localProvider = localProvider; self.persistenceFactory = persistenceFactory
        observePlayer()
        if ownsSystemMediaControls { setSystemMediaControlsActive(true) }
        startTicker()
    }

    /// Call after stopping the previous account; snapshots retain the account's
    /// original injected closures while in-flight close requests finish.
    public func configure(service: (any PlaybackService)?, persist: PlaybackPersistence? = nil,
                          checkpoint: PlaybackCheckpoint? = nil, didSynchronize: PlaybackAcknowledgement? = nil,
                          localProvider: PlaybackLocalProvider? = nil, persistenceFactory: PlaybackPersistenceFactory? = nil) async {
        guard !isShutDown, pendingQuit == nil else { return }
        lifecycleTransitionCount += 1
        defer { lifecycleTransitionCount -= 1 }
        let operation = UUID()
        let receipt = await stop(replacingWith: operation)
        guard receipt.mayQuit, operation == generation else { return }
        self.service = service; self.persist = persist; self.checkpoint = checkpoint; self.acknowledge = didSynchronize
        self.localProvider = localProvider; self.persistenceFactory = persistenceFactory
    }

    public func play(media: PlaybackMedia, following: [PlaybackMedia]? = nil, initialPosition: Double? = nil) async {
        guard !Task.isCancelled, !blocksPlaybackActions else { return }
        if let initialPosition, !initialPosition.isFinite || initialPosition < 0 {
            errorDiagnostic = .capture(PlaybackFailure.invalidStartPosition)
            return
        }
        let operation = UUID()
        let receipt = await stop(replacingWith: operation)
        guard receipt.mayQuit, generation == operation, !Task.isCancelled else { return }
        isBuffering = true; errorDiagnostic = nil; syncDiagnostic = nil
        do {
            let activeService = service
            let prepared: PreparedPlayback
            if let local = try await localProvider?(media) { prepared = local }
            else {
                try Task.checkCancellation()
                guard let activeService else { throw PlaybackFailure.unavailableService }
                prepared = try await activeService.prepare(media: media)
            }
            guard generation == operation, !Task.isCancelled else {
                await Self.closeUnadoptedSession(prepared, using: activeService)
                if generation == operation { isBuffering = false }
                return
            }
            if let following { queue = following }
            let ownership = PreparationOwnership()
            do { try await begin(prepared, initialPosition: initialPosition, operation: operation, ownership: ownership) }
            catch {
                // Timeline validation happens before controller state is adopted.
                // Even malformed sessions must be closed on the server.
                if !ownership.adopted {
                    await Self.closeUnadoptedSession(prepared, using: activeService)
                }
                throw error
            }
        } catch {
            guard generation == operation else { return }
            let cancelled = Self.isCancellation(error)
            let diagnostic = ClientDiagnostic.capture(error)
            await stop(replacingWith: operation)
            guard generation == operation else { return }
            if !cancelled { self.errorDiagnostic = diagnostic }
            isBuffering = false; isPlaying = false
        }
    }

    public func playOffline(media: PlaybackMedia, tracks: [PlaybackTrack], initialPosition: Double = 0, following: [PlaybackMedia]? = nil) async {
        guard !Task.isCancelled, !blocksPlaybackActions else { return }
        let operation = UUID()
        let receipt = await stop(replacingWith: operation)
        guard receipt.mayQuit, generation == operation, !Task.isCancelled else { return }
        if let following { queue = following }
        errorDiagnostic = nil; syncDiagnostic = nil; isBuffering = true
        do {
            guard tracks.allSatisfy({ $0.isLocal && $0.url.isFileURL && FileManager.default.isReadableFile(atPath: $0.url.path) }) else {
                throw PlaybackFailure.invalidLocalFile
            }
            try await begin(PreparedPlayback(media: media, tracks: tracks, sessionID: nil, initialPosition: initialPosition), operation: operation)
        } catch {
            guard generation == operation else { return }
            let cancelled = Self.isCancellation(error)
            let diagnostic = ClientDiagnostic.capture(error)
            await stop(replacingWith: operation)
            guard generation == operation else { return }
            if !cancelled { self.errorDiagnostic = diagnostic }
            isBuffering = false; isPlaying = false
        }
    }

    private func begin(_ prepared: PreparedPlayback, initialPosition: Double? = nil, operation: UUID, ownership: PreparationOwnership? = nil) async throws {
        try Task.checkCancellation()
        guard generation == operation else { return }
        timeline = try PlaybackTimeline(tracks: prepared.tracks)
        ownership?.adopted = true
        currentMedia = prepared.media; remoteSessionID = prepared.sessionID
        localSessionID = prepared.sessionID ?? UUID().uuidString
        startedAt = prepared.startedAt; lastUpdatedAt = startedAt
        retriedTrack = nil; hasFinished = false
        listeningClock.reset(); lastReportTime = ProcessInfo.processInfo.systemUptime
        reporter = PlaybackSessionReporter(service: service, remoteSessionID: prepared.sessionID,
                                           persist: persist, checkpoint: checkpoint, acknowledge: acknowledge, recoveryPersist: persistenceFactory?(prepared.media))
        isPlaybackRequested = true
        // Apply a historical position before activating the engine or publishing
        // its first checkpoint. Retain the server's original preparation value
        // for cleanup when this operation never adopts its remote session.
        try await load(at: initialPosition ?? prepared.initialPosition, autoplay: true, operation: operation)
        guard generation == operation else { return }
        loadArtwork(for: prepared.media, operation: operation)
        // Once load has handed the ready item to an engine, closing its UI must
        // not cancel background playback while the durable report finishes.
        await report()
    }

    private static func closeUnadoptedSession(_ prepared: PreparedPlayback, using service: (any PlaybackService)?) async {
        guard let id = prepared.sessionID, let service else { return }
        // Cleanup must reach URLSession even when its caller was cancelled.
        let cleanup = Task { try? await service.close(sessionID: id, currentTime: prepared.initialPosition, timeListened: 0) }
        await cleanup.value
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    public func resume() {
        guard !blocksPlaybackActions, currentMedia != nil, error == nil else { return }
        isPlaybackRequested = true
        if position >= duration { Task { await seek(to: 0) }; return }
        if let compatibility { compatibility.play(rate: rate) } else { player.playImmediately(atRate: rate) }
        refreshPlayerState()
    }

    public func pause() {
        accountListeningTime()
        isPlaybackRequested = false; player.pause(); compatibility?.pause()
        updatePositionFromEngine()
        isPlaying = false; isBuffering = false
        listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
        updateNowPlaying()
        Task { await report() }
    }

    public func togglePlayPause() { isPlaybackRequested ? pause() : resume() }

    public func stop() async {
        guard !blocksPlaybackActions else { return }
        await stop(replacingWith: UUID())
    }

    /// Flush this device's selected remote session without sending close; the
    /// management caller holds the synchronization lease and owns that request.
    @discardableResult public func prepareServerSessionMutation(sessionID: String) async throws -> Bool {
        try Task.checkCancellation()
        guard remoteSessionID == sessionID, let reporter else { return false }
        guard !blocksPlaybackActions else { throw OfflineSyncError.alreadyRunning }
        serverMutationBarrierCount += 1
        defer { serverMutationBarrierCount -= 1 }
        let operation = generation
        pauseForSessionBarrier()
        guard let snapshot = snapshot() else { return false }
        if let failure = await reporter.flushForServerMutation(snapshot) {
            if generation == operation { syncDiagnostic = failure }
            throw failure
        }
        guard generation == operation, remoteSessionID == sessionID else { return false }
        await stop(replacingWith: UUID(), reportFinalSnapshot: false)
        return true
    }

    /// ABS Web closes the exact matching player without reporting to the server
    /// again. Preserve this Mac's unsent cumulative history locally first.
    @discardableResult public func serverSessionClosed(sessionID: String) async throws -> Bool {
        guard remoteSessionID == sessionID, let reporter else { return false }
        let operation = generation
        serverMutationBarrierCount += 1
        defer { serverMutationBarrierCount -= 1 }
        pauseForSessionBarrier()
        guard let snapshot = snapshot() else { return false }
        if let failure = await reporter.preserveAfterRemoteClosure(snapshot) {
            if generation == operation { syncDiagnostic = failure; errorDiagnostic = failure }
            throw failure
        }
        guard generation == operation, remoteSessionID == sessionID else { return false }
        await stop(replacingWith: UUID(), reportFinalSnapshot: false)
        return true
    }

    private func pauseForSessionBarrier() {
        accountListeningTime()
        isPlaybackRequested = false; player.pause(); compatibility?.pause()
        updatePositionFromEngine()
        isPlaying = false; isBuffering = false
        listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
        lastUpdatedAt = Date().timeIntervalSince1970 * 1_000
        updateNowPlaying()
    }

    @discardableResult private func stop(replacingWith operation: UUID, reportFinalSnapshot: Bool = true) async -> PlaybackQuitReceipt {
        detachCurrentPlayback(replacingWith: operation, reportFinalSnapshot: reportFinalSnapshot)
        return await drainFinalizations()
    }

    private func detachCurrentPlayback(replacingWith operation: UUID, reportFinalSnapshot: Bool) {
        generation = operation; loadGeneration = UUID(); seekGeneration = UUID()
        readinessTask?.cancel(); readinessTask = nil; readinessID = nil
        accountListeningTime()
        isPlaybackRequested = false; player.pause(); compatibility?.pause()
        updatePositionFromEngine()
        pendingLoad = nil
        compatibility?.stop(); compatibility = nil
        selectRate(usesCompatibility: false)
        isPlaying = false; isBuffering = false
        listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
        let finalSnapshot = snapshot()
        let finalReporter = reporter
        if reportFinalSnapshot, let finalSnapshot, let finalReporter {
            let context = PlaybackRecoveryHandle(snapshot: finalSnapshot, reporter: finalReporter)
            finalizations[context.id] = context
            finalizingSessionIDs.insert(finalSnapshot.id)
        }
        cancelResourceLoaders()
        player.removeAllItems(); itemTracks.removeAll(); itemObservation = nil; currentTrack = nil
        currentMedia = nil; timeline = nil; position = 0; reporter = nil
        localSessionID = nil; remoteSessionID = nil; cancelSleepTimer()
        artworkTask?.cancel(); nowPlayingArtwork = nil
        clearNowPlayingIfOwner()
    }

    /// Each drain attempts its captured bundles once. Failed cumulative snapshots
    /// remain owned here, including after the visible player has been detached.
    @discardableResult private func drainFinalizations() async -> PlaybackQuitReceipt {
        let pending = finalizations
        var failure: PlaybackQuitReceipt?
        for (id, context) in pending {
            guard finalizations[id] != nil else { continue }
            let receipt = await context.finalize()
            // A concurrent drain may have already consumed or transferred it.
            if finalizations[id] != nil {
                if receipt.mayQuit {
                    finalizations[id] = nil
                    finalizingSessionIDs.remove(context.sessionID)
                } else {
                    failure = failure ?? receipt
                    syncDiagnostic = receipt.diagnostic; errorDiagnostic = receipt.diagnostic
                }
            }
        }
        return failure ?? .noActiveSession
    }

    /// Transfer ownership before an account/permission transition drops its player.
    /// This method has no suspension point: callers can retain every handle first,
    /// then revoke its network authority and retry original-source local writes.
    public func detachForRecovery() -> [PlaybackRecoveryHandle] {
        if let pendingQuit { finalizations[pendingQuit.id] = pendingQuit }
        let alreadyFrozen = pendingQuit != nil
        pendingQuit = nil
        detachCurrentPlayback(replacingWith: UUID(), reportFinalSnapshot: !alreadyFrozen)
        isShutDown = true
        removeShutdownObservers()
        let handles = Array(finalizations.values)
        finalizations.removeAll(); finalizingSessionIDs.removeAll()
        return handles
    }

    /// A voluntary account switch can still fail or be cancelled after saving.
    /// Keep this controller reusable until the caller actually replaces it.
    public func checkpointForTransition() async -> PlaybackQuitReceipt {
        guard serverMutationBarrierCount == 0, quitTask == nil else {
            return PlaybackQuitReceipt(sessionID: currentSessionID, remoteCumulativeConfirmed: false,
                cumulativeSnapshotSaved: false, checkpointSaved: false,
                diagnostic: .capture(OfflineSyncError.alreadyRunning), transitionInProgress: true)
        }
        lifecycleTransitionCount += 1
        defer { lifecycleTransitionCount -= 1 }
        if let pendingQuit {
            finalizations[pendingQuit.id] = pendingQuit
            finalizingSessionIDs.insert(pendingQuit.sessionID)
            self.pendingQuit = nil
            detachCurrentPlayback(replacingWith: UUID(), reportFinalSnapshot: false)
            return await drainFinalizations()
        }
        return await stop(replacingWith: UUID())
    }

    /// Shutdown is explicit so the application can await durable save and server
    /// close before terminating instead of relying on asynchronous deinit work.
    public func shutdown() async {
        // A failed explicit quit owns its original frozen snapshot and reporter.
        // A later ordinary lifecycle call must not destroy that retry state.
        guard pendingQuit == nil else { return }
        lifecycleTransitionCount += 1
        defer { lifecycleTransitionCount -= 1 }
        let receipt = await stop(replacingWith: UUID())
        guard receipt.mayQuit else { return }
        isShutDown = true
        removeShutdownObservers()
    }

    /// Explicit application quit has a durability gate. Failed attempts keep the
    /// same paused session, cumulative snapshot and account-bound reporter.
    /// Previously detached ordinary stops also participate in this gate.
    public func shutdownForQuit() async -> PlaybackQuitReceipt {
        // A management flush owns this generation until it detaches the player.
        // Do not invalidate that ownership or freeze its detached reporter into
        // an unretryable quit. The caller can retry after the barrier completes.
        guard serverMutationBarrierCount == 0 else {
            return PlaybackQuitReceipt(sessionID: currentSessionID, remoteCumulativeConfirmed: false,
                cumulativeSnapshotSaved: false, checkpointSaved: false,
                diagnostic: .capture(OfflineSyncError.alreadyRunning), transitionInProgress: true)
        }
        if isShutDown {
            return await drainFinalizations()
        }
        lifecycleTransitionCount += 1
        defer { lifecycleTransitionCount -= 1 }
        if pendingQuit == nil {
            generation = UUID(); loadGeneration = UUID(); seekGeneration = UUID()
            readinessTask?.cancel(); readinessTask = nil; readinessID = nil
            accountListeningTime()
            isPlaybackRequested = false; player.pause(); compatibility?.pause()
            updatePositionFromEngine()
            pendingLoad = nil
            isPlaying = false; isBuffering = false
            listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
            lastUpdatedAt = Date().timeIntervalSince1970 * 1_000
            cancelSleepTimer(); updateNowPlaying()
            if let snapshot = snapshot(), let reporter {
                pendingQuit = PlaybackRecoveryHandle(snapshot: snapshot, reporter: reporter)
            }
        }
        guard let context = pendingQuit else {
            let receipt = await drainFinalizations()
            guard receipt.mayQuit else { return receipt }
            isShutDown = true
            removeShutdownObservers()
            return receipt
        }
        let task: Task<PlaybackQuitReceipt, Never>
        if let quitTask { task = quitTask }
        else {
            task = Task { [self] in
                let previous = await drainFinalizations()
                guard previous.mayQuit else { return previous }
                return await context.finalize()
            }
            quitTask = task
        }
        let receipt = await task.value
        guard pendingQuit?.id == context.id else { return receipt }
        quitTask = nil
        guard receipt.mayQuit else {
            syncDiagnostic = receipt.diagnostic; errorDiagnostic = receipt.diagnostic
            return receipt
        }
        pendingQuit = nil
        isShutDown = true
        await stop(replacingWith: UUID(), reportFinalSnapshot: false)
        await drainFinalizations()
        removeShutdownObservers()
        return receipt
    }

    private func removeShutdownObservers() {
        setSystemMediaControlsActive(false)
        cancelResourceLoaders()
        tickTask?.cancel(); tickTask = nil
        stateObservations.removeAll(); itemObservation = nil
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notificationTokens.removeAll()
        remoteTargets.forEach { $0.0.removeTarget($0.1) }; remoteTargets.removeAll()
    }

    public func seek(to seconds: Double) async {
        guard !Task.isCancelled, !blocksPlaybackActions else { return }
        guard let timeline else { return }
        let operation = generation
        let seeking = UUID(); seekGeneration = seeking
        let target = timeline.position(at: seconds)
        accountListeningTime()
        listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
        let autoplay = isPlaybackRequested
        do {
            if currentTrack?.index == target.trackIndex, let compatibility, !compatibility.hasEnded {
                compatibility.seek(to: target.localTime)
                if autoplay { compatibility.play(rate: rate) }
            } else if currentTrack?.index == target.trackIndex, let currentTrack,
                      !Self.isHLS(currentTrack), player.currentItem != nil {
                let loading = UUID(); pendingLoad = loading
                accountListeningTime(); player.pause(); refreshPlayerState()
                defer { if pendingLoad == loading { pendingLoad = nil; refreshPlayerState() } }
                try await prepareForSeek(track: currentTrack, localTime: target.localTime)
                try Task.checkCancellation()
                guard generation == operation, seekGeneration == seeking else { return }
                let completed = await player.seek(to: CMTime(seconds: target.localTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                try Task.checkCancellation()
                guard generation == operation, seekGeneration == seeking else { return }
                guard completed else { throw PlaybackFailure.seekInterrupted }
                if isPlaybackRequested { player.playImmediately(atRate: rate) }
            } else {
                try await load(at: target.absoluteTime, autoplay: autoplay, operation: operation)
            }
            guard generation == operation, seekGeneration == seeking else { return }
            position = target.absoluteTime; lastUpdatedAt = Date().timeIntervalSince1970 * 1_000
            if position < duration { hasFinished = false }
            updateNowPlaying(); await report()
        } catch {
            guard generation == operation, seekGeneration == seeking else { return }
            if !Self.isCancellation(error) { self.errorDiagnostic = .capture(error) }
            pause()
        }
    }

    public func skip(by seconds: Double) async { await seek(to: position + seconds) }
    public func playChapter(_ chapter: PlaybackChapter) async { await seek(to: chapter.start) }
    public func setRate(_ value: Float) {
        guard value.isFinite else { return }
        requestedRate = Float(PlaybackRatePolicy.normalized(Double(value)))
        selectRate(usesCompatibility: compatibility != nil, item: player.currentItem)
        if let compatibility { compatibility.setRate(rate) }
        else if isPlaybackRequested { player.rate = rate }
        updateNowPlaying()
    }
    public func canAdjustRate(by amount: Double) -> Bool {
        guard amount.isFinite else { return false }
        let next = PlaybackRatePolicy.adjusted(Double(rate), by: amount)
        return next >= Double(minimumRate) && next <= Double(maximumRate)
    }
    private func requestRemoteRateChange(_ value: Float) {
        guard value.isFinite else { return }
        if let handler = onRemoteRateChange { handler(value) }
        else { setRate(value) }
    }
    private func selectRate(usesCompatibility: Bool, item: AVPlayerItem? = nil) {
        var lower = Float(PlaybackRatePolicy.minimum)
        var upper = Float(PlaybackRatePolicy.maximum)
        if usesCompatibility { upper = LocalCompatibilityEngine.maximumRate }
        else if let item, item.status == .readyToPlay {
            // A ready item's false fast-forward capability still permits 1–2×.
            // Unknown items cannot supply reliable capabilities yet.
            if !item.canPlayFastForward { upper = 2 }
            if !item.canPlaySlowForward { lower = 1 }
        }
        let changed = lower != minimumRate || upper != maximumRate
        minimumRate = lower; maximumRate = upper
        rate = min(upper, max(lower, requestedRate))
        if changed { publishRemotePlaybackRates() }
    }
    private func publishRemotePlaybackRates() {
        guard ownsSystemMediaControls else { return }
        MPRemoteCommandCenter.shared().changePlaybackRateCommand.supportedPlaybackRates = PlaybackRatePolicy.rates(
            step: remoteRateStep, minimum: Double(minimumRate), maximum: Double(maximumRate)
        ).map { NSNumber(value: $0) }
    }
    /// Keep the system media controls consistent with this account's local preferences.
    public func configureRemoteCommands(jumpForward: Double, jumpBackward: Double, rateStep: Double) {
        jumpForwardAmount = jumpForward.isFinite ? min(300, max(5, jumpForward)) : 30
        jumpBackwardAmount = jumpBackward.isFinite ? min(300, max(5, jumpBackward)) : 15
        remoteRateStep = rateStep == 0.05 ? 0.05 : 0.1
        guard ownsSystemMediaControls else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: jumpForwardAmount)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: jumpBackwardAmount)]
        publishRemotePlaybackRates()
    }
    public func setSleepTimer(minutes: Int) {
        chapterSleepPosition = nil; sleepAtChapterEnd = false
        sleepDeadline = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
    }
    public func stopAtChapterEnd() {
        sleepDeadline = nil; chapterSleepPosition = currentChapter?.end ?? (duration > 0 ? duration : nil)
        sleepAtChapterEnd = chapterSleepPosition != nil
    }
    public func cancelSleepTimer() { sleepDeadline = nil; sleepAtChapterEnd = false; chapterSleepPosition = nil }
    public func enqueue(_ media: PlaybackMedia) { queue.append(media) }
    public func removeFromQueue(at offsets: IndexSet) { for i in offsets.sorted(by: >) where queue.indices.contains(i) { queue.remove(at: i) } }
    public func playNext() async {
        guard !Task.isCancelled, !blocksPlaybackActions else { return }
        guard !queue.isEmpty else { return }
        let operation = UUID()
        let receipt = await stop(replacingWith: operation)
        guard receipt.mayQuit, generation == operation, !Task.isCancelled,
              !blocksPlaybackActions, !queue.isEmpty else { return }
        // Read the live queue after the gate so edits made while saving survive.
        let next = queue.removeFirst(); await play(media: next)
    }

    private func load(at seconds: Double, autoplay: Bool, operation: UUID) async throws {
        try Task.checkCancellation()
        guard operation == generation else { return }
        guard let timeline else { return }
        let target = timeline.position(at: seconds)
        guard let track = timeline.tracks.first(where: { $0.index == target.trackIndex }) else { throw PlaybackFailure.invalidTimeline }
        let loading = UUID(); loadGeneration = loading
        let seeking = seekGeneration
        pendingLoad = loading
        defer { if pendingLoad == loading { pendingLoad = nil; refreshPlayerState() } }
        accountListeningTime()
        player.pause()
        listeningClock.update(monotonicTime: ProcessInfo.processInfo.systemUptime, isPlaying: false)
        cancelResourceLoaders()
        player.removeAllItems(); itemObservation = nil; itemTracks.removeAll()
        compatibility?.stop(); compatibility = nil
        currentTrack = track; nativeTimeOffset = 0; position = target.absoluteTime; isBuffering = true
        // Old segment requests must finish cancelling before a new seek target
        // is sent to ABS's single on-demand transcoder.
        await hlsCancellation?.value
        try Task.checkCancellation()
        guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
        if LocalCompatibilityEngine.needsCompatibility(track) {
            selectRate(usesCompatibility: true)
            let engine = LocalCompatibilityEngine()
            try engine.load(track, localTime: target.localTime, rate: rate, autoplay: autoplay)
            compatibility = engine; isBuffering = engine.isBuffering
        } else {
            let authorized = try await authorize(track)
            try Task.checkCancellation()
            guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
            do {
                try await prepareForSeek(track: authorized, localTime: target.localTime)
                try Task.checkCancellation()
            }
            catch {
                guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
                throw error
            }
            guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
            let (asset, loader, proxy, timeOffset) = try await makeAsset(for: authorized, localTime: target.localTime)
            guard !Task.isCancelled, operation == generation, loading == loadGeneration, seeking == seekGeneration else { loader?.cancelAll(); await proxy?.cancel(); return }
            var playable = true
            if track.isLocal { playable = try await asset.load(.isPlayable) }
            try Task.checkCancellation()
            guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
            if !playable {
                selectRate(usesCompatibility: true)
                let engine = LocalCompatibilityEngine()
                try engine.load(track, localTime: target.localTime, rate: rate, autoplay: autoplay)
                compatibility = engine; isBuffering = engine.isBuffering
                return
            }
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .timeDomain
            if proxy != nil { item.preferredForwardBufferDuration = 12; item.canUseNetworkResourcesForLiveStreamingWhilePaused = false }
            nativeTimeOffset = timeOffset
            hlsProxies[ObjectIdentifier(item)] = proxy
            itemTimeOffsets[ObjectIdentifier(item)] = timeOffset
            itemTracks[ObjectIdentifier(item)] = track
            resourceLoaders[ObjectIdentifier(item)] = loader
            player.insert(item, after: nil)
            observeCurrentItem()
            let completed = await player.seek(to: CMTime(seconds: max(0, target.localTime - timeOffset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
            guard completed else { throw PlaybackFailure.seekInterrupted }
            if let proxy, await proxy.hasFailed { throw PlaybackFailure.streamNotReady }
            guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
            selectRate(usesCompatibility: false, item: item)
            if isPlaybackRequested { player.playImmediately(atRate: rate) }
            await appendNextTrack(operation: operation, loading: loading)
        }
        guard operation == generation, loading == loadGeneration, seeking == seekGeneration else { return }
        errorDiagnostic = nil; refreshPlayerState(); updateNowPlaying()
    }

    private static func isHLS(_ track: PlaybackTrack) -> Bool {
        !track.isLocal && track.url.pathExtension.lowercased() == "m3u8"
    }

    private func makeAsset(for track: PlaybackTrack, localTime: Double = 0) async throws -> (AVURLAsset, PlaybackResourceLoader?, HLSStreamProxy?, Double) {
        if Self.isHLS(track) {
            let proxy = HLSStreamProxy(manifestURL: track.url)
            startingHLSProxy = proxy
            defer { if startingHLSProxy === proxy { startingHLSProxy = nil } }
            do {
                let url = try await proxy.start(at: localTime)
                try Task.checkCancellation()
                return (AVURLAsset(url: url), nil, proxy, await proxy.timeOffset)
            } catch { await proxy.cancel(); throw error }
        }
        if !track.isLocal, let source = try await service?.resourceSource(for: track) {
            try Task.checkCancellation()
            let loader = PlaybackResourceLoader(source: source, filenameExtension: track.url.pathExtension)
            return (loader.makeAsset(), loader, nil, 0)
        }
        return (AVURLAsset(url: track.url), nil, nil, 0)
    }
    private func cancelResourceLoaders() {
        resourceLoaders.values.forEach { $0.cancelAll() }
        resourceLoaders.removeAll()
        let proxies = Array(hlsProxies.values) + [startingHLSProxy].compactMap { $0 }
        startingHLSProxy = nil
        hlsProxies.removeAll(); itemTimeOffsets.removeAll()
        let previous = hlsCancellation
        hlsCancellation = Task {
            await previous?.value
            for proxy in proxies { await proxy.cancel() }
        }
    }

    private func authorize(_ track: PlaybackTrack) async throws -> PlaybackTrack {
        guard !track.isLocal, let service else { return track }
        return try await service.authorize(track: track)
    }

    private func prepareForSeek(track: PlaybackTrack, localTime: Double) async throws {
        guard !track.isLocal, let service else { return }
        readinessTask?.cancel()
        let id = UUID(); readinessID = id
        let task = Task { try await service.prepareToSeek(track: track, localTime: localTime) }
        readinessTask = task
        defer { if readinessID == id { readinessTask = nil; readinessID = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func appendNextTrack(operation: UUID, loading: UUID) async {
        guard !Task.isCancelled else { return }
        guard let timeline, let currentTrack,
              let i = timeline.tracks.firstIndex(where: { $0.index == currentTrack.index }),
              timeline.tracks.indices.contains(i + 1) else { return }
        let next = timeline.tracks[i + 1]
        guard !Self.isHLS(next), !LocalCompatibilityEngine.needsCompatibility(next), !player.items().contains(where: { itemTracks[ObjectIdentifier($0)]?.index == next.index }) else { return }
        do {
            let authorized = try await authorize(next)
            guard !Task.isCancelled, operation == generation, loading == loadGeneration,
                  !player.items().contains(where: { itemTracks[ObjectIdentifier($0)]?.index == next.index }) else { return }
            let (asset, loader, _, _) = try await makeAsset(for: authorized)
            guard !Task.isCancelled, operation == generation, loading == loadGeneration,
                  !player.items().contains(where: { itemTracks[ObjectIdentifier($0)]?.index == next.index }) else { loader?.cancelAll(); return }
            let item = AVPlayerItem(asset: asset); item.audioTimePitchAlgorithm = .timeDomain
            resourceLoaders[ObjectIdentifier(item)] = loader
            itemTracks[ObjectIdentifier(item)] = next
            player.insert(item, after: player.items().last)
        } catch { /* Current track stays usable. Next track will be retried on transition. */ }
    }

    private func observePlayer() {
        stateObservations = [
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.refreshPlayerState() } },
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.currentItemChanged() } }
        ]
        notificationTokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let identifier = ObjectIdentifier(item)
            Task { @MainActor in await self?.itemEnded(identifier) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            let identifier = ObjectIdentifier(item)
            Task { @MainActor in await self?.itemFailed(identifier) }
        })
    }

    private func observeCurrentItem() {
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player.currentItem?.status == .failed, let item = self.player.currentItem { await self.itemFailed(ObjectIdentifier(item)) }
                else { self.refreshPlayerState() }
            }
        }
    }

    private func currentItemChanged() {
        guard pendingQuit == nil, !isShutDown else { return }
        let retainedItems = Set(player.items().map(ObjectIdentifier.init))
        for id in resourceLoaders.keys.filter({ !retainedItems.contains($0) }) {
            resourceLoaders.removeValue(forKey: id)?.cancelAll()
        }
        for id in hlsProxies.keys.filter({ !retainedItems.contains($0) }) {
            if let proxy = hlsProxies.removeValue(forKey: id) { Task { await proxy.cancel() } }
            itemTimeOffsets.removeValue(forKey: id)
        }
        if let item = player.currentItem, let track = itemTracks[ObjectIdentifier(item)] {
            nativeTimeOffset = itemTimeOffsets[ObjectIdentifier(item)] ?? 0
            currentTrack = track; observeCurrentItem()
            let operation = generation, loading = loadGeneration
            Task { await appendNextTrack(operation: operation, loading: loading) }
        }
        refreshPlayerState()
    }

    private func itemEnded(_ identifier: ObjectIdentifier) async {
        guard pendingQuit == nil, !isShutDown else { return }
        guard let ended = itemTracks[identifier], let timeline,
              let i = timeline.tracks.firstIndex(where: { $0.index == ended.index }) else { return }
        if timeline.tracks.indices.contains(i + 1) {
            let next = timeline.tracks[i + 1]
            if player.currentItem == nil || LocalCompatibilityEngine.needsCompatibility(next) {
                let operation = generation
                do { try await load(at: next.startOffset, autoplay: isPlaybackRequested, operation: operation) }
                catch {
                    guard operation == generation else { return }
                    self.errorDiagnostic = .capture(error)
                    pause()
                }
            }
        } else { await finishMedia() }
    }

    private func itemFailed(_ identifier: ObjectIdentifier) async {
        guard pendingQuit == nil, !isShutDown else { return }
        guard let track = itemTracks[identifier], track.index == currentTrack?.index else { return }
        let operation = generation
        if track.isLocal, retriedTrack != track.index {
            retriedTrack = track.index
            retryListeningBaseline = listeningClock.total
            do {
                accountListeningTime(); cancelResourceLoaders(); player.pause(); player.removeAllItems()
                selectRate(usesCompatibility: true)
                let engine = LocalCompatibilityEngine()
                try engine.load(track, localTime: max(0, position - track.startOffset), rate: rate, autoplay: isPlaybackRequested)
                compatibility = engine; refreshPlayerState()
                return
            } catch { self.errorDiagnostic = .capture(error) }
        }
        if !track.isLocal, retriedTrack != track.index {
            retriedTrack = track.index
            retryListeningBaseline = listeningClock.total
            let saved = position
            do { try await load(at: saved, autoplay: isPlaybackRequested, operation: operation); return } catch { }
        }
        guard operation == generation else { return }
        accountListeningTime(); errorDiagnostic = player.currentItem?.error.map(ClientDiagnostic.capture) ??
            .init(code: "playback.engineFailed", fallbackMessage: "音频播放失败，请检查网络或重新下载。")
        isPlaybackRequested = false; player.pause(); isPlaying = false; isBuffering = false
        await report()
    }

    private func refreshPlayerState() {
        // AVFoundation can deliver an earlier playing state after pause/quit.
        // The final snapshot owns position and listening time until retry ends.
        guard pendingQuit == nil, !isShutDown else { return }
        let previousRate = rate
        selectRate(usesCompatibility: compatibility != nil, item: player.currentItem)
        if rate != previousRate, isPlaybackRequested {
            if let compatibility { compatibility.setRate(rate) }
            else { player.rate = rate }
        }
        let playing = pendingLoad == nil && (compatibility?.isPlaying ?? (player.timeControlStatus == .playing))
        listeningClock.update(monotonicTime: compatibility?.listeningClockTime ?? ProcessInfo.processInfo.systemUptime,
                              isPlaying: pendingLoad == nil && (compatibility?.isListening ?? playing))
        isPlaying = playing
        isBuffering = isPlaybackRequested && (pendingLoad != nil || (compatibility?.isBuffering ?? (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)))
        updateNowPlaying()
    }

    private func updatePlaybackActivity() {
        if isPlaybackRequested, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Audiobook playback and listening progress")
        } else if !isPlaybackRequested, let playbackActivity {
            ProcessInfo.processInfo.endActivity(playbackActivity)
            self.playbackActivity = nil
        }
    }

    private func accountListeningTime() {
        guard pendingQuit == nil, !isShutDown else { return }
        listeningClock.update(monotonicTime: compatibility?.listeningClockTime ?? ProcessInfo.processInfo.systemUptime,
                              isPlaying: pendingLoad == nil && (compatibility?.isListening ?? (player.timeControlStatus == .playing)))
    }

    private func updatePositionFromEngine() {
        guard pendingQuit == nil, !isShutDown else { return }
        guard !hasFinished, pendingLoad == nil, let timeline, let currentTrack else { return }
        let local = compatibility?.localTime ?? (player.currentTime().seconds + nativeTimeOffset)
        guard local.isFinite, let absolute = timeline.absoluteTime(trackIndex: currentTrack.index, localTime: local) else { return }
        if abs(absolute - position) > 0.01 { lastUpdatedAt = Date().timeIntervalSince1970 * 1_000 }
        position = absolute
    }

    private func startTicker() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func tick() async {
        guard pendingQuit == nil, !isShutDown else { return }
        guard currentMedia != nil, let timeline, let currentTrack else { return }
        let operation = generation
        if let item = player.currentItem, let proxy = hlsProxies[ObjectIdentifier(item)] {
            let failed = await proxy.hasFailed
            guard operation == generation, player.currentItem === item,
                  hlsProxies[ObjectIdentifier(item)] === proxy else { return }
            if failed {
                // An exhausted segment retry must stop the clock as well as audio.
                // AVPlayer can otherwise skip forward through failed VOD segments.
                errorDiagnostic = .capture(PlaybackFailure.streamNotReady)
                pause()
                return
            }
        }
        guard operation == generation else { return }
        compatibility?.tick(); accountListeningTime()
        // A healthy recovery replenishes the retry allowance. Otherwise a
        // second JWT expiry in the same long audio file could never renew.
        if compatibility == nil, retriedTrack == currentTrack.index,
           player.timeControlStatus == .playing, listeningClock.total - retryListeningBaseline >= 2 {
            retriedTrack = nil
        }
        updatePositionFromEngine()
        refreshPlayerState()
        if let deadline = sleepDeadline, Date() >= deadline { pause(); cancelSleepTimer() }
        if let end = chapterSleepPosition, position >= end {
            pause(); cancelSleepTimer(); await seek(to: end)
            guard operation == generation else { return }
        }
        if compatibility?.hasFailed == true {
            errorDiagnostic = .init(code: "playback.localEngineFailed", fallbackMessage: "本地兼容引擎无法播放此文件。"); pause()
        } else if compatibility?.hasEnded == true {
            if let i = timeline.tracks.firstIndex(where: { $0.index == currentTrack.index }), timeline.tracks.indices.contains(i + 1) {
                do { try await load(at: timeline.tracks[i + 1].startOffset, autoplay: isPlaybackRequested, operation: operation) }
                catch {
                    guard operation == generation else { return }
                    self.errorDiagnostic = .capture(error); pause()
                }
            } else { await finishMedia() }
        }
        guard operation == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReportTime >= 5 { lastReportTime = now; await report() }
    }

    private func finishMedia() async {
        guard !hasFinished else { return }
        let operation = generation
        hasFinished = true
        accountListeningTime(); position = duration; lastUpdatedAt = Date().timeIntervalSince1970 * 1_000
        isPlaybackRequested = false; isPlaying = false; isBuffering = false
        player.pause(); compatibility?.pause(); updateNowPlaying()
        await report()
        guard operation == generation else { return }
        if !queue.isEmpty { await playNext() }
    }

    private func snapshot() -> LocalPlaybackSession? {
        guard let currentMedia, let localSessionID else { return nil }
        return LocalPlaybackSession(id: localSessionID, libraryItemId: currentMedia.itemID, episodeId: currentMedia.episodeID,
                                    mediaType: currentMedia.episodeID == nil ? "book" : "podcast",
                                    mediaMetadata: ItemMetadata(title: currentMedia.title, authorName: currentMedia.author),
                                    chapters: chapters.map { Chapter(id: $0.id, title: $0.title, start: $0.start, end: $0.end) },
                                    displayTitle: currentMedia.title, displayAuthor: currentMedia.author,
                                    duration: duration, currentTime: position, startedAt: startedAt, updatedAt: lastUpdatedAt,
                                    timeListening: listeningClock.total)
    }

    private func report() async {
        guard !blocksPlaybackActions, let snapshot = snapshot(), let reporter else { return }
        let operation = generation
        let result = await reporter.submit(snapshot)
        if operation == generation { syncDiagnostic = result }
    }

    private func updateNowPlaying() {
        guard ownsSystemMediaControls else { return }
        guard let currentMedia else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: currentMedia.title, MPMediaItemPropertyArtist: currentMedia.author,
                                   MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
                                   MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
                                   MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
                                   MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(for media: PlaybackMedia, operation: UUID) {
        artworkTask?.cancel(); nowPlayingArtwork = nil
        guard ownsSystemMediaControls, let ownerToken = systemMediaControlToken, let url = media.coverURL else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled,
                  let self, self.generation == operation, self.ownsSystemMediaControls, self.systemMediaControlToken == ownerToken, let image = NSImage(data: data) else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
    }

    /// Ownership controls system integration only; callers retain responsibility
    /// for pausing and durably finalizing the old playback session.
    public func setSystemMediaControlsActive(_ active: Bool) {
        if active {
            guard !isShutDown, !ownsSystemMediaControls else { return }
            Self.systemMediaOwner?.setSystemMediaControlsActive(false)
            Self.systemMediaOwner = self
            systemMediaControlToken = UUID()
            installRemoteCommands()
            observeSleep()
            if let currentMedia { loadArtwork(for: currentMedia, operation: generation) }
            updateNowPlaying()
        } else {
            clearNowPlayingIfOwner()
            if Self.systemMediaOwner === self { Self.systemMediaOwner = nil }
            systemMediaControlToken = nil
            remoteTargets.forEach { $0.0.removeTarget($0.1) }; remoteTargets.removeAll()
            remoteTasks.values.forEach { $0.cancel() }; remoteTasks.removeAll()
            sleepTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; sleepTokens.removeAll()
            shouldResumeAfterWake = false
            artworkTask?.cancel(); artworkTask = nil; nowPlayingArtwork = nil
        }
    }
    private func clearNowPlayingIfOwner() {
        guard ownsSystemMediaControls else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
    // The token belongs to the installed target, not whichever controller later
    // owns the command center when its queued MainActor work gets to run.
    func enqueueSystemMediaCommand(_ command: PlaybackSystemMediaCommand, token: UUID) {
        guard ownsSystemMediaControls, systemMediaControlToken == token else { return }
        let id = UUID()
        remoteTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.remoteTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, self.ownsSystemMediaControls, self.systemMediaControlToken == token else { return }
            switch command {
            case .play: self.resume()
            case .pause: self.pause()
            case .toggle: self.togglePlayPause()
            case .next: await self.playNext()
            case .forward: await self.skip(by: self.jumpForwardAmount)
            case .backward: await self.skip(by: -self.jumpBackwardAmount)
            case .seek(let position): await self.seek(to: position)
            case .rate(let rate): self.requestRemoteRateChange(rate)
            case .sleep:
                self.shouldResumeAfterWake = self.isPlaybackRequested; self.pause()
            case .wake:
                guard self.shouldResumeAfterWake else { return }
                self.shouldResumeAfterWake = false; self.resume()
            }
        }
    }
    private func installRemoteCommands() {
        guard ownsSystemMediaControls, let token = systemMediaControlToken else { return }
        let center = MPRemoteCommandCenter.shared()
        func command(_ remote: MPRemoteCommand, _ action: PlaybackSystemMediaCommand) {
            let target = remote.addTarget { [weak self] _ in
                Task { @MainActor in self?.enqueueSystemMediaCommand(action, token: token) }
                return .success
            }
            remoteTargets.append((remote, target))
        }
        command(center.playCommand, .play); command(center.pauseCommand, .pause)
        command(center.togglePlayPauseCommand, .toggle); command(center.nextTrackCommand, .next)
        command(center.skipForwardCommand, .forward); command(center.skipBackwardCommand, .backward)
        configureRemoteCommands(jumpForward: jumpForwardAmount, jumpBackward: jumpBackwardAmount, rateStep: remoteRateStep)
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.enqueueSystemMediaCommand(.seek(position), token: token) }; return .success
        }
        remoteTargets.append((center.changePlaybackPositionCommand, positionTarget))
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let rate = event.playbackRate
            Task { @MainActor in self?.enqueueSystemMediaCommand(.rate(rate), token: token) }; return .success
        }
        remoteTargets.append((center.changePlaybackRateCommand, rateTarget))
    }
    private func observeSleep() {
        guard ownsSystemMediaControls, let token = systemMediaControlToken else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enqueueSystemMediaCommand(.sleep, token: token) }
        })
        sleepTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.enqueueSystemMediaCommand(.wake, token: token) }
        })
    }
}

enum PlaybackSystemMediaCommand: Sendable {
    case play, pause, toggle, next, forward, backward, seek(Double), rate(Float), sleep, wake
}
