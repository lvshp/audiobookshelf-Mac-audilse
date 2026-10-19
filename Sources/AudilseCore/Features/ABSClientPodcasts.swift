import Foundation

extension ABSClient {
    public func searchPodcastDirectory(term: String, country: String = "us") async throws -> [PodcastDirectoryResult] {
        try await getJSON(path: FeaturePath.query("api/search/podcast", [.init(name: "term", value: term), .init(name: "country", value: country)]))
    }
    public func existingPodcasts(libraryID: String) async throws -> [ExistingPodcastTitle] {
        let response: ExistingPodcastsResponse = try await getJSON(path: "api/libraries/\(FeaturePath.id(libraryID))/podcast-titles")
        return response.podcasts
    }
    public func recentPodcastEpisodes(libraryID: String, page: Int = 0, limit: Int = 50) async throws -> RecentPodcastEpisodesPage {
        try await getJSON(path: FeaturePath.query("api/libraries/\(FeaturePath.id(libraryID))/recent-episodes", [.init(name: "page", value: String(max(0, page))), .init(name: "limit", value: String(min(100, max(1, limit))))]))
    }
    public func podcastLibraryDownloadQueue(libraryID: String) async throws -> PodcastLibraryDownloadQueue {
        // ABS caches /libraries GETs by the full URL. Queue changes are in memory
        // and do not trigger its database cache invalidation hooks. A fresh URL
        // reads transient state without changing sorting or queue semantics.
        let path = FeaturePath.query("api/libraries/\(FeaturePath.id(libraryID))/episode-downloads", [
            .init(name: "_queueRefresh", value: UUID().uuidString)
        ])
        return try await getJSON(path: path)
    }
    public func podcastEpisodeDetails(itemID: String, episodeID: String) async throws -> PodcastEpisodeDetails {
        try await getJSON(path: "api/podcasts/\(FeaturePath.id(itemID))/episode/\(FeaturePath.id(episodeID))")
    }
    public func setPodcastEpisodeFinished(itemID: String, episodeID: String, isFinished: Bool) async throws {
        _ = try await requestData(path: "api/me/progress/\(FeaturePath.id(itemID))/\(FeaturePath.id(episodeID))", method: "PATCH", body: JSONEncoder().encode(PodcastFinishedPayload(isFinished: isFinished)))
    }
    public func podcastFeed(url: String) async throws -> PodcastFeed { let response: PodcastFeedResponse = try await postJSON(path: "api/podcasts/feed", body: PodcastFeedPayload(rssFeed: url)); return response.podcast }
    public func parseOPML(text: String) async throws -> [OPMLFeed] { let response: OPMLResponse = try await postJSON(path: "api/podcasts/opml/parse", body: OPMLPayload(opmlText: text)); return response.feeds }
    public func exportOPML(libraryID: String) async throws -> Data { try await requestData(path: "api/libraries/\(FeaturePath.id(libraryID))/opml") }
    public func importOPML(feedURLs: [String], libraryID: String, folderID: String, autoDownloadEpisodes: Bool = false) async throws {
        _ = try await requestData(path: "api/podcasts/opml/create", method: "POST", body: JSONEncoder().encode(OPMLImportPayload(feeds: feedURLs, libraryId: libraryID, folderId: folderID, autoDownloadEpisodes: autoDownloadEpisodes)))
    }
    public func createPodcast(_ draft: PodcastSubscriptionDraft) async throws -> LibraryItem { try await postJSON(path: "api/podcasts", body: draft) }
    public func podcastDownloads(itemID: String) async throws -> [PodcastServerDownload] { let response: PodcastDownloadsResponse = try await getJSON(path: "api/podcasts/\(FeaturePath.id(itemID))/downloads"); return response.downloads }
    public func checkNewPodcastEpisodes(itemID: String, limit: Int = 3) async throws -> [PodcastFeedEpisode] {
        let path = FeaturePath.query("api/podcasts/\(FeaturePath.id(itemID))/checknew", [URLQueryItem(name: "limit", value: String(max(0, limit)))])
        // Despite its GET method, this ABS endpoint enqueues downloads. Never replay it automatically.
        let data = try await requestData(path: path, retryAfterAuthentication: false)
        return try JSONDecoder().decode(PodcastFeedEpisodesResponse.self, from: data).episodes
    }
    public func clearPodcastDownloadQueue(itemID: String) async throws { _ = try await requestData(path: "api/podcasts/\(FeaturePath.id(itemID))/clear-queue", retryAfterAuthentication: false) }
    public func searchPodcastEpisodes(itemID: String, title: String) async throws -> [PodcastFeedEpisode] { let response: PodcastEpisodeMatchesResponse = try await getJSON(path: FeaturePath.query("api/podcasts/\(FeaturePath.id(itemID))/search-episode", [URLQueryItem(name: "title", value: title)])); return response.episodes.map(\.episode) }
    public func downloadPodcastEpisodes(itemID: String, episodes: [PodcastFeedEpisode]) async throws { _ = try await requestData(path: "api/podcasts/\(FeaturePath.id(itemID))/download-episodes", method: "POST", body: JSONEncoder().encode(episodes)) }
    public func matchPodcastEpisodes(itemID: String, overrideDetails: Bool = false) async throws -> Int { let response: EpisodeMatchResponse = try await postJSON(path: "api/podcasts/\(FeaturePath.id(itemID))/match-episodes?override=\(overrideDetails ? "1" : "0")", body: EmptyPayload()); return response.numEpisodesUpdated ?? 0 }
    public func podcastEpisode(itemID: String, episodeID: String) async throws -> PodcastEpisode { try await getJSON(path: "api/podcasts/\(FeaturePath.id(itemID))/episode/\(FeaturePath.id(episodeID))") }
    public func updatePodcastEpisode(itemID: String, episodeID: String, update: PodcastEpisodeUpdate) async throws -> LibraryItem { try JSONDecoder().decode(LibraryItem.self, from: await requestData(path: "api/podcasts/\(FeaturePath.id(itemID))/episode/\(FeaturePath.id(episodeID))", method: "PATCH", body: JSONEncoder().encode(update))) }
    public func deletePodcastEpisode(itemID: String, episodeID: String, deleteFile: Bool = false) async throws -> LibraryItem { try JSONDecoder().decode(LibraryItem.self, from: await requestData(path: "api/podcasts/\(FeaturePath.id(itemID))/episode/\(FeaturePath.id(episodeID))?hard=\(deleteFile ? "1" : "0")", method: "DELETE")) }
    public func updatePodcastSettings(itemID: String, update: PodcastSettingsUpdate) async throws -> LibraryItem { try JSONDecoder().decode(PodcastSettingsResponse.self, from: await requestData(path: "api/items/\(FeaturePath.id(itemID))/media", method: "PATCH", body: JSONEncoder().encode(update))).libraryItem }
}

private struct PodcastFeedResponse: Decodable, Sendable { let podcast: PodcastFeed }
private struct ExistingPodcastsResponse: Decodable, Sendable { let podcasts: [ExistingPodcastTitle] }
private struct PodcastFinishedPayload: Encodable, Sendable { let isFinished: Bool }
private struct PodcastFeedPayload: Encodable, Sendable { let rssFeed: String }
private struct OPMLPayload: Encodable, Sendable { let opmlText: String }
private struct OPMLResponse: Decodable, Sendable { let feeds: [OPMLFeed] }
private struct OPMLImportPayload: Encodable, Sendable { let feeds: [String]; let libraryId: String; let folderId: String; let autoDownloadEpisodes: Bool }
private struct PodcastFeedEpisodesResponse: Decodable, Sendable { let episodes: [PodcastFeedEpisode] }
private struct PodcastEpisodeMatchesResponse: Decodable, Sendable {
    struct Match: Decodable, Sendable { let episode: PodcastFeedEpisode }
    let episodes: [Match]
}
private struct PodcastDownloadsResponse: Decodable, Sendable { let downloads: [PodcastServerDownload] }
private struct EpisodeMatchResponse: Decodable, Sendable { let numEpisodesUpdated: Int? }

private struct PodcastSettingsResponse: Decodable, Sendable { let updated: Bool; let libraryItem: LibraryItem }
