import Foundation
import Testing
@testable import AudilseCore

private func taskEvent(_ name: String, _ payload: [String: Any]) throws -> ServerTaskEvent {
    let data = try JSONSerialization.data(withJSONObject: payload)
    let event = try ServerTaskEvent.decode(.init(name: name, payload: data))
    return try #require(event)
}
private func serverTask(_ id: String, action: String = "library-scan", item: String? = nil, library: String? = "library", finished: Bool = false, failed: Bool = false) throws -> ServerTask {
    var data: [String: Any] = [:]
    if let item { data["libraryItemId"] = item }
    if let library { data["libraryId"] = library }
    return try JSONDecoder().decode(ServerTask.self, from: JSONSerialization.data(withJSONObject: ["id": id, "action": action, "data": data, "title": "Synthetic", "isFinished": finished, "isFailed": failed, "startedAt": 10, "finishedAt": finished ? 20 : NSNull()]))
}
private func taskSnapshot(_ tasks: [ServerTask], queued: [String] = []) throws -> ServerTaskListing {
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tasks))
    let data: [String: Any] = ["tasks": encoded, "queuedTaskData": ["embedMetadata": queued.map { ["libraryItemId": $0, "metadataObject": ["title": "Title " + $0]] }]]
    return try JSONDecoder().decode(ServerTaskListing.self, from: JSONSerialization.data(withJSONObject: data))
}

@Suite struct ServerTaskEventTests {
    @Test(arguments: [
        ("https://fixture.test", "/socket.io"),
        ("https://fixture.test/", "/socket.io"),
        ("https://fixture.test/compat", "/compat/socket.io"),
        ("https://fixture.test/compat/", "/compat/socket.io"),
        ("https://fixture.test/proxy/abs", "/proxy/abs/socket.io"),
        ("https://fixture.test/abs%20proxy/", "/abs proxy/socket.io")
    ]) func socketPathPreservesReverseProxySeparators(input: String, expected: String) throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: input)))
        let path = ABSRealtimeClient.socketPath(for: endpoint)
        #expect(path == expected)
        var engineURL = URLComponents(string: "https://fixture.test")!
        engineURL.path = path
        #expect(engineURL.percentEncodedPath == expected.replacingOccurrences(of: " ", with: "%20"))
    }

    @Test func numericMessageSubstitutionsAndTerminalStartedArePreserved() throws {
        let event = try taskEvent("task_started", ["id":"opml", "action":"opml-import-feed", "descriptionKey":"MessageTaskOpmlImportDescription", "descriptionSubs":[2], "isFinished":true, "isFailed":true])
        guard case .started(let task) = event else { Issue.record("Unexpected event"); return }
        #expect(task.descriptionSubs == [.number(2)])
        #expect(task.isFinished && task.isFailed)
        #expect(try JSONDecoder().decode(ServerTask.self, from: JSONEncoder().encode(task)) == task)
        var state = ServerTasksState(); state.apply(event)
        #expect(state.tasks.first?.isFailed == true)
    }

    @Test func initializationHasNoTasksAndUnknownEventsAreIgnored() throws {
        guard case .initialized(let value) = try taskEvent("init", ["userId":"admin", "username":"Admin", "usersOnline":[]]) else { Issue.record("Missing init"); return }
        #expect(value.userId == "admin")
        #expect(try ServerTaskEvent.decode(.init(name:"task_updated", payload:Data("{}".utf8))) == nil)
        #expect(throws: ABSError.invalidResponse) { try ServerTaskEvent.decode(.init(name:"task_started", payload:nil)) }
        #expect(throws: (any Error).self) { try ServerTaskEvent.decode(.init(name:"task_progress", payload:Data("{}".utf8))) }
    }

    @Test func staleSnapshotCannotReviveCompletionAndReplaysNewTasks() throws {
        let running = try serverTask("first"), finished = try serverTask("first", finished:true)
        let next = try serverTask("second", action:"encode-m4b", item:"item")
        var state = ServerTasksState(); state.apply(.started(running))
        var journal = ServerTaskEventJournal()
        for event in [ServerTaskEvent.finished(finished), .started(next), try taskEvent("task_progress", ["libraryItemId":"item", "progress":42])] { state.apply(event); journal.append(event) }
        state.replaceSnapshot(try taskSnapshot([running]), replaying:journal)
        #expect(state.task(id:"first")?.isFinished == true)
        #expect(state.task(id:"second") == next)
        #expect(state.progress(for:next) == 42)
        state.replaceSnapshot(try taskSnapshot([running,next]), replaying:.init())
        #expect(state.task(id:"first")?.isFinished == true)
    }

    @Test func queuedEmbeddingSnapshotReplaysAddAndRemove() throws {
        var state = ServerTasksState(), journal = ServerTaskEventJournal()
        for event in [try taskEvent("metadata_embed_queue_update", ["libraryItemId":"old", "queued":false]), try taskEvent("metadata_embed_queue_update", ["libraryItemId":"new", "queued":true])] { state.apply(event); journal.append(event) }
        state.replaceSnapshot(try taskSnapshot([],queued:["old"]), replaying:journal)
        #expect(state.queuedEmbeds.map(\.id) == ["new"])
        state.replaceSnapshot(try taskSnapshot([],queued:["old"]), replaying:.init())
        #expect(state.queuedEmbeds.first?.title == "Title old")
    }

    @Test func progressIsPercentAndAmbiguousConcurrentTasksAreNotAttributed() throws {
        let encode = try serverTask("encode", action:"encode-m4b", item:"item")
        let embed = try serverTask("embed", action:"embed-metadata", item:"item")
        var state = ServerTasksState(); state.apply(.started(encode))
        state.apply(try taskEvent("task_progress", ["libraryItemId":"item", "progress":25]))
        #expect(state.progress(for:encode) == 25)
        state.apply(.started(embed)); state.apply(try taskEvent("task_progress", ["libraryItemId":"item", "progress":60]))
        #expect(state.progress(for:encode) == nil && state.progress(for:embed) == nil)
        state.apply(.finished(try serverTask("encode", action:"encode-m4b", item:"item", finished:true)))
        #expect(state.progress(for:embed) == nil)
        state.apply(try taskEvent("task_progress", ["libraryItemId":"item", "progress":120]))
        #expect(state.progress(for:embed) == 100)
    }

    @Test func trackIdentityAndNaturalOrderDoNotLoseNumericInodes() throws {
        let task = try serverTask("encode", action:"encode-m4b", item:"item")
        var state = ServerTasksState(); state.apply(.started(task))
        for ino in [10,2,1] { state.apply(try taskEvent("track_started", ["libraryItemId":"item", "ino":ino])) }
        state.apply(try taskEvent("track_progress", ["libraryItemId":"item", "ino":"2", "progress":12.5]))
        state.apply(try taskEvent("track_finished", ["libraryItemId":"item", "ino":"1"]))
        #expect(state.tracks(for:task).map(\.ino) == ["1","2","10"])
        #expect(state.tracks(for:task).first?.isFinished == true)
        #expect(state.tracks(for:task)[1].progress == 12.5)
    }

    @Test func scanCancellationWhitelistRequiresRunningSupportedTaskAndLibraryID() throws {
        let state = ServerTasksState()
        for action in ["library-scan","library-match-all"] { #expect(state.scanLibraryID(for:try serverTask(action,action:action)) == "library") }
        for action in ["watcher-scan","encode-m4b","embed-metadata","unknown"] { #expect(state.scanLibraryID(for:try serverTask(action,action:action)) == nil) }
        #expect(state.scanLibraryID(for:try serverTask("done",finished:true)) == nil)
        #expect(state.scanLibraryID(for:try serverTask("failed",failed:true)) == nil)
        #expect(state.scanLibraryID(for:try serverTask("missing",library:nil)) == nil)
    }

    @Test func coalescedJournalKeepsLatestValuesAndBoundsCompletedHistory() throws {
        let task = try serverTask("encode",action:"encode-m4b",item:"item")
        var journal = ServerTaskEventJournal(); journal.append(.started(task))
        for value in 0..<1_000 { journal.append(try taskEvent("task_progress", ["libraryItemId":"item", "progress":Double(value)/10])) }
        #expect(journal.events.count == 2)
        var state = ServerTasksState(); state.replaceSnapshot(try taskSnapshot([]),replaying:journal)
        #expect(state.progress(for:task) == 99.9)
        for index in 0..<105 { state.apply(.finished(try serverTask("finished-\(index)",finished:true))) }
        #expect(state.tasks.filter(\.isFinished).count == 100)
        #expect(state.task(id:"encode") == task)
    }
}
