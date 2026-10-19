import Foundation

/// The adapter must PATCH audio fields only; never send stale ebook fields from the local cache.
public protocol OfflineSyncRemote: Sendable {
    func progress(itemID: String, episodeID: String?) async throws -> SyncProgressSnapshot?
    func upload(_ session: OfflinePlaybackSession) async throws
    func setAudioPosition(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool) async throws
}

public struct SyncReport: Sendable {
    public var uploaded = 0
    public var conflicts: [SyncConflict] = []
    public init() {}
}

public enum OfflineSyncError: Error, LocalizedError, Sendable {
    case verificationFailed
    case progressChangedDuringResolution
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .verificationFailed: "同步后播放位置校验失败，记录已保留。"
        case .progressChangedDuringResolution: "其他设备再次更新了进度，请重新选择播放位置。"
        case .alreadyRunning: "同步正在进行。"
        }
    }
}

public actor SyncCoordinator {
    private let database: ShelfDatabase
    private var running = false
    private var sessionMutations: [UUID: AccountPartition] = [:]

    public init(database: ShelfDatabase) { self.database = database }

    /// A history upload must not recreate a record being deleted by management.
    /// Wait for a running sync to finish before the caller retries this action.
    public func reserveSessionMutation(id: UUID, partition: AccountPartition) throws {
        guard !running, sessionMutations[id] == nil, !sessionMutations.values.contains(partition) else { throw OfflineSyncError.alreadyRunning }
        sessionMutations[id] = partition
    }

    public func finishSessionMutation(id: UUID) {
        sessionMutations[id] = nil
    }

    public func synchronize(partition: AccountPartition, remote: any OfflineSyncRemote, excludingSessionIDs: Set<String> = []) async throws -> SyncReport {
        guard !running, !sessionMutations.values.contains(partition) else { throw OfflineSyncError.alreadyRunning }
        running = true
        defer { running = false }
        var report = SyncReport()
        let sessions = OfflineSyncPolicy.ordered(try await database.pendingSessions(partition: partition))
            .filter { !excludingSessionIDs.contains($0.id) }
        let grouped = Dictionary(grouping: sessions, by: \.mediaKey)
        let existing = try await database.conflicts(partition: partition)
        var blocked = Set(existing.map(\.mediaKey))
        report.conflicts = existing
        for latest in sessions {
            guard !blocked.contains(latest.mediaKey) else { continue }
            blocked.insert(latest.mediaKey)
            let current = try await remote.progress(itemID: latest.itemID, episodeID: latest.episodeID)
            let group = grouped[latest.mediaKey] ?? []
            if OfflineSyncPolicy.conflicts(local: latest, remote: current, pendingSessions: group), let current {
                let conflict = SyncConflict(local: latest, remote: current)
                try await database.saveConflict(conflict, partition: partition)
                report.conflicts.append(conflict)
                continue
            }
            // Upload history first. A failed call keeps this and all remaining snapshots queued.
            for session in group {
                try await remote.upload(session)
            }
            // Older histories can move ABS progress backward. Restore the most recent snapshot.
            try await remote.setAudioPosition(itemID: latest.itemID, episodeID: latest.episodeID, currentTime: latest.currentTime, duration: latest.duration, isFinished: latest.currentTime >= latest.duration)
            try await verify(latest.currentTime, duration: latest.duration, finished: latest.currentTime >= latest.duration, itemID: latest.itemID, episodeID: latest.episodeID, remote: remote)
            for session in group { try await database.acknowledge(session, partition: partition) }
            report.uploaded += group.count
        }
        return report
    }

    public func resolve(_ conflict: SyncConflict, choice: SyncPositionChoice, partition: AccountPartition, remote: any OfflineSyncRemote) async throws {
        guard !running, !sessionMutations.values.contains(partition) else { throw OfflineSyncError.alreadyRunning }
        running = true
        defer { running = false }
        let current = try await remote.progress(itemID: conflict.local.itemID, episodeID: conflict.local.episodeID)
        if let current, current.updatedAt > conflict.remote.updatedAt,
           abs(current.currentTime - conflict.remote.currentTime) > 1 || current.isFinished != conflict.remote.isFinished {
            let refreshed = SyncConflict(local: conflict.local, remote: current)
            try await database.saveConflict(refreshed, partition: partition)
            throw OfflineSyncError.progressChangedDuringResolution
        }
        let queued = OfflineSyncPolicy.ordered(try await database.pendingSessions(partition: partition))
            .filter { $0.mediaKey == conflict.mediaKey }
        let latestLocal = queued.first ?? conflict.local
        let position = choice == .local ? latestLocal.currentTime : conflict.remote.currentTime
        let duration = choice == .local ? latestLocal.duration : conflict.remote.duration
        let finished = choice == .local ? latestLocal.currentTime >= latestLocal.duration : conflict.remote.isFinished
        for session in queued { try await remote.upload(session) }
        try await remote.setAudioPosition(itemID: conflict.local.itemID, episodeID: conflict.local.episodeID, currentTime: position, duration: duration, isFinished: finished)
        try await verify(position, duration: duration, finished: finished, itemID: conflict.local.itemID, episodeID: conflict.local.episodeID, remote: remote)
        for session in queued { try await database.acknowledge(session, partition: partition) }
        try await database.removeConflict(mediaKey: conflict.mediaKey, partition: partition)
    }

    private func verify(_ position: Double, duration: Double, finished: Bool, itemID: String, episodeID: String?, remote: any OfflineSyncRemote) async throws {
        guard let saved = try await remote.progress(itemID: itemID, episodeID: episodeID),
              abs(saved.currentTime - position) <= 1, saved.isFinished == finished else {
            throw OfflineSyncError.verificationFailed
        }
        if let reported = saved.audioProgress {
            let expected = finished ? 1 : (duration > 0 ? min(1, max(0, position / duration)) : 0)
            guard reported.isFinite, abs(reported - expected) <= 0.000001 else {
                // Do not "repair" pre-existing upstream percentages by moving playback or
                // writing private extraData fields. Keep the queue for an explicit retry.
                throw ClientDiagnostic(code: "sync.percentageDiverged", arguments: [String(expected), String(reported)], fallbackMessage: "服务器返回的收听百分比与播放位置不一致，记录已保留。")
            }
        }
    }
}
