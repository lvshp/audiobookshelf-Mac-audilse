import Foundation
import AudilseCore

public typealias PlaybackPersistenceFactory = @MainActor @Sendable (PlaybackMedia) -> PlaybackRecoveryPersistence
public typealias PlaybackRecoveryPersistence = @Sendable (LocalPlaybackSession, PlaybackSyncAcknowledgement?) async throws -> Void
public typealias PlaybackPersistence = @Sendable (LocalPlaybackSession) async throws -> Void
public typealias PlaybackCheckpoint = @Sendable (MediaProgress) async throws -> Void
public typealias PlaybackAcknowledgement = @Sendable (String) async throws -> Void

/// Diagnostics and durability are independent: an offline journal can be safe
/// even when the server or the separate resume checkpoint could not be updated.
public struct PlaybackQuitReceipt: Sendable {
    public let sessionID: String?
    public let remoteCumulativeConfirmed: Bool
    public let cumulativeSnapshotSaved: Bool
    public let checkpointSaved: Bool
    public let diagnostic: ClientDiagnostic?
    public var transitionInProgress = false
    public var mayQuit: Bool { !transitionInProgress && (sessionID == nil || remoteCumulativeConfirmed || cumulativeSnapshotSaved) }

    static let noActiveSession = PlaybackQuitReceipt(sessionID: nil, remoteCumulativeConfirmed: false,
        cumulativeSnapshotSaved: false, checkpointSaved: false, diagnostic: nil)
}

/// Serializes checkpoints, delta syncs and close even when UI actions arrive
/// while a periodic request is suspended. Failed delta syncs keep the original
/// cumulative snapshot for local recovery using the same ABS session ID.
actor PlaybackSessionReporter {
    private let service: (any PlaybackService)?
    private let remoteSessionID: String?
    private let persist: PlaybackPersistence?
    private let recoveryPersist: PlaybackRecoveryPersistence?
    private var ownAcknowledgement: PlaybackSyncAcknowledgement?
    private let checkpoint: PlaybackCheckpoint?
    private let acknowledge: PlaybackAcknowledgement?
    private var acknowledgedListening = 0.0
    private var requiresCumulativeRecovery = false
    private var localRecoveryOnly = false
    private var remotelyClosed = false
    private var detachedAfterFlush = false
    private struct ReportOutcome: Sendable {
        var remoteCumulativeConfirmed = false
        var cumulativeSnapshotSaved = false
        var checkpointSaved = false
        var diagnostic: ClientDiagnostic?
    }
    private var confirmedClosingSnapshot: LocalPlaybackSession?
    private var recoveryCloseConfirmed = false
    private var tail: Task<ReportOutcome, Never>?

    init(service: (any PlaybackService)?, remoteSessionID: String?, persist: PlaybackPersistence?, checkpoint: PlaybackCheckpoint?, acknowledge: PlaybackAcknowledgement?, recoveryPersist: PlaybackRecoveryPersistence? = nil) {
        self.service = service; self.remoteSessionID = remoteSessionID; self.persist = persist
        self.checkpoint = checkpoint; self.acknowledge = acknowledge; self.recoveryPersist = recoveryPersist
    }

    func submit(_ snapshot: LocalPlaybackSession, closing: Bool = false) async -> ClientDiagnostic? {
        let previous = tail
        let next = Task { [self] in
            _ = await previous?.value
            return await perform(snapshot, closing: closing)
        }
        tail = next
        return await next.value.diagnostic
    }

    func finalizeForQuit(_ snapshot: LocalPlaybackSession) async -> PlaybackQuitReceipt {
        let previous = tail
        let next = Task { [self] in
            _ = await previous?.value
            return await perform(snapshot, closing: true)
        }
        tail = next
        let result = await next.value
        let safe = result.remoteCumulativeConfirmed || result.cumulativeSnapshotSaved
        return PlaybackQuitReceipt(sessionID: snapshot.id, remoteCumulativeConfirmed: result.remoteCumulativeConfirmed,
            cumulativeSnapshotSaved: result.cumulativeSnapshotSaved, checkpointSaved: result.checkpointSaved,
            diagnostic: result.diagnostic ?? (safe ? nil : .init(code: "playback.finalSnapshotNotDurable",
                fallbackMessage: "完整播放记录尚未安全保存，请重试退出。")))
    }

    /// Management sends its own single close/delete after the final normal sync.
    /// An uncertain delta or failed checkpoint prevents that management write.
    func flushForServerMutation(_ snapshot: LocalPlaybackSession) async -> ClientDiagnostic? {
        let previous = tail
        let next = Task<ReportOutcome, Never> { [self] in
            _ = await previous?.value
            let result = await perform(snapshot, closing: false)
            if remotelyClosed || localRecoveryOnly { return ReportOutcome(diagnostic: ClientDiagnostic.capture(ABSError.sessionChanged)) }
            if result.diagnostic == nil { detachedAfterFlush = true }
            return result
        }
        tail = next
        return await next.value.diagnostic
    }

    /// Suppress a second delta/close, including a suspended earlier report.
    func preserveAfterRemoteClosure(_ snapshot: LocalPlaybackSession) async -> ClientDiagnostic? {
        markRemoteSessionClosed()
        return await submit(snapshot, closing: true)
    }

    func markRemoteSessionClosed() { remotelyClosed = true }

    func retireToLocalRecovery() { localRecoveryOnly = true }

    private func perform(_ snapshot: LocalPlaybackSession, closing: Bool) async -> ReportOutcome {
        guard !detachedAfterFlush || localRecoveryOnly else { return ReportOutcome() }
        let progress = MediaProgress(libraryItemId: snapshot.libraryItemId, episodeId: snapshot.episodeId,
                                     currentTime: snapshot.currentTime, duration: snapshot.duration,
                                     progress: snapshot.duration > 0 ? snapshot.currentTime / snapshot.duration : 0,
                                     isFinished: snapshot.currentTime >= snapshot.duration && snapshot.duration > 0,
                                     lastUpdate: snapshot.updatedAt)
        var result = ReportOutcome()
        do {
            if let checkpoint { try await checkpoint(progress); result.checkpointSaved = true }
        } catch { result.diagnostic = .capture(error) }
        if localRecoveryOnly { return await persist(snapshot, result: result) }
        if confirmedClosingSnapshot == snapshot {
            // A successful close already committed this cumulative snapshot.
            // Retrying a failed local acknowledgement must never repeat its delta.
            result.remoteCumulativeConfirmed = true
            do { if let remoteSessionID { try await acknowledge?(remoteSessionID) } }
            catch { result.diagnostic = .capture(error); return await persist(snapshot, result: result) }
            return result
        }
        guard !remotelyClosed, let service, let remoteSessionID else {
            return await persist(snapshot, result: result)
        }
        if requiresCumulativeRecovery {
            // /sync adds a delta and has no idempotency key. After an ambiguous
            // failure, never resend that delta. /session/local will replace the
            // same ID with the cumulative value, after the open session closes.
            if closing, !recoveryCloseConfirmed {
                do {
                    try await service.close(sessionID: remoteSessionID, currentTime: snapshot.currentTime, timeListened: 0)
                    recoveryCloseConfirmed = true
                } catch { result.diagnostic = .capture(error) }
            }
            // close(0) confirms closure, not the preceding uncertain cumulative
            // listening. Only the journal can make this recovery branch durable.
            result = await persist(snapshot, result: result)
            if result.diagnostic == nil, result.cumulativeSnapshotSaved {
                result.diagnostic = .init(code: "playback.savedForRecovery", fallbackMessage: "播放记录已保存在本地，停止播放后将重新同步。")
            }
            return result
        }
        do {
            let delta = max(0, snapshot.timeListening - acknowledgedListening)
            if closing {
                try await service.close(sessionID: remoteSessionID, currentTime: snapshot.currentTime, timeListened: delta)
            } else {
                try await service.sync(sessionID: remoteSessionID, currentTime: snapshot.currentTime, timeListened: delta)
            }
            if remotelyClosed || localRecoveryOnly {
                // A late response cannot acknowledge the newer local snapshot
                // which the close event will preserve after this report.
                return await persist(snapshot, result: result)
            }
            ownAcknowledgement = PlaybackSyncAcknowledgement(session: snapshot)
            acknowledgedListening = snapshot.timeListening
            if closing { confirmedClosingSnapshot = snapshot; result.remoteCumulativeConfirmed = true }
            try await acknowledge?(remoteSessionID)
            return result
        } catch {
            if !result.remoteCumulativeConfirmed { requiresCumulativeRecovery = true }
            result.diagnostic = .capture(error)
            return await persist(snapshot, result: result)
        }
    }

    private func persist(_ snapshot: LocalPlaybackSession, result: ReportOutcome) async -> ReportOutcome {
        var result = result
        guard recoveryPersist != nil || persist != nil else { return result }
        do {
            if let recoveryPersist { try await recoveryPersist(snapshot, ownAcknowledgement) }
            else { try await persist?(snapshot) }
            result.cumulativeSnapshotSaved = true
        }
        catch {
            let local = ClientDiagnostic.capture(error)
            if let previous = result.diagnostic {
                result.diagnostic = .init(code: "playback.localPersistenceFailed",
                    fallbackMessage: "\(previous.fallbackMessage)；本地保存失败：\(local.fallbackMessage)", causes: [previous, local])
            } else { result.diagnostic = local }
        }
        return result
    }
}
