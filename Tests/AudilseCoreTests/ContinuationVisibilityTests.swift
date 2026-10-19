import Foundation
import Testing
@testable import AudilseCore

struct ContinuationVisibilityTests {
    @Test func metadataNeverRewindsAudioOrReading() {
        let current = MediaProgress(libraryItemId: "book", currentTime: 900, duration: 1800, progress: 0.5, lastUpdate: 999, ebookLocation: "new-cfi", ebookProgress: 0.8)
        let staleResponse = MediaProgress(libraryItemId: "book", currentTime: 100, duration: 2000, progress: 0.05, lastUpdate: 100, ebookLocation: "old-cfi", ebookProgress: 0.1, serverID: "uuid", hideFromContinueListening: true)
        let merged = current.withContinuationMetadata(from: staleResponse)
        #expect(merged.currentTime == 900 && merged.duration == 1800 && merged.progress == 0.5 && merged.lastUpdate == 999)
        #expect(merged.ebookLocation == "new-cfi" && merged.ebookProgress == 0.8)
        #expect(merged.serverID == "uuid" && merged.hideFromContinueListening)
        #expect(current.withContinuationMetadata(from: .init(libraryItemId: "other", hideFromContinueListening: true)) == current)
        let user = UserAccount(id: "u", username: "Name", type: "root", mediaProgress: [current], seriesHideFromContinueListening: ["s1"])
        let changed = ContinuationMetadataChange.progress(staleResponse).applying(to: user)
        #expect(changed.mediaProgress == [merged] && changed.type == "root" && changed.seriesHideFromContinueListening == ["s1"])
        #expect(ContinuationMetadataChange.series(id: "s2", hidden: true).applying(to: changed).seriesHideFromContinueListening == ["s1", "s2"])
    }

    @Test func preciseEpisodeAndRecommendationContextOnly() throws {
        let wire = #"[{"id":"continue-listening","label":"Continue","type":"episode","entities":[{"id":"show","libraryId":"l","mediaType":"podcast","media":{"metadata":{"title":"Show"}},"recentEpisode":{"id":"e1","title":"One"}},{"id":"show","libraryId":"l","mediaType":"podcast","media":{"metadata":{"title":"Show"}},"recentEpisode":{"id":"e2","title":"Two"}}],"total":99},{"id":"continue-series","label":"Series","type":"book","entities":[{"id":"book","libraryId":"l","mediaType":"book","media":{"metadata":{"title":"Next","series":{"id":"s1","name":"One"}}}},{"id":"book","libraryId":"l","mediaType":"book","media":{"metadata":{"title":"Next","series":{"id":"s2","name":"Two"}}}}],"total":2}]"#
        let shelves = try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: Data(wire.utf8))
        let hidden = MediaProgress(libraryItemId: "show", episodeId: "e1", currentTime: 10, serverID: "uuid", hideFromContinueListening: true)
        let user = UserAccount(id: "u", username: "User", mediaProgress: [hidden], seriesHideFromContinueListening: ["s1"])
        let listening = shelves[0].applyingContinuationVisibility(user: user, progressByID: [hidden.id: hidden])
        #expect(listening.total == 99 && listening.entities.count == 1)
        guard case .item(let remaining) = listening.entities[0] else { Issue.record("Expected episode"); return }
        #expect(remaining.recentEpisode?.id == "e2")
        let series = shelves[1].applyingContinuationVisibility(user: user, progressByID: [:])
        #expect(series.entities.count == 1 && series.total == 2)
        var recent = shelves[0]; recent.id = "newest-episodes"
        #expect(recent.applyingContinuationVisibility(user: user, progressByID: [:]) == recent)
    }

    @Test func stationaryAudioCheckpointKeepsHiddenButAdvanceReveals() {
        let previous = MediaProgress(libraryItemId: "book", currentTime: 20, serverID: "uuid", hideFromContinueListening: true)
        let paused = MediaProgress(libraryItemId: "book", currentTime: 20).preservingLocalContinuationMetadata(from: previous)
        let advanced = MediaProgress(libraryItemId: "book", currentTime: 21).preservingLocalContinuationMetadata(from: previous)
        #expect(paused.serverID == "uuid" && paused.hideFromContinueListening)
        #expect(advanced.serverID == "uuid" && !advanced.hideFromContinueListening)
    }

    @Test func transactionalCacheMergePreservesNewestResumeAndOtherAccounts() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("continuation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try ShelfDatabase(path: path)
        let first = AccountPartition(serverID: UUID(), userID: "u")
        let second = AccountPartition(serverID: first.serverID, userID: "other")
        let newest = MediaProgress(libraryItemId: "book", currentTime: 900, progress: 0.5, lastUpdate: 999, ebookLocation: "new", ebookProgress: 0.8)
        let user = UserAccount(id: "u", username: "User", mediaProgress: [newest], seriesHideFromContinueListening: ["keep"])
        try await database.save(user, key: "user", partition: first)
        try await database.save([newest], key: "progress", partition: first)
        try await database.saveResume(newest, partition: first)
        try await database.saveResume(newest, partition: second)
        let response = MediaProgress(libraryItemId: "book", currentTime: 1, ebookLocation: "old", serverID: "uuid", hideFromContinueListening: true)
        try await database.applyContinuationMetadata(.progress(response), partition: first)
        try await database.applyContinuationMetadata(.series(id: "new", hidden: true), partition: first)
        let reopened = try ShelfDatabase(path: path)
        let resume = try #require(await reopened.loadResume(itemID: "book", partition: first))
        #expect(resume.currentTime == 900 && resume.lastUpdate == 999 && resume.ebookLocation == "new" && resume.ebookProgress == 0.8)
        #expect(resume.serverID == "uuid" && resume.hideFromContinueListening)
        #expect(try await reopened.loadResume(itemID: "book", partition: second) == newest)
        let restoredUser = try #require(await reopened.load(UserAccount.self, key: "user", partition: first))
        #expect(restoredUser.seriesHideFromContinueListening == ["keep", "new"] && restoredUser.mediaProgress.first?.currentTime == 900)
        #expect(try await reopened.load([MediaProgress].self, key: "progress", partition: first)?.first?.currentTime == 900)
        try await reopened.saveResume(.init(libraryItemId: "book", currentTime: 900, lastUpdate: 1000), partition: first)
        #expect(try await reopened.loadResume(itemID: "book", partition: first)?.hideFromContinueListening == true)
        try await reopened.saveResume(.init(libraryItemId: "book", currentTime: 901, lastUpdate: 1001), partition: first)
        #expect(try await reopened.loadResume(itemID: "book", partition: first)?.hideFromContinueListening == false)
    }
}
