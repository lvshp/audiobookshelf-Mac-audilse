import Foundation
import Testing
@testable import AudilseCore

private actor FaultShareStore: PublicShareStateStore {
    var data: Data?
    var failing = false
    func setFailure(_ value: Bool) { failing = value }
    func load(key: String) -> Data? { data }
    func compareAndSwap(key: String, expected: Data?, replacement: Data?) throws -> Bool {
        if failing { throw PublicShareStorageError.io(5) }
        guard data == expected else { return false }; data = replacement; return true
    }
}
private actor SuspendedShareStore: PublicShareStateStore {
    var data: Data?
    var suspendNext = false
    var continuation: CheckedContinuation<Void, Never>?
    func arm() { suspendNext = true }
    func isSuspended() -> Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
    func load(key: String) -> Data? { data }
    func compareAndSwap(key: String, expected: Data?, replacement: Data?) async -> Bool {
        if suspendNext { suspendNext = false; await withCheckedContinuation { continuation = $0 } }
        guard data == expected else { return false }; data = replacement; return true
    }
}
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PUBLIC_SHARE_FIXTURE_INFO"] != nil)) struct PublicShareClientTests {
    private func base() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["PUBLIC_SHARE_FIXTURE_INFO"] else {
            throw IssueRecorded() // Explicit fixture required; never contact a configured user server.
        }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: String]
        return value["baseURL"]!
    }
    private struct IssueRecorded: Error {}
    private func client(_ slug: String, store: any PublicShareStateStore = MemoryPublicShareStateStore()) throws -> PublicShareClient {
        PublicShareClient(location: try PublicShareLocation(link: URL(string: try base() + "/share/" + slug)!), stateStore: store)
    }
    private func control(_ body: [String: Bool]) async throws {
        let origin = try String(base().dropLast("/prefix".count))
        var request = URLRequest(url: URL(string: origin + "/__control")!); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
    @Test func strictLocations() throws {
        for text in ["https://user:pass@example.com/share/a", "https://example.com/share/%252e%252e", "https://example.com/a//share/b", "https://example.com/share/a?t=1&t=2", "https://example.com/share/a#x"] {
            #expect(throws: PublicShareError.self) { try PublicShareLocation(link: URL(string: text)!) }
        }
        let location = try PublicShareLocation(link: URL(string: "https://EXAMPLE.com:443/prefix/share/a?t=2")!)
        #expect(location.baseURL.absoluteString == "https://example.com/prefix/")
        #expect(throws: PublicShareError.self) { try location.validateTrackURL("https://example.com:444/prefix/public/share/a/track/1", index: 1) }
    }
    @Test func rangeCoverDownloadAndRetire() async throws {
        let c = try client("normal"); let s = try await c.open()
        let range = try await c.readTrackRange(index: 1, offset: 256, length: 1024, handle: s.handle)
        #expect(range.range == 256..<1280); #expect(range.totalLength == 65536)
        #expect(range.data == Data((0..<1024).map { UInt8($0 % 256) }))
        #expect(try await c.cover(handle: s.handle) != nil)
        let exported = try await c.download(handle: s.handle)
        defer { try? FileManager.default.removeItem(at: exported.fileURL.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: exported.fileURL).count == 65540)
        #expect(!exported.suggestedFilename.contains("/"))
        let ack = try await c.syncProgress(currentTime: 1.5, handle: s.handle); #expect(ack.remoteAcknowledged)
        try await c.retire(handle: s.handle)
        await #expect(throws: PublicShareError.self) { try await c.checkpoint(currentTime: 2, handle: s.handle) }
    }
    @Test func boundedHostileResponses() async throws {
        for slug in ["ignore-range", "oversized-range", "wrong-range", "chunk-overflow", "track-redirect"] {
            let c = try client(slug); let s = try await c.open()
            await #expect(throws: PublicShareError.self) { try await c.readTrackRange(index: 1, offset: 0, length: 1024, handle: s.handle) }
        }
        for slug in ["cross-origin", "bad-cookie", "redirect", "gone"] {
            let c = try client(slug)
            await #expect(throws: PublicShareError.self) { try await c.open() }
        }
        let c = try client("huge-cover"); let s = try await c.open()
        await #expect(throws: PublicShareError.self) { try await c.cover(handle: s.handle) }
    }
    @Test func durableFailureRecoveryAndServerRestart() async throws {
        let store = MemoryPublicShareStateStore(); let c = try client("recovery", store: store); let s = try await c.open()
        try await control(["failProgress": true])
        do { _ = try await c.syncProgress(currentTime: 2.5, handle: s.handle); Issue.record("Expected remote failure") }
        catch let failure as PublicShareProgressSyncFailure { #expect(!failure.checkpoint.remoteAcknowledged); #expect(failure.checkpoint.currentTime == 2.5) }
        try await control(["failProgress": false, "restart": true])
        let recovered = try await c.reopen(); #expect(recovered.currentTime == 2.5)
        #expect(recovered.handle != s.handle)
        #expect(try await c.syncProgress(currentTime: 2.5, handle: recovered.handle).remoteAcknowledged)
    }
    @Test func failedRetirementAndCloseRemainRetryable() async throws {
        let store = FaultShareStore(); let c = try client("retire-retry", store: store); let s = try await c.open()
        await store.setFailure(true)
        await #expect(throws: PublicShareStorageError.self) { try await c.checkpoint(currentTime: 1, handle: s.handle) }
        await #expect(throws: PublicShareStorageError.self) { try await c.retire(handle: s.handle) }
        await #expect(throws: PublicShareStorageError.self) { try await c.close(currentTime: 2, handle: s.handle) }
        await store.setFailure(false)
        let saved = try await c.checkpoint(currentTime: 3, handle: s.handle)
        #expect(saved.currentTime == 3); try await c.retire(handle: s.handle)
    }
    @Test func permissionRechecked() async throws {
        let c = try client("permission"); let s = try await c.open()
        try await control(["downloadAllowed": false])
        await #expect(throws: PublicShareError.downloadForbidden) { try await c.download(handle: s.handle) }
        try await control(["downloadAllowed": true])
    }
    @Test func cancelledExportRemovesPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory
        let c = try client("slow-download"); let snapshot = try await c.open()
        let task = Task { try await c.download(handle: snapshot.handle) }
        var partial: URL?
        for _ in 0..<100 {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("Audilse-PublicShare-") {
                let file = directory.appendingPathComponent(name).appendingPathComponent("download")
                if let reader = try? FileHandle(forReadingFrom: file) {
                    let first = try? reader.read(upToCount: 1); try? reader.close()
                    if first == Data("x".utf8) { partial = file.deletingLastPathComponent() }
                }
            }
            if partial != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(partial != nil)
        if let partial { #expect(!FileManager.default.fileExists(atPath: partial.path)) }
    }
    @Test func isolatedCookiesAndNoRedirect() async throws {
        try await control(["clearRecords": true])
        let a = try client("isolation-a"), b = try client("isolation-b")
        let sa = try await a.open(), sb = try await b.open()
        _ = try await a.readTrackRange(index: 1, offset: 0, length: 16, handle: sa.handle)
        _ = try await b.readTrackRange(index: 1, offset: 0, length: 16, handle: sb.handle)
        let redirect = try client("redirect")
        await #expect(throws: PublicShareError.self) { try await redirect.open() }
        let origin = try String(base().dropLast("/prefix".count))
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/__control")!)
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let records = state["records"] as! [[String: Any]]
        #expect(records.allSatisfy { $0["authorization"] as? Bool == false && $0["proxyAuthorization"] as? Bool == false })
        #expect(records.allSatisfy { Set($0["cookieNames"] as! [String]).isSubset(of: ["share_session_id"]) })
        #expect(!records.contains { ($0["path"] as! String).contains("__sink") })
        let tracks = records.filter { ($0["path"] as! String).contains("/track/") }
        #expect(tracks.count == 2 && tracks[0]["cookieDigest"] as? String != tracks[1]["cookieDigest"] as? String)
    }
    @Test func retirementSerializesLifecycleTransitions() async throws {
        let store = SuspendedShareStore(), c = try client("lifecycle-race", store: store)
        let snapshot = try await c.open(); await store.arm()
        let save = Task { try await c.checkpoint(currentTime: 1, handle: snapshot.handle) }
        for _ in 0..<100 {
            if await store.isSuspended() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await store.isSuspended())
        let retire = Task { try await c.retire(handle: snapshot.handle) }
        // Observe the actor's transition gate instead of assuming task scheduling order.
        var gated = false
        for _ in 0..<100 {
            do { _ = try await c.readTrackRange(index: 1, offset: 0, length: 1, handle: snapshot.handle) }
            catch PublicShareError.sessionChanged { gated = true; break }
            catch PublicShareError.transport(-999) { /* Retirement cancelled the in-flight probe; observe the next gate. */ }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(gated)
        await #expect(throws: PublicShareError.closed) { try await c.reopen() }
        await #expect(throws: PublicShareError.closed) { try await c.forget() }
        await store.resume(); _ = try await save.value; try await retire.value
        let fresh = try await c.reopen(); #expect(fresh.handle != snapshot.handle)
    }
    @Test func cancelledOpenDoesNotAdoptLateSession() async throws {
        let store = MemoryPublicShareStateStore(), c = try client("slow-open", store: store)
        let opening = Task { try await c.open() }
        try await Task.sleep(for: .milliseconds(40)); opening.cancel()
        await #expect(throws: (any Error).self) { try await opening.value }
        try await Task.sleep(for: .milliseconds(550))
        #expect(await store.load(key: c.location.storageKey) == nil)
        #expect(try await c.open().tracks.count == 2)
    }
    @Test func encryptedStoreAndCAS() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("public-state-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LocalPublicShareStateStore(directory: folder); let key = String(repeating: "a", count: 64)
        let bytes = Data("synthetic-anonymous-state".utf8)
        #expect(try await store.compareAndSwap(key: key, expected: nil, replacement: bytes))
        #expect(try await store.load(key: key) == bytes)
        #expect(try await !store.compareAndSwap(key: key, expected: nil, replacement: Data()))
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(!(try Data(contentsOf: file)).contains(bytes))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }
}
