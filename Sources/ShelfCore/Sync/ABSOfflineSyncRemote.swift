import Foundation

public struct ABSOfflineSyncRemote: OfflineSyncRemote {
    private let client: ABSClient
    public init(client: ABSClient) { self.client = client }

    public func progress(itemID: String, episodeID: String?) async throws -> SyncProgressSnapshot? {
        guard let progress = try await client.progress(itemID: itemID, episodeID: episodeID) else { return nil }
        return SyncProgressSnapshot(itemID: progress.libraryItemId, episodeID: progress.episodeId, currentTime: progress.currentTime, duration: progress.duration, isFinished: progress.isFinished, updatedAt: progress.lastUpdate ?? 0, ebookLocation: progress.ebookLocation, ebookProgress: progress.ebookProgress, audioProgress: progress.progress)
    }

    public func upload(_ snapshot: OfflinePlaybackSession) async throws {
        guard let data = snapshot.sessionPayload else { throw OfflineStorageError.invalidSession }
        var session = try JSONDecoder().decode(LocalPlaybackSession.self, from: data)
        guard session.id == snapshot.id, session.libraryItemId == snapshot.itemID,
              session.episodeId == snapshot.episodeID, session.startedAt == snapshot.startedAt else { throw OfflineStorageError.sessionIdentityChanged }
        session.updatedAt = snapshot.updatedAt
        session.currentTime = snapshot.currentTime
        session.timeListening = snapshot.timeListening
        // Online recovery journals share the original ID. Retire any open in-memory session
        // before replacing its database history, so a later close cannot restore stale totals.
        do { try await client.closePlayback(sessionID: snapshot.id, currentTime: snapshot.currentTime, timeListening: 0) }
        catch ABSError.http(status: 404, message: _) { /* Pure offline sessions are not open. */ }
        try await client.syncLocalSession(session)
    }

    public func setAudioPosition(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        try await client.setAudioPosition(itemID: itemID, episodeID: episodeID, currentTime: currentTime, duration: duration, isFinished: isFinished)
    }
}
