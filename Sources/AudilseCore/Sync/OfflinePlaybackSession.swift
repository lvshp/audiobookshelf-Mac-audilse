import Foundation

/// Evidence from a successful sync/close by this exact local playback session.
/// ABS returns no progress timestamp in that response; do not invent one from the client clock.
public struct PlaybackSyncAcknowledgement: Codable, Hashable, Sendable {
    public let sessionID: String
    public let itemID: String
    public let episodeID: String?
    public let startedAt: Double
    public let currentTime: Double
    public let duration: Double

    public init(session: LocalPlaybackSession) {
        sessionID = session.id; itemID = session.libraryItemId; episodeID = session.episodeId
        startedAt = session.startedAt; currentTime = session.currentTime; duration = session.duration
    }

    func matches(_ session: OfflinePlaybackSession) -> Bool {
        sessionID == session.id && itemID == session.itemID && episodeID == session.episodeID && startedAt == session.startedAt
            && currentTime.isFinite && currentTime >= 0 && duration.isFinite && duration > 0 && currentTime <= duration + 1
    }
}

/// Immutable session identity plus the latest cumulative snapshot. Times are ABS milliseconds.
public struct OfflinePlaybackSession: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let itemID: String
    public let episodeID: String?
    public let startedAt: Double
    public var updatedAt: Double
    public var currentTime: Double
    public var timeListening: Double
    public let duration: Double
    public let serverProgressUpdatedAt: Double?
    public let serverCurrentTime: Double?
    public let serverFinished: Bool?
    public let ownAcknowledgement: PlaybackSyncAcknowledgement?
    /// JSON returned by /play, retained for the original local-session wire representation.
    public let sessionPayload: Data?

    public init(id: String, itemID: String, episodeID: String? = nil, startedAt: Double, updatedAt: Double, currentTime: Double, timeListening: Double, duration: Double, serverProgressUpdatedAt: Double? = nil, serverCurrentTime: Double? = nil, serverFinished: Bool? = nil, sessionPayload: Data? = nil, ownAcknowledgement: PlaybackSyncAcknowledgement? = nil) {
        self.id = id
        self.itemID = itemID
        self.episodeID = episodeID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.currentTime = currentTime
        self.timeListening = timeListening
        self.duration = duration
        self.serverProgressUpdatedAt = serverProgressUpdatedAt
        self.serverCurrentTime = serverCurrentTime
        self.serverFinished = serverFinished
        self.sessionPayload = sessionPayload
        self.ownAcknowledgement = ownAcknowledgement
    }

    public var mediaKey: String { Self.mediaKey(itemID: itemID, episodeID: episodeID) }

    public static func mediaKey(itemID: String, episodeID: String?) -> String {
        // Length-prefixing prevents collisions between arbitrary opaque IDs.
        "\(itemID.utf8.count):\(itemID)\(episodeID.map { "\($0.utf8.count):\($0)" } ?? "-")"
    }

    public func validate() throws {
        guard !id.isEmpty, !itemID.isEmpty,
              startedAt.isFinite, updatedAt.isFinite, currentTime.isFinite,
              timeListening.isFinite, duration.isFinite,
              startedAt >= 0, updatedAt >= startedAt, currentTime >= 0,
              timeListening >= 0, duration > 0, currentTime <= duration + 1 else {
            throw OfflineStorageError.invalidSession
        }
        if let ownAcknowledgement, !ownAcknowledgement.matches(self) { throw OfflineStorageError.invalidSession }
    }
}

public struct SyncProgressSnapshot: Codable, Hashable, Sendable {
    public let itemID: String
    public let episodeID: String?
    public var currentTime: Double
    public var duration: Double
    public var isFinished: Bool
    public var updatedAt: Double
    public var ebookLocation: String?
    public var ebookProgress: Double?
    /// The server's persisted audio percentage, distinct from currentTime / duration.
    /// Nil keeps older cached conflicts and third-party sync adapters compatible.
    public var audioProgress: Double?

    public init(itemID: String, episodeID: String? = nil, currentTime: Double, duration: Double, isFinished: Bool, updatedAt: Double, ebookLocation: String? = nil, ebookProgress: Double? = nil, audioProgress: Double? = nil) {
        self.itemID = itemID
        self.episodeID = episodeID
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.updatedAt = updatedAt
        self.ebookLocation = ebookLocation
        self.ebookProgress = ebookProgress
        self.audioProgress = audioProgress
    }

    public var mediaKey: String { OfflinePlaybackSession.mediaKey(itemID: itemID, episodeID: episodeID) }
}

public struct SyncConflict: Codable, Hashable, Sendable, Identifiable {
    public let local: OfflinePlaybackSession
    public let remote: SyncProgressSnapshot
    public let detectedAt: Date
    public var id: String { mediaKey }
    public var mediaKey: String { local.mediaKey }

    public init(local: OfflinePlaybackSession, remote: SyncProgressSnapshot, detectedAt: Date = Date()) {
        self.local = local
        self.remote = remote
        self.detectedAt = detectedAt
    }
}

public enum SyncPositionChoice: Sendable { case local, remote }

public enum OfflineSyncPolicy {
    /// Only audio fields constitute an audio conflict. Ebook-only edits must not overwrite audio.
    public static func conflicts(local: OfflinePlaybackSession, remote: SyncProgressSnapshot?) -> Bool {
        guard let remote else { return false }
        if let acknowledged = local.ownAcknowledgement, acknowledged.matches(local) {
            // A matching position is the only state established by our successful request.
            // Preserve a different finished flag (including ABS near-end auto-finish) as a
            // conflict: the response did not establish the server's completion decision.
            let matchesAcknowledged = abs(remote.currentTime - acknowledged.currentTime) <= 1
                && remote.isFinished == (acknowledged.currentTime >= acknowledged.duration)
            let sameResult = abs(remote.currentTime - local.currentTime) <= 1
                && remote.isFinished == (local.currentTime >= local.duration)
            return !matchesAcknowledged && !sameResult
        }
        guard let baselineDate = local.serverProgressUpdatedAt else {
            // No captured baseline: an existing different position needs an explicit choice.
            return abs(remote.currentTime - local.currentTime) > 1 || remote.isFinished != (local.currentTime >= local.duration)
        }
        guard remote.updatedAt > baselineDate else { return false }
        let baselinePosition = local.serverCurrentTime ?? local.currentTime
        let audioChanged = abs(remote.currentTime - baselinePosition) > 1 || remote.isFinished != (local.serverFinished ?? false)
        let sameResult = abs(remote.currentTime - local.currentTime) <= 1 && remote.isFinished == (local.currentTime >= local.duration)
        return audioChanged && !sameResult
    }

    /// The coordinator supplies only rows read from one account partition. Keep the
    /// original acknowledged session as evidence; never relabel it as the new session.
    static func conflicts(local: OfflinePlaybackSession, remote: SyncProgressSnapshot?, pendingSessions: [OfflinePlaybackSession]) -> Bool {
        guard let remote else { return false }
        guard local.ownAcknowledgement == nil else { return conflicts(local: local, remote: remote) }
        let chain = ordered(pendingSessions.filter { $0.mediaKey == local.mediaKey })
        guard chain.first?.id == local.id,
              let sourceIndex = chain.firstIndex(where: { $0.ownAcknowledgement != nil }) else {
            return conflicts(local: local, remote: remote)
        }
        let source = chain[sourceIndex]
        guard let acknowledged = source.ownAcknowledgement, acknowledged.matches(source) else { return true }
        // Pick the newest evidence once, independently of the remote position. An
        // older matching acknowledgement must never hide a later confirmed write.
        for index in 0..<sourceIndex {
            let newer = chain[index], older = chain[index + 1]
            guard older.updatedAt <= newer.startedAt,
                  newer.serverProgressUpdatedAt == source.serverProgressUpdatedAt,
                  newer.serverCurrentTime == source.serverCurrentTime,
                  newer.serverFinished == source.serverFinished else { return true }
        }
        let matchesAcknowledged = abs(remote.currentTime - acknowledged.currentTime) <= 1
            && remote.isFinished == (acknowledged.currentTime >= acknowledged.duration)
        let sameResult = abs(remote.currentTime - local.currentTime) <= 1
            && remote.isFinished == (local.currentTime >= local.duration)
        return !matchesAcknowledged && !sameResult
    }

    public static func ordered(_ sessions: [OfflinePlaybackSession]) -> [OfflinePlaybackSession] {
        // /session/local changes progress, so each media's most recent session must go first.
        sessions.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
