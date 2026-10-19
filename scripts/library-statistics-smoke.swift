// Compiles the actual LibraryStatisticsModel. Identity-only AppStore is supplied here.
// Every request is intercepted; only synthetic MemoryTokenStore credentials are used.
import Foundation
import AudilseCore

@MainActor final class AppStore {
    var partition: AccountPartition?
    var profile: ServerProfile?
    var user: UserAccount?
    var client: ABSClient?
    var currentLibrary: Library?
    var libraries: [Library] = []
    var libraryRevision = UUID()
    var isOffline = false
    var isConnecting = false
    var isDemo = false
    var recoveryBusy = false
}
private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    var isEntered: Bool { lock.withLock { entered } }
    func wait() { lock.withLock { entered = true }; release.wait() }
}
private struct Reply: Sendable { let json: String; var status = 200; var gate: Gate? }
private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var count = 0
    private var unexpected = 0
    func install(_ replies: [Reply]) { lock.withLock { self.replies = replies; count = 0; unexpected = 0 } }
    func take(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            guard let url = request.url, url.scheme == "https", url.host == "library-statistics.fixture.test", request.httpMethod == "GET",
                  (url.path.hasPrefix("/compat/api/libraries/") && url.path.hasSuffix("/stats") && url.query == nil) || url.path.hasPrefix("/compat/api/items/"),
                  !replies.isEmpty else { unexpected += 1; throw Failure(message: "Unexpected HTTP") }
            count += 1; return replies.removeFirst()
        }
    }
    var requests: Int { lock.withLock { count } }
    var unexpectedRequests: Int { lock.withLock { unexpected } }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply
        do { reply = try Self.state.take(request) } catch { client?.urlProtocol(self, didFailWithError: error); return }
        DispatchQueue.global().async { [self] in
            reply.gate?.wait()
            guard !lock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
private let book = """
{"totalItems":12,"totalAuthors":7,"totalGenres":2,"totalDuration":12001.5,"totalSize":8589934593,"numAudioTracks":31,"authorsWithCount":[{"id":"author","name":"Author","count":6}],"genresWithCount":[{"genre":"Fiction","count":8},{"genre":"History","count":6}],"longestItems":[{"id":"long","title":"Long","duration":7200.25}],"largestItems":[{"id":"large","title":"Large","size":4294967297}]}
"""
private let podcast = """
{"totalItems":2,"totalGenres":0,"totalDuration":40,"totalSize":400,"numAudioTracks":3,"genresWithCount":[],"longestItems":[{"id":"show","title":"Show","duration":null}],"largestItems":[]}
"""
private let empty = """
{"totalItems":0,"totalAuthors":0,"totalGenres":0,"totalDuration":0,"totalSize":0,"numAudioTracks":0,"authorsWithCount":[],"genresWithCount":[],"longestItems":[],"largestItems":[]}
"""
@main private struct Smoke {
    @MainActor static func client(_ profile: ServerProfile) async -> ABSClient {
        let tokens = MemoryTokenStore()
        await tokens.save(.init(accessToken: "synthetic-statistics-token", userID: "user"), account: profile.id.uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ABSClient(profile: profile, session: URLSession(configuration: config), tokenStore: tokens)
    }
    @MainActor static func store() async -> AppStore {
        let value = AppStore(), profile = ServerProfile(name: "Fixture", baseURL: URL(string: "https://library-statistics.fixture.test/compat")!, serverVersion: "2.37.1")
        value.profile = profile; value.partition = .init(serverID: profile.id, userID: "user"); value.user = .init(id: "user", username: "Fixture", type: "admin")
        value.currentLibrary = .init(id: "library", name: "Fixture"); value.libraries = [value.currentLibrary!, .init(id: "other", name: "Other")]; value.client = await client(profile)
        return value
    }
    @MainActor static func load(_ model: LibraryStatisticsModel, _ store: AppStore) async {
        await model.load(store: store, library: store.currentLibrary!, expected: .init(store: store, library: store.currentLibrary!))
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(predicate(), "Timed out waiting for fixture boundary")
    }
    @MainActor static func run() async throws {
        let value = await store(), model = LibraryStatisticsModel(), library = value.currentLibrary!
        FixtureProtocol.state.install([.init(json: book)]); await load(model, value)
        let confirmed = model.statistics, timestamp = model.updatedAt
        try require(confirmed?.totalItems == 12 && confirmed?.totalSize == 8589934593 && confirmed?.genresWithCount.map(\.genre) == ["Fiction", "History"] && timestamp != nil && model.error == nil && model.isBound(to: value, library: library), "Loaded catalog fields/order failed")
        print("PASS statistics actual Model typed fields, order, source and timestamp")

        FixtureProtocol.state.install([.init(json: "{}", status: 503)]); await load(model, value)
        try require(model.statistics == confirmed && model.updatedAt == timestamp && model.error != nil && !model.isLoading, "Refresh lost confirmed data or error")
        FixtureProtocol.state.install([.init(json: book)]); await load(model, value)
        try require(model.error == nil && model.statistics == confirmed, "Retry did not clear error")
        print("PASS statistics refresh preserves confirmed snapshot and independent retry")

        for (json, count) in [(podcast, 2), (empty, 0)] {
            FixtureProtocol.state.install([.init(json: json)]); await load(model, value)
            try require(model.statistics?.totalItems == count && model.error == nil && !model.isLoading, "Null/empty loaded snapshot failed")
        }
        try require(model.statistics?.totalItems == 0, "Zero snapshot treated as absent")
        print("PASS statistics podcast null duration and empty loaded snapshot")

        let changes: [@MainActor (AppStore) -> Void] = [
            { $0.partition = .init(serverID: UUID(), userID: "user") }, { $0.user = .init(id: "other", username: "other", type: "admin") },
            { $0.user = .init(id: "user", username: "u", type: "user") }, { $0.user = .init(id: "user", username: "u", type: "admin", isActive: false) },
            { $0.currentLibrary = $0.libraries.last }, { $0.libraries = [] }, { $0.isOffline = true }, { $0.isConnecting = true },
            { $0.isDemo = true }, { $0.recoveryBusy = true }, { $0.profile?.serverVersion = "2.26.0" }, { $0.libraryRevision = UUID() },
            { $0.profile?.baseURL = URL(string: "https://another.fixture.test/compat")! }
        ]
        for change in changes {
            let scoped = await store(), scopedModel = LibraryStatisticsModel()
            FixtureProtocol.state.install([.init(json: book)]); await load(scopedModel, scoped)
            change(scoped)
            try require(!scopedModel.isBound(to: scoped, library: library), "Identity/state mutation exposed old statistics")
        }
        print("PASS statistics thirteen source, role, revision and availability boundaries hide old data synchronously")

        for role in ["admin", "root", "user"] {
            let scoped = await store(); scoped.user = .init(id: "user", username: "u", type: role)
            FixtureProtocol.state.install(role == "user" ? [] : [.init(json: book)])
            let scopedModel = LibraryStatisticsModel(); await load(scopedModel, scoped)
            try require((scopedModel.statistics != nil) == (role != "user") && FixtureProtocol.state.requests == (role == "user" ? 0 : 1), "Web role gate incorrect")
        }
        print("PASS statistics Web admin/root role gate independent of content-write permissions")

        FixtureProtocol.state.install([.init(json: book)]); await load(model, value)
        let expected = LibraryStatisticsSource(store: value, library: library)!
        let gate = Gate(); FixtureProtocol.state.install([.init(json: podcast, gate: gate), .init(json: book)])
        let old = Task { await model.load(store: value, library: library, expected: expected) }
        try await wait { gate.isEntered }
        value.libraryRevision = UUID(); await load(model, value); gate.release.signal(); await old.value
        try require(model.statistics?.totalItems == 12 && model.error == nil && model.isBound(to: value, library: library), "Late old revision overwrote winner")
        print("PASS statistics late old revision response cannot overwrite newer request")

        FixtureProtocol.state.install([])
        await model.load(store: value, library: library, expected: expected)
        await model.load(store: value, library: library, expected: nil)
        let alreadyCancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load(store: value, library: library, expected: .init(store: value, library: library)) }
        await alreadyCancelled.value
        try require(model.statistics?.totalItems == 12 && FixtureProtocol.state.requests == 0 && FixtureProtocol.state.unexpectedRequests == 0, "Old or cancelled entry altered winner")
        print("PASS statistics stale Source, stale nil Source and already-cancelled task reject at entry")

        let cancelGate = Gate(); FixtureProtocol.state.install([.init(json: podcast, gate: cancelGate)])
        let pending = Task { await load(model, value) }; try await wait { cancelGate.isEntered }; pending.cancel(); cancelGate.release.signal(); await pending.value
        try require(model.statistics?.totalItems == 12 && model.error == nil && !model.isLoading, "Caller cancellation published error or replacement")
        print("PASS statistics caller cancellation retains confirmed data without error")

        let clearGate = Gate(); FixtureProtocol.state.install([.init(json: podcast, gate: clearGate)])
        let clearing = Task { await load(model, value) }; try await wait { clearGate.isEntered }; model.cancel(); clearGate.release.signal(); await clearing.value
        try require(model.source == nil && model.statistics == nil && model.updatedAt == nil && model.error == nil && !model.isLoading, "Explicit cancel retained old snapshot")
        print("PASS statistics explicit cancel clears all old screen state")

        FixtureProtocol.state.install([.init(json: book)]); await load(model, value)
        value.client = await client(value.profile!)
        try require(!model.isBound(to: value, library: library), "Same account replacement client was treated as old client")
        FixtureProtocol.state.install([.init(json: book)]); await load(model, value)
        print("PASS statistics same-account replacement client invalidates binding")

        let proper = "{\"id\":\"long\",\"libraryId\":\"library\",\"mediaType\":\"book\",\"media\":{\"metadata\":{\"title\":\"Long\"}}}"
        FixtureProtocol.state.install([.init(json: proper)]); model.openItem(id: "long", store: value, library: library)
        try await wait { !model.isOpeningItem }
        try require(model.openedItem?.id == "long" && model.itemError == nil, "Rank item did not load through item authorization")
        FixtureProtocol.state.install([.init(json: proper.replacingOccurrences(of: "\"libraryId\":\"library\"", with: "\"libraryId\":\"other\""))]); model.openItem(id: "long", store: value, library: library)
        try await wait { !model.isOpeningItem }
        try require(model.openedItem == nil && model.itemError != nil, "Cross-library rank detail accepted")
        print("PASS statistics rank details use authenticated item lookup and validate returned library")

        let itemGate = Gate(); FixtureProtocol.state.install([.init(json: proper, gate: itemGate)])
        model.openItem(id: "long", store: value, library: library); try await wait { itemGate.isEntered }
        value.isOffline = true; itemGate.release.signal(); try await wait { !model.isOpeningItem }
        try require(model.openedItem == nil && model.itemError == nil, "Late item after source invalidation was published")
        model.cancel(); FixtureProtocol.state.install([]); model.openItem(id: "long", store: value, library: library)
        try require(FixtureProtocol.state.requests == 0 && FixtureProtocol.state.unexpectedRequests == 0, "Unbound rank action sent HTTP")
        print("PASS statistics late rank detail and invalid action are suppressed without request/error")
        print("PASS library statistics actual Model smoke: 12 groups; URLProtocol intercepted all HTTP; no native UI or real server writes")
    }
    @MainActor static func main() async {
        do { try await run() } catch let failure as Failure { print("FAIL statistics: " + failure.message); exit(1) }
        catch { print("FAIL statistics: isolated fixture error"); exit(1) }
    }
}
