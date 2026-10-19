// Uses the actual LibrarySearchModel and SQLite. AppStore supplies identity fields only.
// Every URLSession request is intercepted; fixtures never reach the network or use real credentials.
import Foundation
import GRDB
import ShelfCore

enum ShelfRoute: Hashable { case home, library(String), search, downloads }
@MainActor final class AppStore {
    var profile: ServerProfile?
    var isDemo = false
    var partition: AccountPartition?
    var currentLibrary: Library?
    var libraries: [Library] = []
    var route: ShelfRoute = .search
    var search = ""
    var client: ABSClient?
    var database: ShelfDatabase?
    var user: UserAccount? = .init(id: "fixture-user", username: "fixture")
    var isOffline = false
    var isConnecting = false
    var libraryRevision = UUID()
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
private struct RequestKey: Hashable, Sendable {
    let library: String
    let query: String
    let limit: Int
    init(_ library: String, _ query: String, _ limit: Int = 12) {
        self.library = library; self.query = query; self.limit = limit
    }
    init(_ query: String, _ limit: Int = 12) { self.init("A", query, limit) }
}
private struct Reply: Sendable {
    let status: Int
    let json: String
    let gate: Gate?
    init(_ json: String = "{}", status: Int = 200, gate: Gate? = nil) {
        self.json = json; self.status = status; self.gate = gate
    }
}
private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [RequestKey: Reply] = [:]
    private var paths: [RequestKey] = []
    private var failures = 0
    private var active = 0
    private var maximum = 0
    func install(_ replies: [RequestKey: Reply]) throws {
        try lock.withLock {
            try require(active == 0, "Previous fixture HTTP did not finish")
            self.replies = replies; paths = []; failures = 0; maximum = 0
        }
    }
    func take(_ request: URLRequest) throws -> Reply {
        try lock.withLock {
            guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.host == "search-model.fixture.test", parts.scheme == "https", request.httpMethod == "GET",
                  url.path.hasPrefix("/compat/api/libraries/"), url.path.hasSuffix("/search") else {
                failures += 1; throw SmokeFailure(reason: "Unexpected HTTP boundary")
            }
            let components = url.path.split(separator: "/")
            let queryItems = parts.queryItems ?? []
            guard components.count == 5, queryItems.count == 2,
                  let query = queryItems.first(where: { $0.name == "q" })?.value,
                  let limitText = queryItems.first(where: { $0.name == "limit" })?.value,
                  let limit = Int(limitText) else {
                failures += 1; throw SmokeFailure(reason: "Search invented query parameters or lost base path")
            }
            let key = RequestKey(String(components[3]), query, limit)
            guard let reply = replies.removeValue(forKey: key) else {
                failures += 1; throw SmokeFailure(reason: "Unexpected library/query/limit or repeated request")
            }
            paths.append(key); active += 1; maximum = max(maximum, active)
            return reply
        }
    }
    func finish() { lock.withLock { active -= 1 } }
    var requests: [RequestKey] { lock.withLock { paths } }
    var unexpected: Int { lock.withLock { failures } }
    var activeCount: Int { lock.withLock { active } }
    var peak: Int { lock.withLock { maximum } }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    private let lock = NSLock()
    private var stopped = false
    private var counted = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply
        do {
            reply = try Self.state.take(request)
            let alreadyStopped = lock.withLock { if stopped { return true }; counted = true; return false }
            if alreadyStopped { Self.state.finish(); return }
        }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        DispatchQueue.global().async { [self] in
            reply.gate?.wait()
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
            finish(); client?.urlProtocolDidFinishLoading(self)
        }
    }
    private func finish() {
        let decrement = lock.withLock { let value = counted; counted = false; return value }
        if decrement { Self.state.finish() }
    }
    override func stopLoading() { lock.withLock { stopped = true }; finish() }
}

private func item(_ id: String, library: String = "A", episode: String? = nil) -> String {
    let recent = episode.map { ",\"recentEpisode\":{\"id\":\"\($0)\",\"title\":\"Episode \($0)\",\"duration\":40}" } ?? ""
    return "{\"id\":\"\(id)\",\"libraryId\":\"\(library)\",\"mediaType\":\"\(episode == nil ? "book" : "podcast")\",\"media\":{\"numTracks\":1,\"metadata\":{\"title\":\"\(id)\"}}\(recent)}"
}
private func payload(_ marker: String, library: String = "A") -> String {
    """
    {"book":[{"libraryItem":\(item(marker, library:library))}],
     "podcast":[{"libraryItem":\(item(marker+"-podcast",library:library))}],
     "episodes":[{"libraryItem":\(item(marker+"-show",library:library,episode:"e1"))},{"libraryItem":\(item(marker+"-show",library:library,episode:"e2"))}],
     "authors":[{"id":"author","name":"Author","numBooks":3}],
     "series":[{"series":{"id":"series","name":"Series"},"books":[\(item(marker+"-series",library:library))]}],
     "tags":[{"name":"tag","numItems":5}],"genres":[{"name":"genre","numItems":4}],
     "narrators":[{"name":"Narrator","numBooks":6}]}
    """
}
private func cacheKey(_ library: String, _ query: String, _ limit: Int = 12) -> String {
    "search.v1.\(library.utf8.count):\(library).\(query.utf8.count):\(query).\(limit)"
}
private func cacheKey(_ query: String) -> String { cacheKey("A", query) }

@main private struct LibrarySearchSmoke {
    @MainActor static func makeClient() async -> ABSClient {
        let profile = ServerProfile(name: "Search fixture", baseURL: URL(string: "https://search-model.fixture.test/compat")!, serverVersion: "2.37.1")
        let tokens = MemoryTokenStore()
        await tokens.save(.init(accessToken: "synthetic-off-network-token", userID: "fixture-user"), account: profile.id.uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ABSClient(profile: profile, session: URLSession(configuration: config), tokenStore: tokens)
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(condition(), "Fixture did not reach expected async boundary")
    }
    @MainActor static func load(_ model: LibrarySearchModel, _ store: AppStore) async {
        await model.load(store: store, source: .init(store: store, scope: model.scope, limit: model.limit))
    }
    @MainActor static func restore() async throws {
        let args = CommandLine.arguments
        try require(args.count == 5, "Invalid offline restore arguments")
        guard let serverID = UUID(uuidString: args[3]) else { throw SmokeFailure(reason: "Invalid isolated partition") }
        let store = AppStore(); store.partition = .init(serverID: serverID, userID: args[4])
        store.currentLibrary = .init(id: "A", name: "A"); store.libraries = [store.currentLibrary!]
        store.database = try ShelfDatabase(path: URL(fileURLWithPath: args[2])); store.isOffline = true; store.search = "unicode + 阅"
        try FixtureProtocol.state.install([:])
        let model = LibrarySearchModel(); await load(model, store)
        try require(model.sections.count == 1 && model.sections[0].state == .cached && model.sections[0].usesCache && model.sections[0].updatedAt != nil, "Offline fresh process did not restore exact cached query")
        let response = model.sections[0].response
        let expected = try JSONDecoder().decode(LibrarySearchResponse.self, from: Data(payload("book-A").utf8))
        try require(response == expected && response?.episodes[0].id != response?.episodes[1].id, "Offline cache changed categories, nested entities or episode identity")
        try require(FixtureProtocol.state.requests.isEmpty && FixtureProtocol.state.unexpected == 0, "Offline restoration attempted HTTP")
        print("PASS search fresh-process exact query SQLite restoration and heterogeneous categories")
    }
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "--restore" { try await restore() }
            else { try await run() }
        } catch let failure as SmokeFailure { print("FAIL search: " + failure.reason); exit(1) }
        catch { print("FAIL search: unexpected isolated fixture error: \(type(of:error))"); exit(1) }
    }
    @MainActor static func run() async throws {
        try require(CommandLine.arguments.count == 2, "Pass an isolated work directory")
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let path = work.appendingPathComponent("search-" + UUID().uuidString + ".sqlite")
        let database = try ShelfDatabase(path: path), store = AppStore()
        let partition = AccountPartition(serverID: UUID(), userID: "fixture-user")
        let libraries = ["A", "B", "C", "D", "E"].map { Library(id: $0, name: $0) }
        store.partition = partition; store.libraries = libraries; store.currentLibrary = libraries[0]
        store.database = database; store.client = await makeClient(); store.search = "  unicode + 阅  "
        let model = LibrarySearchModel(); model.scope = .allLibraries
        let a = Gate(), b = Gate(), c = Gate(), d = Gate(), query = "unicode + 阅"
        try FixtureProtocol.state.install([
            .init("A",query): .init(payload("book-A"),gate:a), .init("B",query): .init(payload("book-B",library:"B"),gate:b),
            .init("C",query): .init(status:503,gate:c), .init("D",query): .init(gate:d),
            .init("E",query): .init(payload("book-E",library:"E"))])
        let loading = Task { await load(model, store) }
        try await waitFor { a.entered && b.entered && c.entered }
        try require(FixtureProtocol.state.requests.count == 3 && FixtureProtocol.state.peak == 3 && model.sections.map(\.id) == ["A","B","C","D","E"], "Initial bounded worker pool or server library order failed")
        b.release.signal(); try await waitFor { d.entered && model.sections[1].state == .loaded }
        try require(model.isLoading && model.sections[0].state == .loading && model.sections[2].state == .loading && model.sections[1].response?.books.first?.libraryItem.item.id == "book-B", "Fast library did not publish independently of slow libraries")
        d.release.signal(); try await waitFor { model.sections[4].state == .loaded }
        a.release.signal(); c.release.signal(); await loading.value
        try require(FixtureProtocol.state.peak == 3 && FixtureProtocol.state.requests.count == 5 && FixtureProtocol.state.unexpected == 0, "Requests exceeded concurrency limit, repeated a library or invented pagination")
        try require(model.sections.map(\.state) == [.loaded,.loaded,.failed,.loaded,.loaded] && model.sections[2].error != nil && model.sections[3].response == .init(), "Partial failure or confirmed empty results cleared unrelated successful libraries")
        let response = model.sections[0].response!
        try require(response.books.count == 1 && response.podcasts.count == 1 && response.episodes.count == 2 && response.authors.count == 1 && response.series.count == 1 && response.tags.count == 1 && response.genres.count == 1 && response.narrators.count == 1 && response.episodes[0].id != response.episodes[1].id, "Actual Model lost one of eight categories or merged episodes")
        print("PASS search maximum three concurrent requests, progressive partial publication and server library order")
        print("PASS search all eight typed categories, distinct episode identities, partial 503 and confirmed empty")

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let restoreArguments = ["--restore",path.path,partition.serverID.uuidString,partition.userID]
        let status = try await Task.detached {
            let process = Process(); process.executableURL = executable; process.arguments = restoreArguments
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }.value
        try require(status == 0, "Fresh process cached search restoration failed")

        store.isOffline = true; model.scope = .currentLibrary; store.search = query
        try FixtureProtocol.state.install([:]); await load(model,store)
        try require(model.sections[0].state == .cached && model.sections[0].response?.books.first?.libraryItem.item.id == "book-A", "Online/offline cache did not use identical query")
        for boundary in ["query","limit","library","account","server"] {
            store.search = boundary == "query" ? "unvisited" : query
            model.limit = boundary == "limit" ? 24 : 12
            store.currentLibrary = boundary == "library" ? libraries[2] : libraries[0]
            store.partition = boundary == "account" ? .init(serverID:partition.serverID,userID:"other") : (boundary == "server" ? .init(serverID:UUID(),userID:partition.userID) : partition)
            await load(model,store)
            try require(model.sections.count == 1 && model.sections[0].state == .missingCache && model.sections[0].response == nil && model.sections[0].error == nil, "Missing cache crossed \(boundary) boundary or became confirmed empty")
        }
        try require(FixtureProtocol.state.requests.isEmpty && FixtureProtocol.state.unexpected == 0, "Offline isolation attempted HTTP")
        print("PASS search offline query/limit/library/account/server isolation, missing cache is not empty results")

        store.partition = partition; store.currentLibrary = libraries[3]; store.search = query; model.limit = 12
        await load(model,store)
        try require(model.sections.count == 1 && model.sections[0].state == .cached && model.sections[0].response == .init() && model.sections[0].usesCache && model.sections[0].error == nil && FixtureProtocol.state.unexpected == 0, "Cached confirmed empty became missing cache")
        print("PASS search cached confirmed empty remains distinct from absent query cache")

        store.partition = partition; store.currentLibrary = libraries[0]; store.isOffline = false; store.search = "prefix"; model.limit = 12
        try FixtureProtocol.state.install([.init("prefix",12):.init(payload("prefix12")),.init("prefix",60):.init(payload("prefix60"))])
        await load(model,store); model.limit = 60
        try require(!model.isBound(to:store), "Changed prefix limit left stale action bound before load")
        await load(model,store)
        try require(model.sections[0].response?.books.map { $0.libraryItem.item.id } == ["prefix60"] && FixtureProtocol.state.requests.map(\.limit) == [12,60], "Larger per-category prefix appended fake pages instead of replacing")
        model.limit = 999; store.search = "bounded"
        try FixtureProtocol.state.install([.init("bounded",500):.init()]); await load(model,store)
        try require(model.source?.limit == 500 && FixtureProtocol.state.requests.first?.limit == 500, "Per-category limit exceeded 500")
        model.limit = 0; store.search = "minimum"
        try FixtureProtocol.state.install([.init("minimum",1):.init()]); await load(model,store)
        try require(model.source?.limit == 1 && FixtureProtocol.state.requests.first?.limit == 1, "Per-category limit accepted zero")
        print("PASS search query prefix replacement, immediately invalidated option bindings and bounded limits")

        model.limit = 12; store.search = "   \n  "
        try FixtureProtocol.state.install([:]); await load(model,store)
        try require(model.sections.isEmpty && !model.isLoading && model.error == nil && model.source?.query == "" && FixtureProtocol.state.unexpected == 0, "Empty query sent request or retained old result")
        store.search = "one"; store.currentLibrary = libraries[1]; store.libraries = [libraries[0],libraries[1],libraries[1]]
        try FixtureProtocol.state.install([.init("B","one"):.init(payload("only-B",library:"B"))]); await load(model,store)
        try require(model.sections.map(\.id) == ["B"] && FixtureProtocol.state.requests.map(\.library) == ["B"], "Current-library scope searched unrelated or duplicate libraries")
        model.scope = .allLibraries
        try require(!model.isBound(to:store), "Scope change left old results actionable before task began")
        store.libraries = [libraries[1],libraries[0],libraries[1]]; store.search = "ordered"
        try FixtureProtocol.state.install([.init("B","ordered"):.init(),.init("A","ordered"):.init()]); await load(model,store)
        try require(model.sections.map(\.id) == ["B","A"], "All-library scope lost server order or repeated duplicate IDs")
        print("PASS search empty query, exact current scope, all-library duplicate identity and scope invalidation")

        // Every identity change invalidates actions immediately and suppresses late responses.
        model.scope = .currentLibrary; store.currentLibrary = libraries[0]; store.libraries = libraries
        for boundary in ["account","client","database","libraries","currentLibrary","revision","offline","route","query","active","connecting","scope","limit"] {
            let originalClient = store.client, originalDatabase = store.database
            let blocked = Gate(); store.search = "late-" + boundary
            let expectedSource = LibrarySearchSource(store:store,scope:model.scope,limit:model.limit)
            try FixtureProtocol.state.install([.init(store.search):.init(payload("stale-"+boundary),gate:blocked)])
            let task = Task { await model.load(store:store,source:expectedSource) }
            try await waitFor { blocked.entered }
            switch boundary {
            case "account": store.partition = .init(serverID:partition.serverID,userID:"other")
            case "client": store.client = await makeClient()
            case "database": store.database = try ShelfDatabase(path:work.appendingPathComponent("other-"+UUID().uuidString+".sqlite"))
            case "libraries": store.libraries.reverse()
            case "currentLibrary": store.currentLibrary = libraries[1]
            case "revision": store.libraryRevision = UUID()
            case "offline": store.isOffline = true
            case "route": store.route = .downloads
            case "query": store.search = "different"
            case "active": store.user = .init(id:"fixture-user",username:"fixture",isActive:false)
            case "connecting": store.isConnecting = true
            case "scope": model.scope = .allLibraries
            default: model.limit = 24
            }
            try require(!model.isBound(to:store,source:expectedSource), "Stale action stayed bound across \(boundary)")
            blocked.release.signal(); await task.value
            try require(model.sections.allSatisfy { $0.response == nil } && !model.isLoading, "Late response published across \(boundary)")
            store.partition = partition; store.client = originalClient; store.database = originalDatabase
            store.libraries = libraries; store.currentLibrary = libraries[0]; store.isOffline = false; store.route = .search
            store.user = .init(id:"fixture-user",username:"fixture"); store.isConnecting = false
            model.scope = .currentLibrary; model.limit = 12
        }
        print("PASS search thirteen late-response and stale-action identity boundaries")

        let oldGate = Gate(), winnerGate = Gate(); store.search = "old"
        let oldSource = LibrarySearchSource(store:store,scope:model.scope,limit:model.limit)
        try FixtureProtocol.state.install([.init("old"):.init(payload("old"),gate:oldGate),.init("winner"):.init(payload("winner"),gate:winnerGate)])
        let oldTask = Task { await model.load(store:store,source:oldSource) }; try await waitFor { oldGate.entered }
        store.search = "winner"
        let winningSource = LibrarySearchSource(store:store,scope:model.scope,limit:model.limit)
        let winner = Task { await model.load(store:store,source:winningSource) }; try await waitFor { winnerGate.entered }
        // Already-cancelled old task enters after winner and must not cancel it/change generation.
        let cancelledEntry = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load(store:store,source:winningSource) }
        await cancelledEntry.value
        try require(model.source == winningSource && model.isLoading && model.isBound(to:store), "Cancelled task entry replaced active winner")
        await model.load(store:store,source:oldSource)
        try require(model.source == winningSource && model.isLoading && model.isBound(to:store), "Obsolete source entry replaced active winner")
        oldTask.cancel(); oldGate.release.signal(); await oldTask.value
        try require(model.source == winningSource && model.isLoading, "Old cancelled defer cleared newer load")
        winnerGate.release.signal(); await winner.value
        try require(model.sections[0].response?.books.first?.libraryItem.item.id == "winner" && !model.isLoading && FixtureProtocol.state.unexpected == 0, "Late old generation replaced winner")
        print("PASS search overlapping loads, cancelled task entry and old cancellation cannot erase winner")

        for explicitCancel in [false,true] {
            store.search = explicitCancel ? "explicit-cancel" : "caller-cancel"
            let gate = Gate()
            try FixtureProtocol.state.install([.init(store.search):.init(payload("must-not-publish"),gate:gate)])
            let task = Task { await load(model,store) }; try await waitFor { gate.entered }
            if explicitCancel { model.cancel() } else { task.cancel() }
            try await waitFor { !model.isLoading }
            try require(model.source == nil && model.sections.isEmpty && model.error == nil, "Cancellation retained actionable loading result")
            gate.release.signal(); await task.value
            try require(model.source == nil && model.sections.isEmpty && FixtureProtocol.state.activeCount == 0, "Cancelled request leaked or published after release")
        }
        print("PASS search caller cancellation and explicit close cancel URLSession and clear actionable state")

        store.search = query
        try FixtureProtocol.state.install([.init(query):.init(status:503)]); await load(model,store)
        try require(model.sections[0].state == .cached && model.sections[0].usesCache && model.sections[0].error != nil && model.sections[0].response?.books.first?.libraryItem.item.id == "book-A", "Online refresh failure erased known cached results or concealed error")
        print("PASS search cached fallback remains labelled with independent online failure")

        let queue = try DatabaseQueue(path:path.path)
        try await queue.write { db in
            try db.execute(sql:"UPDATE cachedValue SET payload=? WHERE serverID=? AND userID=? AND key=?", arguments:[Data("invalid-cache".utf8),partition.serverID.uuidString,partition.userID,cacheKey(query)])
        }
        store.isOffline = true; try FixtureProtocol.state.install([:]); await load(model,store)
        try require(model.sections[0].state == .failed && model.sections[0].response == nil && model.sections[0].cacheError != nil, "Unreadable offline cache became no-results")
        store.isOffline = false; try FixtureProtocol.state.install([.init(query):.init(payload("recovered"))]); await load(model,store)
        try require(model.sections[0].state == .loaded && model.sections[0].cacheError != nil && model.sections[0].response?.books.first?.libraryItem.item.id == "recovered", "Cache decode failure prevented live results")
        print("PASS search corrupt cache is transparent offline and nonfatal online")

        try await queue.write { db in try db.execute(sql:"CREATE TRIGGER blockSearchCache BEFORE INSERT ON cachedValue BEGIN SELECT RAISE(ABORT,'synthetic cache write failure'); END") }
        store.search = "write-failure"; try FixtureProtocol.state.install([.init(store.search):.init(payload("live-despite-disk"))]); await load(model,store)
        try require(model.sections[0].state == .loaded && model.sections[0].response?.books.first?.libraryItem.item.id == "live-despite-disk" && model.sections[0].cacheError != nil && model.sections[0].error == nil, "Cache write failure cleared confirmed live results")
        try await queue.write { db in try db.execute(sql:"DROP TRIGGER blockSearchCache") }
        print("PASS search real SQLite write failure preserves live results and reports cache error")

        store.database = nil; store.isOffline = true; store.search = "no-database"
        try FixtureProtocol.state.install([:]); await load(model,store)
        try require(model.sections[0].state == .missingCache && model.sections[0].response == nil && FixtureProtocol.state.unexpected == 0, "Missing offline database was treated as empty matches or queried online")
        store.isOffline = false; store.client = nil; await load(model,store)
        try require(model.sections[0].state == .failed && model.error != nil, "Missing online client was silently accepted")
        store.client = await makeClient(); store.libraries = []; await load(model,store)
        try require(model.sections.isEmpty && model.error != nil && !model.isLoading, "Missing accessible libraries was silently accepted")
        print("PASS search missing database/client/library states remain explicit without network leakage")
        print("PASS search summary: actual Model, intercepted HTTP only, temporary SQLite; no native UI or production-server claim")
    }
}
