// Compiles with the actual HomeModel. Only its AppStore dependencies are supplied here.
// All HTTP is intercepted, tokens are synthetic, and SQLite uses isolated temporary files.
import Foundation
import GRDB
import AudilseCore

@MainActor final class AppStore {
    var partition: AccountPartition?
    var currentLibrary: Library?
    var client: ABSClient?
    var database: ShelfDatabase?
    var user: UserAccount? = .init(id: "fixture-user", username: "fixture")
    var isOffline = false
    var isConnecting = false
    var libraryRevision = UUID()
    var progressByItem: [String: MediaProgress] = [:]
}

private struct SmokeFailure: Error { let reason: String }
private func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw SmokeFailure(reason: reason) }
}
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { didEnter } }
    func wait() { lock.withLock { didEnter = true }; release.wait() }
}
private struct Reply: Sendable {
    let status: Int
    let json: String
    var gate: Gate?
    init(_ json: String, status: Int = 200, gate: Gate? = nil) { self.json = json; self.status = status; self.gate = gate }
}
private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var paths: [String] = []
    private var failures = 0
    func install(_ replies: [Reply]) { lock.withLock { self.replies = replies; paths = []; failures = 0 } }
    func take(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            guard request.url?.host == "home.fixture.test", request.httpMethod == "GET",
                  request.url?.path.hasPrefix("/compat/api/libraries/") == true,
                  request.url?.path.hasSuffix("/personalized") == true, !replies.isEmpty else {
                failures += 1; throw SmokeFailure(reason: "Unexpected HTTP request")
            }
            paths.append(request.url!.path + "?" + (request.url!.query ?? ""))
            return replies.removeFirst()
        }
    }
    var requests: [String] { lock.withLock { paths } }
    var unexpectedRequests: Int { lock.withLock { failures } }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply
        do { reply = try Self.state.take(request) }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        DispatchQueue.global().async { [self] in
            reply.gate?.wait()
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

private func itemJSON(_ id: String, podcast: Bool = false, episode: String? = nil) -> String {
    let recent = episode.map { ",\"recentEpisode\":{\"id\":\"\($0)\",\"title\":\"Episode \($0)\",\"duration\":40}" } ?? ""
    return "{\"id\":\"\(id)\",\"libraryId\":\"A\",\"mediaType\":\"\(podcast ? "podcast" : "book")\",\"media\":{\"numTracks\":1,\"numEpisodes\":2,\"duration\":40,\"metadata\":{\"title\":\"\(id)\"}}\(recent)}"
}
private func shelvesJSON(_ marker: String = "base") -> String {
    """
    [
      {"id":"continue-listening","label":"Continue","type":"book","total":18,"entities":[\(itemJSON(marker + "-z")),\(itemJSON(marker + "-a"))]},
      {"id":"newest-episodes","label":"Episodes","type":"episode","total":2,"entities":[\(itemJSON(marker + "-show", podcast:true, episode:"e2")),\(itemJSON(marker + "-show", podcast:true, episode:"e1"))]},
      {"id":"recently-added","label":"Podcasts","type":"podcast","total":1,"entities":[\(itemJSON(marker + "-podcast", podcast:true))]},
      {"id":"continue-series","label":"Series","type":"series","total":1,"entities":[{"id":"\(marker)-series","name":"Fixture series","books":[\(itemJSON(marker + "-series-book"))]}]},
      {"id":"newest-authors","label":"Authors","type":"authors","total":1,"entities":[{"id":"\(marker)-author","name":"Fixture author","numBooks":7}]},
      {"id":"future-shelf","label":"Future","type":"future-type","total":1,"entities":[{"id":"future","opaque":[true,17,{"nested":"kept"}]}]}
    ]
    """
}
private func expected(_ marker: String = "base") throws -> [PersonalizedLibraryShelf] {
    try JSONDecoder().decode([PersonalizedLibraryShelf].self, from: Data(shelvesJSON(marker).utf8))
}
private func cacheKey(_ libraryID: String, limit: Int = 10) -> String { "home.v1.\(libraryID.utf8.count):\(libraryID).\(limit)" }

@main private struct HomeSmoke {
    @MainActor static func makeClient() async -> ABSClient {
        let profile = ServerProfile(name: "Home fixture", baseURL: URL(string: "https://home.fixture.test/compat")!, serverVersion: "2.37.1")
        let tokens = MemoryTokenStore()
        await tokens.save(.init(accessToken: "synthetic-off-network-token", userID: "fixture-user"), account: profile.id.uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ABSClient(profile: profile, session: URLSession(configuration: config), tokenStore: tokens)
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(condition(), "Fixture request did not reach gate")
    }
    @MainActor static func restore() async throws {
        let args = CommandLine.arguments
        try require(args.count == 5, "Invalid isolated restore arguments")
        guard let serverID = UUID(uuidString: args[3]) else { throw SmokeFailure(reason: "Invalid fixture partition") }
        let store = AppStore(), library = Library(id: "A", name: "A")
        store.partition = .init(serverID: serverID, userID: args[4]); store.currentLibrary = library
        store.client = await makeClient(); store.isOffline = true
        store.database = try ShelfDatabase(path: URL(fileURLWithPath: args[2]))
        FixtureProtocol.state.install([])
        let model = HomeModel(); await model.load(store: store, library: library)
        try require(model.shelves == expected() && model.usesCache && model.error == nil && model.cacheError == nil, "Independent-process SQLite restoration changed typed shelves/order")
        try require(model.localResumeByID["base-z"]?.currentTime == 17 && model.localResumeByID["base-show:e2"]?.currentTime == 23 && model.localResumeByID["base-series-book"]?.currentTime == 29, "Independent-process offline resumes were not restored outside Store items")
        try require(model.localResumeByID["base-show:e1"] == nil && model.localResumeByID.count == 3, "Episode resumes leaked between episodes")
        try require(FixtureProtocol.state.unexpectedRequests == 0, "Offline restoration attempted HTTP")
        print("PASS home fresh-process offline typed SQLite and book/episode/series resume restoration")
    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "--restore" { try await restore() }
            else { try await run() }
        } catch let failure as SmokeFailure { print("FAIL home: " + failure.reason); exit(1) }
        catch { print("FAIL home: unexpected isolated fixture error"); exit(1) }
    }
    @MainActor static func run() async throws {
        try require(CommandLine.arguments.count == 2, "Pass an isolated work directory")
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let databasePath = work.appendingPathComponent("home-" + UUID().uuidString + ".sqlite")
        let database = try ShelfDatabase(path: databasePath)
        let store = AppStore(), library = Library(id: "A", name: "A"), libraryB = Library(id: "B", name: "B")
        let partition = AccountPartition(serverID: UUID(), userID: "fixture-user")
        store.partition = partition; store.currentLibrary = library; store.client = await makeClient(); store.database = database
        let model = HomeModel()
        FixtureProtocol.state.install([Reply(shelvesJSON())])
        await model.load(store: store, library: library)
        try require(model.shelves == expected() && model.isBound(to: store, libraryID: library.id) && !model.usesCache && model.updatedAt != nil && model.error == nil && model.cacheError == nil, "Online typed shelf/order load failed")
        let path = FixtureProtocol.state.requests.first ?? ""
        let query = URLComponents(string: "https://home.fixture.test" + path)?.queryItems ?? []
        try require(FixtureProtocol.state.requests.count == 1 && query.first(where: { $0.name == "limit" })?.value == "10", "Personalized library query lost proxy base path or limit")
        store.progressByItem["base-z"] = .init(libraryItemId: "base-z", isFinished: true, lastUpdate: 99_999)
        try require(model.shelves == expected(), "Local completion reordered or removed server recommendations")
        print("PASS home complete heterogeneous shelves, server ordering, distinct episodes and local-progress independence")

        try await database.saveResume(.init(libraryItemId: "base-z", currentTime: 17), partition: partition)
        try await database.saveResume(.init(libraryItemId: "base-show", episodeId: "e2", currentTime: 23), partition: partition)
        try await database.saveResume(.init(libraryItemId: "base-series-book", currentTime: 29), partition: partition)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let restoreArguments = ["--restore", databasePath.path, partition.serverID.uuidString, partition.userID]
        let status = try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = restoreArguments
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }.value
        try require(status == 0, "Independent offline restore process failed")

        store.isOffline = true
        FixtureProtocol.state.install([])
        for scenario in ["account", "server", "library", "limit"] {
            let isolated = HomeModel()
            store.partition = scenario == "account" ? .init(serverID: partition.serverID, userID: "other-user") : (scenario == "server" ? .init(serverID: UUID(), userID: partition.userID) : partition)
            store.currentLibrary = scenario == "library" ? libraryB : library
            await isolated.load(store: store, library: store.currentLibrary!, limit: scenario == "limit" ? 11 : 10)
            try require(isolated.shelves.isEmpty && isolated.localResumeByID.isEmpty && isolated.error != nil && !isolated.isLoading, "Offline cache crossed \(scenario) boundary")
        }
        try require(FixtureProtocol.state.unexpectedRequests == 0, "Offline isolation attempted HTTP")
        print("PASS home offline account/server/library/limit isolation and missing-cache errors")

        store.partition = partition; store.currentLibrary = library; store.isOffline = false
        FixtureProtocol.state.install([Reply("{}", status: 503)])
        await model.load(store: store, library: library)
        try require(model.shelves == expected() && model.usesCache && model.error != nil && !model.isLoading, "Online failure discarded same-account cache or its visible error")
        try require(model.localResumeByID.isEmpty, "Online load retained offline resume overlay")
        print("PASS home failed refresh retains cache with visible error and clears offline-only progress")

        let refreshGate = Gate()
        FixtureProtocol.state.install([Reply(shelvesJSON("refresh"), gate: refreshGate)])
        let refresh = Task { await model.load(store: store, library: library) }
        try await waitFor { refreshGate.entered }
        try require(model.isLoading && model.shelves == expected() && model.error == nil, "Same-source refresh flashed an empty page")
        refreshGate.release.signal(); await refresh.value
        try require(model.shelves == expected("refresh") && !model.usesCache && model.error == nil && !model.isLoading, "Successful refresh failed to replace cache")
        print("PASS home refresh preserves visible rows while loading and replaces them on success")

        let changedGate = Gate()
        store.partition = .init(serverID: partition.serverID, userID: "changed-user")
        FixtureProtocol.state.install([Reply(shelvesJSON("changed"), gate: changedGate)])
        let changed = Task { await model.load(store: store, library: library) }
        try await waitFor { changedGate.entered }
        try require(model.shelves.isEmpty && model.localResumeByID.isEmpty && model.isLoading && model.isBound(to: store, libraryID: library.id), "Account transition retained old-account rows while loading")
        changedGate.release.signal(); await changed.value
        print("PASS home account transition clears old rows before awaiting its replacement")

        for scenario in ["account", "client", "library", "offline", "revision", "connecting", "inactive", "cancel", "explicit-cancel", "newer-load", "newer-load-failure"] {
            store.partition = .init(serverID: UUID(), userID: "delayed-" + scenario); store.client = await makeClient()
            store.currentLibrary = library; store.isOffline = false; store.isConnecting = false; store.user = .init(id: "fixture-user", username: "fixture")
            let isolated = HomeModel(), gate = Gate()
            FixtureProtocol.state.install([Reply(shelvesJSON("obsolete"), status: scenario == "newer-load-failure" ? 503 : 200, gate: gate)])
            let obsolete = Task { await isolated.load(store: store, library: library) }
            try await waitFor { gate.entered }
            switch scenario {
            case "account": store.partition = .init(serverID: UUID(), userID: "other-user")
            case "client": store.client = await makeClient()
            case "library": store.currentLibrary = libraryB
            case "offline": store.isOffline = true
            case "revision": store.libraryRevision = UUID()
            case "connecting": store.isConnecting = true
            case "inactive": store.user?.isActive = false
            case "cancel": obsolete.cancel()
            case "explicit-cancel": isolated.cancel()
            default:
                FixtureProtocol.state.install([Reply(shelvesJSON("winner"))])
                await isolated.load(store: store, library: library)
            }
            gate.release.signal(); await obsolete.value
            try require(isolated.shelves == (scenario.hasPrefix("newer-load") ? expected("winner") : []) && isolated.error == nil && !isolated.isLoading, "Delayed \(scenario) response replaced winning state")
            if !["cancel", "newer-load", "newer-load-failure"].contains(scenario) { try require(!isolated.isBound(to: store, libraryID: library.id), "Obsolete \(scenario) binding remained renderable") }
            print("PASS home delayed \(scenario) isolation")
        }

        store.partition = partition; store.client = await makeClient(); store.currentLibrary = library
        store.isOffline = false; store.isConnecting = false; store.user = .init(id: "fixture-user", username: "fixture")
        let activeGate = Gate(), active = HomeModel()
        FixtureProtocol.state.install([Reply(shelvesJSON("active"), gate: activeGate)])
        let winning = Task { await active.load(store: store, library: library) }
        try await waitFor { activeGate.entered }
        let cancelledAtEntry = Task { await active.load(store: store, library: library) }
        cancelledAtEntry.cancel(); await cancelledAtEntry.value
        try require(active.isLoading && FixtureProtocol.state.requests.count == 1, "Cancelled-at-entry task stole the active generation")
        activeGate.release.signal(); await winning.value
        try require(active.shelves == expected("active") && !active.isLoading, "Cancelled-at-entry task discarded winning response")
        store.isConnecting = true
        FixtureProtocol.state.install([])
        await active.load(store: store, library: library)
        try require(!active.isBound(to: store, libraryID: library.id) && FixtureProtocol.state.unexpectedRequests == 0, "Connecting state admitted a load or exposed old rows")
        store.isConnecting = false
        print("PASS home cancelled-entry generation and connecting-entry guards")

        let brokenPath = work.appendingPathComponent("broken-" + UUID().uuidString + ".sqlite")
        let broken = try ShelfDatabase(path: brokenPath)
        let raw = try DatabaseQueue(path: brokenPath.path)
        try await raw.write { try $0.execute(sql: "DROP TABLE cachedValue") }
        store.database = broken
        FixtureProtocol.state.install([Reply(shelvesJSON("live"))])
        await active.load(store: store, library: library)
        try require(active.shelves == expected("live") && active.cacheError != nil && active.error == nil && !active.usesCache, "SQLite read/write failure discarded live shelves")
        print("PASS home cache read/write failures remain nonfatal to live results")

        store.database = database
        FixtureProtocol.state.install([Reply("[]")])
        await active.load(store: store, library: library)
        try require(active.shelves.isEmpty && active.error == nil && active.updatedAt != nil && !active.usesCache, "Valid empty personalized response became an error")
        store.isOffline = true; FixtureProtocol.state.install([])
        let empty = HomeModel(); await empty.load(store: store, library: library)
        try require(empty.shelves.isEmpty && empty.error == nil && empty.usesCache && empty.updatedAt != nil && FixtureProtocol.state.unexpectedRequests == 0, "Persisted empty shelf response was mistaken for missing cache")
        print("PASS home empty-library online and fresh-model offline restoration")
    }
}
