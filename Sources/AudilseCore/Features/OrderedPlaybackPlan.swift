import Foundation

/// Matches ABS Web's collection/playlist playback order. Filter unavailable
/// media before deciding whether the list has any unfinished content.
public struct OrderedPlaybackPlan: Hashable, Sendable {
    public let entries: [PlaylistEntry]

    public init(entries: [PlaylistEntry], progressByItem: [String: MediaProgress]) {
        let playable = entries.compactMap(Self.playableEntry)
        let unfinished = playable.filter { progressByItem[$0.id]?.isFinished != true }
        self.entries = unfinished.isEmpty ? playable : unfinished
    }

    private static func playableEntry(_ entry: PlaylistEntry) -> PlaylistEntry? {
        guard let item = entry.libraryItem, item.id == entry.libraryItemId,
              !item.isMissing, !item.isInvalid else { return nil }
        var resolved = entry
        switch item.mediaType {
        case "book":
            // Author/series and filtered library responses may be minified even
            // with minified=0; ABS includes numTracks instead of the tracklist.
            guard entry.episodeId == nil,
                  !item.media.tracks.isEmpty || (item.media.numTracks ?? 0) > 0 else { return nil }
            resolved.episode = nil
        case "podcast":
            guard let episodeID = entry.episodeId,
                  let episode = entry.episode ?? item.media.episodes.first(where: { $0.id == episodeID }),
                  episode.id == episodeID, let file = episode.audioFile,
                  !file.exclude, !file.isInvalid else { return nil }
            resolved.episode = episode
        default:
            return nil
        }
        return resolved
    }
}
