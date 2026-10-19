import Foundation
import AudilseCore

/// Owns one immutable cumulative snapshot independently of the visible player.
/// The reporter retains its original account's persistence and sync callbacks.
@MainActor public final class PlaybackRecoveryHandle {
    public let id = UUID()
    public let sessionID: String
    private let snapshot: LocalPlaybackSession
    private let reporter: PlaybackSessionReporter
    private var localOnly = false
    private var completed: PlaybackQuitReceipt?
    private struct Attempt {
        let id = UUID()
        let localOnly: Bool
        let task: Task<PlaybackQuitReceipt, Never>
    }
    private var attempt: Attempt?

    init(snapshot: LocalPlaybackSession, reporter: PlaybackSessionReporter) {
        self.snapshot = snapshot; self.reporter = reporter; sessionID = snapshot.id
    }

    /// Irreversible: retirement never restores network authority on retry.
    public func retireToLocalRecovery() async {
        localOnly = true
        await reporter.retireToLocalRecovery()
    }

    public func finalize() async -> PlaybackQuitReceipt {
        if let completed, !localOnly || completed.cumulativeSnapshotSaved { return completed }
        let current: Attempt
        if let attempt { current = attempt }
        else {
            let local = localOnly, reporter = reporter, snapshot = snapshot
            current = Attempt(localOnly: local, task: Task {
                if local { await reporter.retireToLocalRecovery() }
                return await reporter.finalizeForQuit(snapshot)
            })
            attempt = current
        }
        let receipt = await current.task.value
        if attempt?.id == current.id { attempt = nil }
        // A normal close may have completed just before retirement. It cannot
        // replace the local archive checkpoint required by the retired source.
        if localOnly, !current.localOnly, !receipt.cumulativeSnapshotSaved { return await finalize() }
        if receipt.mayQuit { completed = receipt }
        return receipt
    }
}
