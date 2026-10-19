import Foundation
import Testing
@testable import AudilseCore

@Test func readingPositionReopensAndSeparatesUsersAndServers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let a = AccountPartition(serverID: UUID(), userID: "alice")
    let b = AccountPartition(serverID: a.serverID, userID: "bob")
    let c = AccountPartition(serverID: UUID(), userID: "alice")
    let position = ReadingCheckpoint(itemID: "book", format: .epub, location: "epubcfi(/6/2)", progress: 0.2, updatedAt: 2000, baselineLocation: "epubcfi(/6/1)", baselineProgress: 0.1, baselineUpdatedAt: 1000)
    try await repository.checkpoint(position, partition: a)
    let reopened = try ReadingRepository(rootDirectory: root)
    #expect(try await reopened.position(itemID: "book", partition: a) == position)
    #expect(try await reopened.pending(partition: a) == [position])
    #expect(try await reopened.position(itemID: "book", partition: b) == nil)
    #expect(try await reopened.pending(partition: c).isEmpty)
}

@Test func readingQueueKeepsOriginalRemoteBaselineAndLatestBackwardPosition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    try await repository.checkpoint(ReadingCheckpoint(itemID: "book", format: .pdf, location: "8", progress: 0.7, updatedAt: 2000, baselineLocation: "3", baselineProgress: 0.2, baselineUpdatedAt: 1000), partition: partition)
    try await repository.checkpoint(ReadingCheckpoint(itemID: "book", format: .pdf, location: "4", progress: 0.3, updatedAt: 3000, baselineLocation: "9", baselineProgress: 0.8, baselineUpdatedAt: 2500), partition: partition)
    let saved = try #require(await repository.position(itemID: "book", partition: partition))
    #expect(saved.location == "4")
    #expect(saved.baselineLocation == "3")
    #expect(saved.baselineUpdatedAt == 1000)
}

@Test func mobiPositionsRemainLocalAndDoNotInventServerProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-reading-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try ReadingRepository(rootDirectory: root)
    let partition = AccountPartition(serverID: UUID(), userID: "reader")
    try await repository.checkpoint(ReadingCheckpoint(itemID: "mobi", format: .mobi, location: "mobi:2:300", progress: 0.3), partition: partition)
    #expect(try await repository.pending(partition: partition).isEmpty)
    #expect(try await repository.position(itemID: "mobi", partition: partition)?.location == "mobi:2:300")
}

@Test func audioOnlyChangesDoNotCreateReadingConflicts() {
    let local = ReadingCheckpoint(itemID: "book", format: .epub, location: "new-cfi", progress: 0.4, updatedAt: 2000, baselineLocation: "old-cfi", baselineProgress: 0.2, baselineUpdatedAt: 1000)
    let audioOnly = MediaProgress(libraryItemId: "book", currentTime: 500, duration: 600, lastUpdate: 1800, ebookLocation: "old-cfi", ebookProgress: 0.2)
    #expect(!ReadingRepository.hasConflict(local: local, remote: audioOnly))
    let remoteReading = MediaProgress(libraryItemId: "book", currentTime: 500, duration: 600, lastUpdate: 1800, ebookLocation: "different-cfi", ebookProgress: 0.6)
    #expect(ReadingRepository.hasConflict(local: local, remote: remoteReading))
}

@Test func pdfAndComicProgressUsesOneBasedABSPageContract() {
    #expect(ReadingCheckpoint.pageProgress(page: 1, count: 10) == 0)
    #expect(ReadingCheckpoint.pageProgress(page: 10, count: 10) == 0.9)
    #expect(ReadingCheckpoint.pageProgress(page: 0, count: 0) == 0)
}
