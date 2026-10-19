import Foundation
import Testing
@testable import AudilseCore

private func orderedBook(_ id: String, playable: Bool = true) -> LibraryItem {
    .init(id: id, libraryId: "books", media: .init(
        metadata: .init(title: id),
        tracks: playable ? [.init(index: 0, duration: 60, contentUrl: "/audio/" + id)] : []))
}
private func orderedEpisode(_ id: String, playable: Bool = true) -> PodcastEpisode {
    .init(id: id, title: id, audioFile: playable ? .init(ino: id, duration: 60) : nil, duration: 60)
}
private func orderedEntry(_ item: LibraryItem, episode: PodcastEpisode? = nil) -> PlaylistEntry {
    .init(libraryItemId: item.id, episodeId: episode?.id, libraryItem: item, episode: episode)
}

struct OrderedPlaybackPlanTests {
    @Test func preservesMixedBookAndEpisodeOrderAndUsesEpisodeProgress() {
        let book = orderedBook("book")
        let podcast = LibraryItem(id: "podcast", libraryId: "podcasts", mediaType: "podcast")
        let first = orderedEpisode("first"), second = orderedEpisode("second"), third = orderedEpisode("third")
        let entries = [orderedEntry(podcast, episode: first), orderedEntry(book), orderedEntry(podcast, episode: second), orderedEntry(podcast, episode: third)]
        let progress: [String: MediaProgress] = [
            "podcast:first": .init(libraryItemId: "podcast", episodeId: "first", isFinished: true),
            "book": .init(libraryItemId: "book", isFinished: true),
            "podcast:second": .init(libraryItemId: "podcast", episodeId: "second", currentTime: 15)
        ]
        let plan = OrderedPlaybackPlan(entries: entries, progressByItem: progress)
        #expect(plan.entries.map(\.id) == ["podcast:second", "podcast:third"])
        #expect(plan.entries.map(\.episodeId) == ["second", "third"])
        #expect(plan.entries.map { $0.episode?.title } == ["second", "third"])
    }

    @Test func excludesEbookOnlyMissingInvalidAndUnknownMedia() {
        var missing = orderedBook("missing"); missing.isMissing = true
        var invalid = orderedBook("invalid"); invalid.isInvalid = true
        let ebook = orderedBook("ebook-only", playable: false)
        var unknown = orderedBook("unknown"); unknown.mediaType = "unknown"
        let playable = orderedBook("playable")
        let entries = [ebook, missing, invalid, unknown, playable].map { orderedEntry($0) }
        #expect(OrderedPlaybackPlan(entries: entries, progressByItem: [:]).entries.map(\.id) == ["playable"])
        #expect(OrderedPlaybackPlan(entries: [orderedEntry(ebook)], progressByItem: [:]).entries.isEmpty)
    }

    @Test func allFinishedFallsBackToAllPlayableInOriginalOrder() {
        let first = orderedBook("first"), last = orderedBook("last")
        let podcast = LibraryItem(id: "podcast", libraryId: "podcasts", mediaType: "podcast")
        let episode = orderedEpisode("episode")
        let ebook = orderedBook("unfinished-ebook", playable: false)
        let entries = [orderedEntry(first), orderedEntry(ebook), orderedEntry(podcast, episode: episode), orderedEntry(last)]
        let progress: [String: MediaProgress] = [
            "first": .init(libraryItemId: "first", isFinished: true),
            "podcast:episode": .init(libraryItemId: "podcast", episodeId: "episode", isFinished: true),
            "last": .init(libraryItemId: "last", isFinished: true)
        ]
        #expect(OrderedPlaybackPlan(entries: entries, progressByItem: progress).entries.map(\.id) == ["first", "podcast:episode", "last"])
    }

    @Test func rejectsMissingMismatchedAndUnavailableEpisodes() {
        let podcast = LibraryItem(id: "podcast", libraryId: "podcasts", mediaType: "podcast")
        var excluded = orderedEpisode("excluded"); excluded.audioFile?.exclude = true
        var invalid = orderedEpisode("invalid"); invalid.audioFile?.isInvalid = true
        let entries = [
            orderedEntry(podcast),
            PlaylistEntry(libraryItemId: podcast.id, episodeId: "missing", libraryItem: podcast),
            PlaylistEntry(libraryItemId: podcast.id, episodeId: "wrong-id", libraryItem: podcast, episode: orderedEpisode("different")),
            orderedEntry(podcast, episode: orderedEpisode("not-downloaded", playable: false)),
            orderedEntry(podcast, episode: excluded),
            orderedEntry(podcast, episode: invalid)
        ]
        #expect(OrderedPlaybackPlan(entries: entries, progressByItem: [:]).entries.isEmpty)
    }

    @Test func resolvesCachedEpisodeWhilePreservingItsReference() {
        let episode = orderedEpisode("episode")
        let podcast = LibraryItem(id: "podcast", libraryId: "podcasts", mediaType: "podcast", media: .init(episodes: [episode]))
        let entry = PlaylistEntry(libraryItemId: podcast.id, episodeId: episode.id, libraryItem: podcast)
        let result = OrderedPlaybackPlan(entries: [entry], progressByItem: [:]).entries
        #expect(result.count == 1)
        #expect(result.first?.episodeId == episode.id)
        #expect(result.first?.episode == episode)
    }

    @Test func missingProgressIsUnfinishedAndMismatchedEmbeddedItemsAreExcluded() {
        let finished = orderedBook("finished"), newBook = orderedBook("new")
        let entries = [orderedEntry(finished), .init(libraryItemId: "wrong", libraryItem: newBook), orderedEntry(newBook)]
        let progress = ["finished": MediaProgress(libraryItemId: "finished", isFinished: true)]
        #expect(OrderedPlaybackPlan(entries: entries, progressByItem: progress).entries.map(\.id) == ["new"])
    }

    @Test func fixedReleaseMinifiedBooksUseTrackCountWithoutInventingTrackURLs() throws {
        // Book.toOldJSONMinified() in ABS 2.37.1: numTracks, duration and
        // ebookFormat are present, while tracks and audioFiles are absent.
        let payload = Data(#"[{"id":"audio","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"Audio book"},"numTracks":2,"numAudioFiles":2,"numChapters":17,"duration":600,"size":1234}},{"id":"ebook","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"Ebook only"},"numTracks":0,"numAudioFiles":0,"duration":0,"ebookFormat":"epub"}},{"id":"unknown","libraryId":"books","mediaType":"book","media":{"metadata":{"title":"No track information"},"duration":600}}]"#.utf8)
        let items = try JSONDecoder().decode([LibraryItem].self, from: payload)
        #expect(items[0].media.numTracks == 2)
        #expect(items[0].media.tracks.isEmpty)
        #expect(items[1].media.numTracks == 0)
        #expect(items[2].media.numTracks == nil)
        let plan = OrderedPlaybackPlan(entries: items.map { orderedEntry($0) }, progressByItem: [:])
        #expect(plan.entries.map(\.id) == ["audio"])
        #expect(plan.entries[0].libraryItem?.media.tracks.isEmpty == true)
        let roundTrip = try JSONDecoder().decode(ItemMedia.self, from: JSONEncoder().encode(items[0].media))
        #expect(roundTrip.numTracks == 2)
        #expect(ItemMedia(numTracks: 3).numTracks == 3)
    }
}
