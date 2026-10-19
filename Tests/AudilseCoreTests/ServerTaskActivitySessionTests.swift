import Foundation
import Testing
@testable import AudilseCore

private func activityRaw(_ name: String, _ body: [String: Any]) throws -> RealtimeEvent {
    .init(name: name, payload: try JSONSerialization.data(withJSONObject: body))
}
private func activitySource(user: String = "admin", generation: UUID = UUID(), connection: UUID = UUID()) -> ServerTaskActivitySession.Source {
    .init(partition: .init(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, userID: user), generation: generation, connection: connection)
}
private func activityTask(_ id: String, finished: Bool, failed: Bool = false, time: Int = 1) throws -> RealtimeEvent {
    try activityRaw("task_started", ["id": id, "action": "opml-import-feed", "title": "Synthetic feed",
        "isFinished": finished, "isFailed": failed, "startedAt": time, "finishedAt": time,
        "errorKey": failed ? "MessageTaskOpmlImportFeedFailed" : ""])
}

@Suite struct ServerTaskActivitySessionTests {
    @Test func failedStartedIsAvailableWhenPageOpensLaterAndSnapshotCannotEraseIt() throws {
        let source = activitySource()
        var cache = ServerTaskActivitySession(); cache.begin(source)
        #expect(try cache.consume(activityRaw("init", ["userId": "admin"]), from: source))
        #expect(try cache.consume(activityTask("failed-feed", finished: true, failed: true), from: source))
        var page = ServerTasksState()
        for raw in try cache.replay() {
            if let event = try ServerTaskEvent.decode(raw) { page.apply(event) }
        }
        #expect(page.task(id: "failed-feed")?.isFailed == true)
        let snapshot = try JSONDecoder().decode(ServerTaskListing.self, from: Data(#"{"tasks":[]}"#.utf8))
        page.replaceSnapshot(snapshot, replaying: .init())
        #expect(page.task(id: "failed-feed")?.isFinished == true)
        #expect(page.task(id: "failed-feed")?.isFailed == true)
    }

    @Test func identityGenerationAndConnectionRejectLateEvents() throws {
        let first = activitySource()
        var cache = ServerTaskActivitySession(); cache.begin(first)
        #expect(try !cache.consume(activityTask("before-auth", finished: true, failed: true), from: first))
        #expect(try !cache.consume(activityRaw("init", ["userId": "other"]), from: first))
        #expect(!cache.isAuthenticated)
        #expect(try cache.consume(activityRaw("init", ["userId": "admin"]), from: first))
        #expect(try cache.consume(activityTask("old", finished: true), from: first))
        let replacement = activitySource(generation: first.generation)
        cache.begin(replacement)
        #expect(cache.state.tasks.isEmpty)
        #expect(try !cache.consume(activityRaw("init", ["userId": "admin"]), from: first))
        #expect(try !cache.consume(activityTask("late-socket", finished: true), from: first))
        #expect(try cache.consume(activityRaw("init", ["userId": "admin"]), from: replacement))
        let nextAccount = activitySource(user: "other")
        cache.begin(nextAccount)
        #expect(try !cache.consume(activityTask("late-account", finished: true), from: replacement))
        #expect(try !cache.consume(activityRaw("init", ["userId": "admin"]), from: nextAccount))
        #expect(try cache.consume(activityRaw("init", ["userId": "other"]), from: nextAccount))
        #expect(cache.state.tasks.isEmpty)
        cache.reset()
        #expect(try !cache.consume(activityTask("after-signout", finished: true), from: nextAccount))
        #expect(try cache.replay().isEmpty)
    }

    @Test func completionCacheIsBoundedAndDoesNotEvictRunningTask() throws {
        let source = activitySource()
        var cache = ServerTaskActivitySession(); cache.begin(source)
        try cache.consume(activityRaw("init", ["userId": "admin"]), from: source)
        try cache.consume(activityTask("running", finished: false), from: source)
        for index in 0..<130 { try cache.consume(activityTask("done-\(index)", finished: true, failed: true, time: index), from: source) }
        #expect(cache.state.tasks.filter(\.isFinished).count == 100)
        #expect(cache.state.task(id: "running") != nil)
        #expect(cache.state.task(id: "done-0") == nil)
        #expect(cache.state.task(id: "done-129")?.isFailed == true)
        #expect(try cache.replay().count == 102) // init + 100 terminal + 1 active
    }

    @Test func disconnectKeepsHistoryButRequiresNewIdentityBeforeConsuming() throws {
        let source = activitySource()
        var cache = ServerTaskActivitySession(); cache.begin(source)
        try cache.consume(activityRaw("init", ["userId": "admin"]), from: source)
        try cache.consume(activityTask("remembered", finished: true, failed: true), from: source)
        try cache.consume(.init(name: "disconnected", payload: nil), from: source)
        #expect(!cache.isAuthenticated)
        #expect(try cache.replay().count == 1)
        #expect(try !cache.consume(activityTask("unverified", finished: true), from: source))
        try cache.consume(activityRaw("init", ["userId": "admin"]), from: source)
        #expect(cache.state.task(id: "remembered") != nil)
        try cache.consume(.init(name: "auth_failed", payload: nil), from: source)
        #expect(cache.state.tasks.isEmpty)
        #expect(!cache.isAuthenticated)
    }
}
