import Foundation
import Testing
@testable import AudilseCore

/// The relevant MediaProgress.applyProgressUpdate branches in all three fixed releases.
/// The separate /tmp source probe additionally executes the official Sequelize methods.
private final class PositionWireState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MediaProgress
    private var requests: [(String, [String: Any])] = []
    private var failStatePatch = false
    private var holdPosition = false
    private var delayedResponse: (@Sendable () -> Void)?
    init(time: Double = 11, duration: Double = 600, percentage: Double? = nil, finished: Bool = false, updated: Double = 500) {
        value = .init(libraryItemId: "book", currentTime: time, duration: duration, progress: percentage ?? time / duration, isFinished: finished, lastUpdate: updated, ebookLocation: "unchanged-cfi", ebookProgress: 0.7)
    }
    func result() -> MediaProgress { lock.lock(); defer { lock.unlock() }; return value }
    func patches() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.0 == "PATCH" }.map(\.1) }
    func failCompletion() { lock.lock(); defer { lock.unlock() }; failStatePatch = true }
    func holdNextPosition() { lock.lock(); defer { lock.unlock() }; holdPosition = true }
    func hasHeldResponse() -> Bool { lock.lock(); defer { lock.unlock() }; return delayedResponse != nil }
    func holdIfNeeded(_ request: URLRequest, response: @escaping @Sendable () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard holdPosition, request.httpMethod == "PATCH" else { return false }
        holdPosition = false; delayedResponse = response; return true
    }
    func releaseResponse() {
        lock.lock(); let response = delayedResponse; delayedResponse = nil; lock.unlock()
        response?()
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        guard request.url?.host == "audio-position.example.test", request.url?.path.hasPrefix("/abs/") == true else { throw URLError(.badURL) }
        let path = request.url!.path
        if path == "/abs/login" { return (200, Data(#"{"user":{"id":"user","username":"fixture","type":"root","token":"synthetic-access"}}"#.utf8)) }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" else { return (401, Data()) }
        if request.httpMethod == "GET", path == "/abs/api/me/progress/book" { return (200, try JSONEncoder().encode(value)) }
        if path.hasSuffix("/close") { return (404, Data()) }
        let body = try JSONSerialization.jsonObject(with: positionBody(request)) as! [String: Any]
        requests.append((request.httpMethod ?? "GET", body))
        if path == "/abs/api/session/local" {
            let update = body["updatedAt"] as! Double
            if update >= (value.lastUpdate ?? 0) {
                let time = body["currentTime"] as! Double, duration = body["duration"] as! Double
                apply(["currentTime": time, "duration": duration, "progress": duration > 0 ? min(1, max(0, time / duration)) : 0])
                value.lastUpdate = update
            }
            return (200, Data("{}".utf8))
        }
        guard request.httpMethod == "PATCH", path == "/abs/api/me/progress/book" else { throw URLError(.badURL) }
        if failStatePatch, body["isFinished"] != nil { return (503, Data("fixture failure".utf8)) }
        apply(body)
        return (200, Data())
    }
    private func apply(_ incoming: [String: Any]) {
        var body = incoming
        let oldTime = value.currentTime
        let oldComputed = value.duration > 0 ? min(1, max(0, oldTime / value.duration)) : 0
        if let finished = body["isFinished"] as? Bool {
            if finished && !value.isFinished { value.isFinished = true; value.progress = 1 }
            else if !finished && value.isFinished { value.isFinished = false; value.progress = 0; value.currentTime = 0; body.removeValue(forKey: "currentTime") }
        } else if let percentage = body["progress"] as? Double, percentage != oldComputed {
            value.progress = min(1, max(0, percentage))
        }
        if let duration = body["duration"] as? Double { value.duration = duration }
        if let time = body["currentTime"] as? Double { value.currentTime = time }
        let changedTime = value.currentTime != oldTime
        let nearEnd = value.duration > 0 && value.duration - value.currentTime < 10
        if !value.isFinished && nearEnd { value.isFinished = true; value.progress = 1 }
        else if value.isFinished && changedTime && !nearEnd { value.isFinished = false }
    }
}
private final class PositionWireProtocol: URLProtocol, @unchecked Sendable {
    static let state = PositionStateBox()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let state = Self.state.get()
            let (status, data) = try state.respond(request)
            let response: @Sendable () -> Void = { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            }
            if !state.holdIfNeeded(request, response: response) { response() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class PositionStateBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: PositionWireState?
    func set(_ value: PositionWireState) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> PositionWireState { lock.lock(); defer { lock.unlock() }; return value! }
}
private func positionBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
    return result
}
private func positionClient(_ state: PositionWireState) async throws -> ABSClient {
    PositionWireProtocol.state.set(state)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PositionWireProtocol.self]
    let client = ABSClient(profile: .init(name: "Position fixture", baseURL: URL(string: "https://audio-position.example.test/abs")!, serverVersion: "2.37.1"), session: URLSession(configuration: config), tokenStore: MemoryTokenStore())
    _ = try await client.login(username: "fixture", password: "synthetic")
    return client
}
private func queuedPosition(_ position: Double, baselineTime: Double = 11, baselineFinished: Bool = false) throws -> OfflinePlaybackSession {
    let session = LocalPlaybackSession(id: "session", libraryItemId: "book", duration: 600, currentTime: position, startedAt: 1000, updatedAt: 3000, timeListening: 10)
    return .init(id: session.id, itemID: "book", startedAt: session.startedAt, updatedAt: session.updatedAt, currentTime: position, timeListening: session.timeListening, duration: 600, serverProgressUpdatedAt: 500, serverCurrentTime: baselineTime, serverFinished: baselineFinished, sessionPayload: try JSONEncoder().encode(session))
}
private func positionDatabase() throws -> (ShelfDatabase, URL, AccountPartition) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-audio-position-" + UUID().uuidString)
    return (try ShelfDatabase(path: directory.appendingPathComponent("db.sqlite")), directory, .init(serverID: UUID(), userID: "user"))
}

@Suite(.serialized) struct AudioPositionSyncTests {
    @Test func positionMoveSendsPercentageWithoutCompletionAndPreservesReading() async throws {
        let state = PositionWireState(time: 11, duration: 90)
        let client = try await positionClient(state)
        try await client.setAudioPosition(itemID: "book", currentTime: 61, duration: 90, isFinished: false)
        let saved = try #require(try await client.progress(itemID: "book"))
        #expect(saved.currentTime == 61); #expect(abs(saved.progress - 61 / 90) < 0.000001)
        #expect(saved.ebookLocation == "unchanged-cfi" && saved.ebookProgress == 0.7)
        let patch = try #require(state.patches().first)
        #expect(patch["isFinished"] == nil && patch["ebookProgress"] == nil && patch["extraData"] == nil)
        #expect(state.patches().count == 1)
    }
    @Test func explicitCompletionAndUnfinishedRetainUpstreamResetSemantics() async throws {
        let state = PositionWireState(time: 100)
        let client = try await positionClient(state)
        try await client.setProgressFinished(itemID: "book", isFinished: true)
        #expect(state.result().currentTime == 100 && state.result().isFinished && state.result().progress == 1)
        try await client.setProgressFinished(itemID: "book", isFinished: false)
        #expect(state.result().currentTime == 0 && !state.result().isFinished && state.result().progress == 0)
        #expect(state.patches().allSatisfy { Set($0.keys) == ["isFinished"] })
    }
    @Test func finishedPartialPositionUsesTwoDistinctRequests() async throws {
        let state = PositionWireState(time: 11)
        let client = try await positionClient(state)
        try await client.setAudioPosition(itemID: "book", currentTime: 200, duration: 600, isFinished: true)
        #expect(state.result().currentTime == 200 && state.result().isFinished && state.result().progress == 1)
        #expect(state.patches().count == 2)
        #expect(state.patches()[0]["isFinished"] == nil)
        #expect(Set(state.patches()[1].keys) == ["isFinished"])
    }
    @Test func failedCompletionIsNotRetried() async throws {
        let state = PositionWireState(time: 11); state.failCompletion()
        let client = try await positionClient(state)
        await #expect(throws: ABSError.http(status: 503, message: "service unavailable")) { try await client.setAudioPosition(itemID: "book", currentTime: 200, duration: 600, isFinished: true) }
        #expect(state.patches().count == 2)
        #expect(state.result().currentTime == 200 && !state.result().isFinished)
    }
    @Test(arguments: [true, false])
    func delayedPositionCannotSendCompletionAfterRetirementOrCancellation(retire: Bool) async throws {
        let state = PositionWireState(time: 11); state.holdNextPosition()
        let client = try await positionClient(state)
        let writing = Task { try await client.setAudioPosition(itemID: "book", currentTime: 200, duration: 600, isFinished: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !state.hasHeldResponse(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(state.hasHeldResponse())
        if retire { await client.retireForServerRestore() } else { writing.cancel() }
        state.releaseResponse()
        do { try await writing.value; Issue.record("invalidated position must not continue to a completion request") }
        catch {
            if retire { #expect(error as? ABSError == .sessionChanged) }
            else { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        }
        #expect(state.patches().count == 1 && state.patches()[0]["isFinished"] == nil)
        #expect(!state.result().isFinished)
    }
    @Test(arguments: [SyncPositionChoice.local, .remote])
    func conflictResolutionVerifiesChosenPercentageAndRetainsReading(choice: SyncPositionChoice) async throws {
        let state = PositionWireState(time: 400, updated: 2500)
        let client = try await positionClient(state), remote = ABSOfflineSyncRemote(client: client)
        let (db, directory, partition) = try positionDatabase(); defer { try? FileManager.default.removeItem(at: directory) }
        try await db.enqueue(queuedPosition(100), partition: partition)
        let coordinator = SyncCoordinator(database: db)
        let report = try await coordinator.synchronize(partition: partition, remote: remote)
        let conflict = try #require(report.conflicts.first)
        try await coordinator.resolve(conflict, choice: choice, partition: partition, remote: remote)
        let wanted = choice == .local ? 100.0 : 400.0
        #expect(state.result().currentTime == wanted && abs(state.result().progress - wanted / 600) < 0.000001)
        #expect(state.result().ebookProgress == 0.7)
        #expect(try await db.pendingSessions(partition: partition).isEmpty)
        #expect(try await db.conflicts(partition: partition).isEmpty)
        #expect(state.patches().allSatisfy { $0["isFinished"] == nil })
    }
    @Test func samePositionWithHistoricalPercentageDivergenceIsReportedWithoutRepairOrAck() async throws {
        let state = PositionWireState(time: 61, percentage: 11 / 600)
        let client = try await positionClient(state), remote = ABSOfflineSyncRemote(client: client)
        let (db, directory, partition) = try positionDatabase(); defer { try? FileManager.default.removeItem(at: directory) }
        let pending = try queuedPosition(61, baselineTime: 61); try await db.enqueue(pending, partition: partition)
        do { _ = try await SyncCoordinator(database: db).synchronize(partition: partition, remote: remote); Issue.record("stale percentage must not be acknowledged") }
        catch let error as ClientDiagnostic {
            #expect(error.code == "sync.percentageDiverged")
            #expect(error.arguments == [String(61.0 / 600), String(11.0 / 600)])
        }
        #expect(state.result().currentTime == 61 && state.result().progress == 11 / 600)
        #expect(try await db.pendingSessions(partition: partition) == [pending])
        #expect(state.patches().count == 1 && state.patches()[0]["isFinished"] == nil)
    }
    @Test(arguments: [true, false])
    func existingFinishedSamePositionAndUpstreamNearEndRuleNeverGetFalseAck(initiallyFinished: Bool) async throws {
        let position = initiallyFinished ? 100.0 : 595.0
        let oldTime = initiallyFinished ? 100.0 : 550.0
        let state = PositionWireState(time: oldTime, percentage: initiallyFinished ? 1 : oldTime / 600, finished: initiallyFinished)
        let client = try await positionClient(state), remote = ABSOfflineSyncRemote(client: client)
        let (db, directory, partition) = try positionDatabase(); defer { try? FileManager.default.removeItem(at: directory) }
        let pending = try queuedPosition(position, baselineTime: oldTime, baselineFinished: initiallyFinished); try await db.enqueue(pending, partition: partition)
        await #expect(throws: OfflineSyncError.verificationFailed) { _ = try await SyncCoordinator(database: db).synchronize(partition: partition, remote: remote) }
        #expect(try await db.pendingSessions(partition: partition) == [pending])
        #expect(state.result().isFinished)
        #expect(state.patches().allSatisfy { $0["isFinished"] == nil })
    }
    @Test func snapshotPercentageIsOptionalForExistingCachedConflicts() throws {
        let old = Data(#"{"itemID":"book","currentTime":11,"duration":90,"isFinished":false,"updatedAt":500}"#.utf8)
        var snapshot = try JSONDecoder().decode(SyncProgressSnapshot.self, from: old)
        #expect(snapshot.audioProgress == nil)
        snapshot.audioProgress = 11 / 90
        #expect(try JSONDecoder().decode(SyncProgressSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }
}
