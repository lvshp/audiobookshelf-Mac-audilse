import Foundation
import ShelfCore

public struct ABSPlaybackService: PlaybackService {
    public let client: ABSClient
    public init(client: ABSClient) { self.client = client }

    public func prepare(media: PlaybackMedia) async throws -> PreparedPlayback {
        let session = try await client.startPlayback(itemID: media.itemID, episodeID: media.episodeID)
        var expanded = media
        expanded.coverURL = try? await client.authorizedURL(path: "api/items/\(ServerEndpoint.component(media.itemID))/cover?width=440&format=jpeg")
        expanded.duration = session.duration
        expanded.chapters = session.chapters.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
        var tracks: [PlaybackTrack] = []
        for track in session.audioTracks {
            let url = try await client.resourceURL(path: track.contentUrl)
            tracks.append(PlaybackTrack(index: track.index, title: track.title ?? "", url: url,
                                        duration: track.duration, startOffset: track.startOffset, mimeType: track.mimeType))
        }
        return PreparedPlayback(media: expanded, tracks: tracks, sessionID: session.id, initialPosition: session.currentTime,
                                startedAt: session.startedAt ?? Date().timeIntervalSince1970 * 1_000)
    }

    public func authorize(track: PlaybackTrack) async throws -> PlaybackTrack {
        guard !track.isLocal else { return track }
        var authorized = track
        // Session HLS manifests and their segments are deliberately public to a
        // session-specific unpredictable URL. Direct files use ABS's supported
        // short-lived query token instead of private AVURLAsset header options.
        if track.url.pathExtension.lowercased() != "m3u8" {
            authorized.url = try await client.authorizedURL(path: track.url.absoluteString)
        }
        return authorized
    }

    // HLS readiness is handled by the load-owned HLSStreamProxy. A separate
    // preflight GET would compete with playback requests on ABS's transcoder.

    public func sync(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        try await client.syncPlayback(sessionID: sessionID, currentTime: currentTime, timeListening: timeListened)
    }

    public func close(sessionID: String, currentTime: Double, timeListened: Double) async throws {
        try await client.closePlayback(sessionID: sessionID, currentTime: currentTime, timeListening: timeListened)
    }
}

extension PlaybackMedia {
    public init(item: LibraryItem, episode: PodcastEpisode? = nil, coverURL: URL? = nil) {
        self.init(itemID: item.id, episodeID: episode?.id, title: episode?.title ?? item.title,
                  author: item.authorName, duration: episode?.duration ?? item.media.duration,
                  chapters: item.media.chapters.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end) },
                  coverURL: coverURL)
    }
}
