import Foundation
import ShelfCore
import ShelfPlayback

/// An anonymous share never uses ABSPlaybackService or the account journal.
struct PublicSharePlaybackService: PlaybackService {
    let client: PublicShareClient
    let snapshot: PublicShareSnapshot
    let media: PlaybackMedia
    let tracks: [PlaybackTrack]
    private let sessionID: String

    init(client: PublicShareClient, snapshot: PublicShareSnapshot) {
        self.client = client
        self.snapshot = snapshot
        let resourceIdentity = UUID().uuidString.lowercased()
        self.sessionID = resourceIdentity
        self.media = PlaybackMedia(
            itemID: "public-share:" + snapshot.shareID,
            title: snapshot.title, author: snapshot.author, duration: snapshot.duration,
            chapters: snapshot.chapters.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
        )
        self.tracks = snapshot.tracks.map {
            // This address cannot fall back to an HTTP asset. Resource reads go
            // exclusively through the anonymous client's bounded transport.
            PlaybackTrack(index: $0.index, title: $0.title,
                          url: URL(string: "shelf-public-share://\(resourceIdentity)/track/\($0.index)")!,
                          duration: $0.duration, startOffset: $0.startOffset,
                          mimeType: $0.contentType, isLocal: false)
        }
    }

    func prepare(media: PlaybackMedia) async throws -> PreparedPlayback {
        guard media == self.media else { throw PublicShareError.sessionChanged }
        return PreparedPlayback(media: self.media, tracks: tracks, sessionID: sessionID,
                                initialPosition: snapshot.currentTime)
    }

    func authorize(track: PlaybackTrack) async throws -> PlaybackTrack {
        guard tracks.contains(track) else { throw PublicShareError.untrustedResource }
        return track
    }

    func resourceSource(for track: PlaybackTrack) async throws -> (any PlaybackResourceSource)? {
        guard tracks.contains(track) else { throw PublicShareError.untrustedResource }
        return ShareTrackResource(client: client, handle: snapshot.handle,
                                  index: track.index, contentType: track.mimeType)
    }

    func sync(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        guard sessionID == self.sessionID else { throw PublicShareError.sessionChanged }
        // The public protocol only accepts currentTime, never account listening statistics.
        _ = try await client.syncProgress(currentTime: currentTime, handle: snapshot.handle)
    }

    func close(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        guard sessionID == self.sessionID else { throw PublicShareError.sessionChanged }
        // There is no public close endpoint. Keep this handle valid while the
        // controller settles its local receipt or retries failed finalization.
        // The coordinator retires the client only after a safe handoff.
        _ = try await client.syncProgress(currentTime: currentTime, handle: snapshot.handle)
    }

    func persist(_ session: LocalPlaybackSession) async throws {
        guard session.libraryItemId == media.itemID else { throw PublicShareError.sessionChanged }
        _ = try await client.checkpoint(currentTime: session.currentTime, handle: snapshot.handle)
    }
}

private struct ShareTrackResource: PlaybackResourceSource {
    let client: PublicShareClient
    let handle: PublicShareHandle
    let index: Int
    let contentType: String?

    func read(offset: Int64, length: Int) async throws -> PlaybackResourceChunk {
        let result = try await client.readTrackRange(index: index, offset: offset, length: length, handle: handle)
        return PlaybackResourceChunk(offset: result.range.lowerBound, data: result.data,
                                     totalLength: result.totalLength,
                                     contentType: result.contentType ?? contentType ?? "application/octet-stream")
    }
}
