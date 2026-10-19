// Compiles with the real LibraryBrowserModel.swift and a matching ShelfCore archive.
// The AppStore below only supplies dependencies; no production model logic is copied.
// Every HTTP request is intercepted. SQLite and preferences use isolated fixture storage.
import Foundation
import ShelfCore

@MainActor final class AppStore {
    var profile: ServerProfile?
    var isDemo = false
    var isConnecting = false
    var partition: AccountPartition?
    var currentLibrary: Library?
    var client: ABSClient?
    var user: UserAccount? = .init(id: "fixture-user", username: "fixture")
    var database: ShelfDatabase?
    var isOffline = false
    var libraryRevision = UUID()
    var progressByItem: [String: MediaProgress] = [:]
}
private struct FixtureFailure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
private func check(_ condition: Bool, _ message: String) throws { if !condition { throw FixtureFailure(message: message) } }
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { didEnter } }
    func wait() { lock.withLock { didEnter = true }; release.wait() }
}
private struct Plan: Sendable { let json: String; var gate: Gate? = nil }
private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [Plan] = []
    private var paths: [String] = []
    func install(_ value: [Plan]) { lock.withLock { plans = value; paths = [] } }
    func take(_ request: URLRequest) throws -> Plan {
        try lock.withLock {
            try check(request.url?.host == "library.fixture.test" && request.httpMethod == "GET", "Unexpected network request")
            paths.append(request.url!.path + "?" + (request.url!.query ?? ""))
            try check(!plans.isEmpty, "Unplanned request")
            return plans.removeFirst()
        }
    }
    var requests: [String] { lock.withLock { paths } }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan: Plan
        do { plan = try Self.state.take(request) }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        DispatchQueue.global().async { [self] in
            plan.gate?.wait()
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(plan.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}
private struct BlockingPayload: Encodable, Sendable {
    let gate: Gate
    func encode(to encoder: Encoder) throws { gate.wait(); var c = encoder.singleValueContainer(); try c.encode("fixture") }
}
private func item(_ id: String) -> String { "{\"id\":\"\(id)\",\"libraryId\":\"A\",\"mediaType\":\"book\",\"media\":{\"numTracks\":1,\"metadata\":{\"title\":\"\(id)\"}}}" }
private func page(_ ids: [String], page: Int = 0, total: Int = 1, limit: Int = 2) -> String {
    "{\"results\":[" + ids.map(item).joined(separator: ",") + "],\"total\":\(total),\"page\":\(page),\"limit\":\(limit)}"
}
private func search(_ ids: [String]) -> String { "{\"book\":[" + ids.map { "{\"libraryItem\":" + item($0) + "}" }.joined(separator: ",") + "],\"podcast\":[]}" }
@main private struct LibraryBrowserSmoke {
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try check(condition(), "Fixture wait timed out")
    }
    static func client() async throws -> ABSClient {
        let profile = ServerProfile(name: "Isolated fixture", baseURL: URL(string: "https://library.fixture.test/compat")!, serverVersion: "2.37.1")
        let tokens = MemoryTokenStore()
        await tokens.save(.init(accessToken: "synthetic-off-network-token", userID: "fixture-user"), account: profile.id.uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ABSClient(profile: profile, session: URLSession(configuration: config), tokenStore: tokens)
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("FAIL LibraryBrowserSmoke: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    @MainActor static func percentageChecks(store: AppStore, library: Library, database: ShelfDatabase, defaults: UserDefaults) async throws {
        let partition = AccountPartition(serverID: UUID(), userID: "percentage-fixture")
        let preferencesStore = LibraryBrowserPreferencesStore(defaults: defaults)
        let key = "ShelfMac.LibraryBrowser." + partition.directoryName + "." + library.id
        let legacy = LibraryBrowserPreferences(options: .init(sort: .progress, descending: true, collapseSeries: true))
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        legacyObject.removeValue(forKey: "sortByProgressPercentage")
        defaults.set(try JSONSerialization.data(withJSONObject: legacyObject), forKey: key)
        var migrated = preferencesStore.load(partition: partition, library: library, fallback: .init())
        migrated.normalize(library: library, user: store.user, version: "2.26.0")
        try check(migrated.sortByProgressPercentage && migrated.options.sort == .title && !migrated.options.collapseSeries && migrated.options.descending, "Old misleading progress preference was not migrated to percentage sorting")
        try preferencesStore.save(migrated, partition: partition, libraryID: library.id)
        try check(preferencesStore.load(partition: partition, library: library, fallback: .init()).sortByProgressPercentage, "Migrated percentage preference did not survive another instance")
        try preferencesStore.save(.init(options: .init(sort: .progress), sortByProgressPercentage: false), partition: partition, libraryID: library.id)
        try check(!preferencesStore.load(partition: partition, library: library, fallback: .init()).sortByProgressPercentage, "Explicit update-date preference was incorrectly migrated again")
        print("PASS percentage legacy preference migration and explicit date-sort preservation")

        let ids = (0..<405).map { String(format: "pct-%03d", $0) }
        func plans(_ values: [String], heldPage: Int? = nil, gate: Gate? = nil) -> [Plan] {
            stride(from: 0, to: values.count, by: 200).enumerated().map { index, offset in
                .init(json: page(Array(values.dropFirst(offset).prefix(200)), page: index, total: values.count, limit: 200), gate: index == heldPage ? gate : nil)
            }
        }
        var progress = Dictionary(uniqueKeysWithValues: (1..<405).map { index in
            let id = ids[index]
            return (id, MediaProgress(libraryItemId: id, progress: index == 404 ? 0.02 : (index == 1 ? 0 : Double(index) / 405), isFinished: index == 404, lastUpdate: Double(10_000 - index)))
        })
        progress[ids[3]] = .init(libraryItemId: ids[3], progress: 0, ebookProgress: 3.0 / 405)
        progress[ids[5]]?.ebookProgress = 0.99 // Nonzero audio still takes precedence.
        let descending = (2..<405).reversed().map { ids[$0] } + [ids[0], ids[1]]
        store.partition = partition; store.currentLibrary = library; store.client = try await client(); store.isOffline = false; store.progressByItem = progress
        let model = LibraryBrowserModel()
        var options = LibraryBrowseOptions(limit: 60, sort: .duration, collapseSeries: true)
        FixtureProtocol.state.install(plans(ids))
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == Array(ids.prefix(60)) && model.total == 405 && model.hasMore && model.error == nil, "Percentage ascending did not combine all server pages before displaying 60 entries")
        try check(FixtureProtocol.state.requests.count == 3, "Percentage scan did not read all three server pages")
        for path in FixtureProtocol.state.requests {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(string: "https://library.fixture.test" + path)!.queryItems!.map { ($0.name, $0.value ?? "") })
            try check(query["sort"] == "media.metadata.title" && query["desc"] == "0" && query["collapseseries"] == "0" && query["limit"] == "200", "Percentage scan did not use stable individual-book title ordering")
        }
        options.page = 1
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == Array(ids[60..<120]) && FixtureProtocol.state.requests.count == 3, "Percentage second UI page was locally sorted instead of globally paged, or needlessly rescanned")
        options.page = 6
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == Array(ids[360..<405]) && !model.hasMore, "Percentage final UI page lost server-page-three records")
        print("PASS percentage ascending global 405-book scan, second/final 60-entry pages and source reuse")
        options.page = 0; options.descending = true
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == Array(descending.prefix(60)), "Percentage descending did not bring finished last-server-page book to the top")
        options.page = 1
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == Array(descending.dropFirst(60).prefix(60)) && FixtureProtocol.state.requests.count == 3, "Percentage descending second page was wrong or discarded its source snapshot")
        print("PASS percentage descending global pages, finished/missing/ebook/audio ordering and date independence")
        options.page = 0
        store.progressByItem[ids[200]]?.isFinished = true
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.first?.item.id == ids[200] && FixtureProtocol.state.requests.count == 3, "Reused percentage source did not rerank current progress snapshot")
        store.progressByItem = progress; store.libraryRevision = UUID()
        FixtureProtocol.state.install(plans(ids))
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.first?.item.id == ids[404] && FixtureProtocol.state.requests.count == 3, "Refresh revision failed to invalidate percentage source")
        print("PASS percentage current-progress rerank and refresh invalidation")

        options.filter = .genre("fixture-filter")
        FixtureProtocol.state.install(plans([ids[100], ids[300]]))
        await model.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(model.entries.map(\.item.id) == [ids[300], ids[100]] && model.total == 2 && FixtureProtocol.state.requests.count == 1, "Changed filter reused unfiltered percentage source")
        let filterQuery = URLComponents(string: "https://library.fixture.test" + FixtureProtocol.state.requests[0])!.queryItems
        try check(filterQuery?.first(where: { $0.name == "filter" })?.value == options.filter.queryValue, "Percentage scan lost the server filter")
        store.isOffline = true; store.progressByItem[ids[100]]?.progress = 0.99; store.progressByItem[ids[300]]?.progress = 0.1
        let reopened = LibraryBrowserModel()
        FixtureProtocol.state.install([])
        await reopened.load(store: store, library: library, options: options, search: "", progressPercentage: true)
        try check(reopened.entries.map(\.item.id) == [ids[100], ids[300]] && FixtureProtocol.state.requests.isEmpty, "Reopened offline percentage source was not persisted or reranked")
        print("PASS percentage filtered scan and fresh-model offline SQLite rerank")

        let legacyLibrary = Library(id: "percentage-legacy", name: "Legacy")
        let legacyItems = ["legacy-missing", "legacy-low", "legacy-high"].map { LibraryItem(id: $0, libraryId: legacyLibrary.id, media: .init(metadata: .init(title: $0))) }
        try await database.save(legacyItems, key: "items." + legacyLibrary.id, partition: partition)
        store.currentLibrary = legacyLibrary; store.progressByItem = ["legacy-low": .init(libraryItemId: "legacy-low", progress: 0.2), "legacy-high": .init(libraryItemId: "legacy-high", progress: 0.8)]
        let legacyModel = LibraryBrowserModel()
        options = .init(limit: 60, descending: true)
        await legacyModel.load(store: store, library: legacyLibrary, options: options, search: "", progressPercentage: true)
        try check(legacyModel.entries.map(\.item.id) == ["legacy-high", "legacy-low", "legacy-missing"], "Legacy offline items were not percentage sorted")
        options.filter = .genre("uncached-filter")
        await legacyModel.load(store: store, library: legacyLibrary, options: options, search: "", progressPercentage: true)
        try check(legacyModel.entries.isEmpty && FixtureProtocol.state.requests.isEmpty, "Uncached filtered offline percentage request incorrectly used unfiltered legacy items")
        print("PASS percentage legacy offline fallback respects filter boundaries")

        store.isOffline = false; store.currentLibrary = library; store.progressByItem = progress
        FixtureProtocol.state.install([.init(json: search(["query-result"]))])
        await model.load(store: store, library: library, options: .init(limit: 60, filter: .progress(.finished)), search: "needle", progressPercentage: true)
        try check(model.entries.map(\.item.id) == ["query-result"] && FixtureProtocol.state.requests.count == 1 && FixtureProtocol.state.requests[0].contains("/search?"), "Search incorrectly applied percentage scan or its saved filter")
        print("PASS percentage mode search still bypasses saved browse sorting/filtering")

        for scenario in ["account", "client", "library", "offline", "cancel", "generation"] {
            store.partition = .init(serverID: UUID(), userID: "percentage-isolation"); store.client = try await client(); store.currentLibrary = library; store.isOffline = false; store.progressByItem = progress
            let isolated = LibraryBrowserModel(), gate = Gate()
            FixtureProtocol.state.install(plans(ids, heldPage: 1, gate: gate))
            let obsolete = Task { await isolated.load(store: store, library: library, options: .init(limit: 60), search: "", progressPercentage: true) }
            try await waitFor { gate.entered }
            try check(isolated.entries.isEmpty && isolated.total == nil && isolated.isLoading, "Percentage scan exposed a partially sorted server page")
            switch scenario {
            case "account": store.partition = .init(serverID: UUID(), userID: "other-percentage-account")
            case "client": store.client = try await client()
            case "library": store.currentLibrary = legacyLibrary
            case "offline": store.isOffline = true
            case "cancel": obsolete.cancel()
            default:
                FixtureProtocol.state.install(plans(ids))
                await isolated.load(store: store, library: library, options: .init(limit: 60, descending: true), search: "", progressPercentage: true)
            }
            gate.release.signal(); await obsolete.value
            try check(isolated.entries.map(\.item.id) == (scenario == "generation" ? Array(descending.prefix(60)) : []) && isolated.error == nil && !isolated.isLoading, "Late multi-page percentage \(scenario) scan changed winning state")
            print("PASS percentage delayed middle-page \(scenario) isolation")
        }
    }

    @MainActor static func retainedCoverSourceCheck(database: ShelfDatabase) async throws {
        let store = AppStore(), model = LibraryBrowserModel(), library = Library(id: "A", name: "Same ID on both servers")
        store.database = database; store.currentLibrary = library; store.isOffline = true
        let profileA = ServerProfile(name: "A", baseURL: URL(string: "https://a.invalid")!)
        store.profile = profileA; store.partition = .init(serverID: profileA.id, userID: "fixture-user")
        store.client = try await client()
        try await database.save([LibraryItem(id: "old-row", libraryId: "A")], key: "items.A", partition: store.partition!)
        await model.load(store: store, library: library, options: .init(), search: "")
        let capturedSource = model.coverSource, capturedEntries = model.entries
        try check(capturedEntries.count == 1 && capturedSource?.request(item: capturedEntries[0].item, store: store)?.url.host == "a.invalid", "Initial retained cover row fixture failed")
        let profileB = ServerProfile(name: "B", baseURL: URL(string: "https://b.invalid")!)
        store.profile = profileB; store.partition = .init(serverID: profileB.id, userID: "fixture-user")
        store.client = try await client()
        try await database.save([LibraryItem(id: "new-row", libraryId: "A")], key: "items.A", partition: store.partition!)
        await model.load(store: store, library: library, options: .init(), search: "")
        try check(model.isBound(to: store, libraryID: "A") && model.entries.first?.item.id == "new-row", "Replacement model did not bind colliding library ID")
        try check(model.coverSource?.request(item: capturedEntries[0].item, store: store)?.url.host == "b.invalid", "Fixture must expose why using the latest model source admits old entries")
        try check(capturedSource?.isCurrent(store) == false && capturedSource?.request(item: capturedEntries[0].item, store: store) == nil, "Retained entry/source pair rebound to replacement server")
        try check(model.coverSource?.request(item: model.entries[0].item, store: store)?.url.host == "b.invalid", "Replacement row source was incorrectly suppressed")
        print("PASS retained entry/source pair across actual model rebind with colliding library ID; current source control demonstrates old-row hazard")
        print("LIMIT retained source test exercises production model/helper; does not execute SwiftUI lazy grid/list closure scheduling")
    }

    @MainActor static func run() async throws {
        try check(CommandLine.arguments.count == 2, "Pass an isolated fixture work directory")
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let library = Library(id: "A", name: "A")
        let libraryB = Library(id: "B", name: "B", mediaType: "podcast")
        let a = AccountPartition(serverID: UUID(), userID: "fixture-user")
        let b = AccountPartition(serverID: a.serverID, userID: "other-user")
        let suite = "ShelfMac.LibraryFixture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferencesStore = LibraryBrowserPreferencesStore(defaults: defaults)
        var preferences = LibraryBrowserPreferences(options: .init(page: 9, sort: .duration, descending: true), display: .list, coverSize: 999, showSubtitles: true)
        try preferencesStore.save(preferences, partition: a, libraryID: "A")
        let restored = preferencesStore.load(partition: a, library: library, fallback: .init())
        try check(restored.options.sort == .duration && restored.options.page == 0 && restored.coverSize == 240 && restored.display == .list && restored.showSubtitles, "Preference restoration or normalization failed")
        try check(preferencesStore.load(partition: b, library: library, fallback: .init()).options.sort == .title, "Preferences leaked into another account")
        try check(preferencesStore.load(partition: a, library: libraryB, fallback: .init()).options.sort == .title, "Preferences leaked into another library")
        preferences.options = .init(page: 99, limit: 777, sort: .progressFinished, descending: true, filter: .explicit, collapseSeries: true)
        preferences.coverSize = .nan
        preferences.normalize(library: libraryB, user: .init(id: "fixture-user", username: "fixture"), version: "2.26.0")
        try check(preferences.options.page == 0 && preferences.options.limit == 60 && preferences.options.sort == .title && !preferences.options.descending && preferences.options.filter == .all && !preferences.options.collapseSeries && preferences.coverSize == 160, "Unsupported media, permissions, version, or cover preferences survived normalization")
        preferences.options = .init(sort: .sequence, filter: .all)
        preferences.normalize(library: library, user: nil, version: "2.37.1")
        try check(preferences.options.sort == .title, "Sequence sorting outside a series filter survived normalization")
        preferences.options = .init(sort: .progress)
        preferences.normalize(library: library, user: nil, version: "2.26.0")
        try check(preferences.options.sort == .title, "Legacy ordinary progress sorting survived without its required filter")
        preferences.options = .init(sort: .progress, filter: .progress(.inProgress))
        preferences.normalize(library: library, user: nil, version: "2.26.0")
        try check(preferences.options.sort == .progress, "Legacy supported filtered progress sorting was discarded")
        for version in ["2.26.0", "2.37.1"] {
            for sort: LibraryBrowseSort in [.progress, .progressStarted, .progressFinished, .random] {
                preferences.options = .init(sort: sort, descending: true, filter: .series("series"), collapseSeries: true)
                preferences.normalize(library: library, user: nil, version: version)
                try check(preferences.options.sort == .sequence && !preferences.options.descending, "Collapsed subseries kept unsupported progress/random sorting")
            }
        }
        print("PASS preferences partition/library isolation, restoration and unsupported normalization")

        let store = AppStore(); store.partition = a; store.currentLibrary = library; store.client = try await client()
        store.database = try ShelfDatabase(path: work.appendingPathComponent("library-" + UUID().uuidString + ".sqlite"))
        let database = store.database!, model = LibraryBrowserModel()
        var options = LibraryBrowseOptions(limit: 2)
        FixtureProtocol.state.install([.init(json: page(["A-one", "A-two"], total: 3)), .init(json: page(["A-three"], page: 1, total: 3))])
        await model.load(store: store, library: library, options: options, search: "")
        try check(model.entries.map(\.item.id) == ["A-one", "A-two"] && model.hasMore && model.total == 3 && model.error == nil && model.isBound(to: store, libraryID: "A"), "First page or account binding failed")
        options.page = 1
        await model.load(store: store, library: library, options: options, search: "")
        try check(model.entries.map(\.item.id) == ["A-three"] && !model.hasMore && model.total == 3 && FixtureProtocol.state.requests[1].contains("page=1"), "Pagination appended incorrectly or failed to finish")
        store.isOffline = true; options.page = 0
        await model.load(store: store, library: library, options: options, search: "")
        try check(model.entries.map(\.item.id) == ["A-one", "A-two"] && model.hasMore && !model.usesLegacyCache, "Offline persisted exact page could not find next cached page")
        options.page = 1
        await model.load(store: store, library: library, options: options, search: "")
        try check(model.entries.map(\.item.id) == ["A-three"] && !model.hasMore, "Offline persisted final page was wrong")
        print("PASS actual SQLite exact-page offline pagination and end-of-list")

        let legacy = ["Zulu", "Alpha", "Beta"].map { LibraryItem(id: $0, libraryId: "B", media: .init(metadata: .init(title: $0))) }
        try await database.save(legacy, key: "items.B", partition: a)
        store.currentLibrary = libraryB; options = .init(page: 1, limit: 2)
        await model.load(store: store, library: libraryB, options: options, search: "")
        try check(model.entries.map(\.item.id) == ["Zulu"] && model.total == 3 && !model.hasMore && model.usesLegacyCache, "Legacy cache title sort/page fallback failed")
        options.page = 0
        await model.load(store: store, library: libraryB, options: options, search: "alp")
        try check(model.entries.map(\.item.id) == ["Alpha"] && model.total == 1 && !model.hasMore, "Offline legacy text search failed")
        print("PASS legacy cache fallback is sorted, paged and searchable")

        store.isOffline = false; store.currentLibrary = library; options = .init(limit: 2)
        FixtureProtocol.state.install([.init(json: search(["one", "two", "three"])), .init(json: search(["one", "two", "three"]))])
        await model.load(store: store, library: library, options: options, search: "needle")
        try check(model.entries.map(\.item.id) == ["one", "two"] && model.hasMore && model.total == nil && FixtureProtocol.state.requests[0].contains("limit=3"), "Search first expanding-prefix page state wrong")
        options.page = 1
        await model.load(store: store, library: library, options: options, search: "needle")
        try check(model.entries.map(\.item.id) == ["three"] && !model.hasMore && model.total == 3 && FixtureProtocol.state.requests[1].contains("limit=5"), "Search second expanding-prefix page state wrong")
        print("PASS search expanding-prefix pagination and unknown-to-final total")

        for scenario in ["account", "client", "library", "offline", "cancel", "generation", "search"] {
            store.partition = a; store.client = try await client(); store.currentLibrary = library; store.isOffline = false
            let gate = Gate(); let scenarioOptions = LibraryBrowseOptions(limit: 2)
            FixtureProtocol.state.install([.init(json: scenario == "search" ? search(["obsolete"]) : page(["obsolete"]), gate: gate), .init(json: scenario == "search" ? search(["winner"]) : page(["winner"]))])
            let obsolete = Task { await model.load(store: store, library: library, options: scenarioOptions, search: scenario == "search" ? "old" : "") }
            try await waitFor { gate.entered }
            switch scenario {
            case "account": store.partition = b
            case "client": store.client = try await client()
            case "library": store.currentLibrary = libraryB
            case "offline": store.isOffline = true
            case "cancel": obsolete.cancel()
            case "generation", "search": await model.load(store: store, library: library, options: scenarioOptions, search: scenario == "search" ? "new" : "")
            default: break
            }
            gate.release.signal(); await obsolete.value
            try check(model.entries.map(\.item.id) == (["generation", "search"].contains(scenario) ? ["winner"] : []) && model.error == nil && !model.isLoading, "Late \(scenario) response published obsolete entries")
            print("PASS delayed online \(scenario) response isolation")
        }
        for scenario in ["account", "client", "library", "offline", "cancel"] {
            store.partition = a; store.client = try await client(); store.currentLibrary = libraryB; store.isOffline = true
            let gate = Gate()
            let blocker = Task.detached { try await database.save(BlockingPayload(gate: gate), key: "actor-gate", partition: a) }
            try await waitFor { gate.entered }
            let obsolete = Task { await model.load(store: store, library: libraryB, options: .init(limit: 2), search: "") }
            try await waitFor { model.isLoading }
            switch scenario {
            case "account": store.partition = b
            case "client": store.client = try await client()
            case "library": store.currentLibrary = library
            case "offline": store.isOffline = false
            default: obsolete.cancel()
            }
            gate.release.signal(); try await blocker.value; await obsolete.value
            try check(model.entries.isEmpty && model.error == nil && !model.isLoading, "Late offline \(scenario) cache published obsolete entries")
            print("PASS delayed SQLite \(scenario) isolation")
        }
        store.partition = a; store.client = try await client(); store.currentLibrary = library; store.isOffline = false
        let metadataGate = Gate()
        FixtureProtocol.state.install([.init(json: "{\"genres\":[\"obsolete\"]}", gate: metadataGate)])
        let obsoleteMetadata = Task { await model.loadMetadata(store: store, library: library) }
        try await waitFor { metadataGate.entered }; model.cancel(); metadataGate.release.signal(); await obsoleteMetadata.value
        try check(model.metadata == nil && model.metadataError == nil && !model.metadataLoading && !model.isBound(to: store, libraryID: "A"), "Cancelled metadata or bound account remained active")
        print("PASS metadata cancellation and bound-action invalidation")
        store.partition = a; store.client = try await client(); store.currentLibrary = library; store.isOffline = false
        let winnerGate = Gate()
        FixtureProtocol.state.install([.init(json: page(["winner"]), gate: winnerGate), .init(json: page(["cancelled-stale"], page: 1))])
        let winner = Task { await model.load(store: store, library: library, options: .init(limit: 2), search: "") }
        try await waitFor { winnerGate.entered }
        let cancelledBeforeEntry = Task { await model.load(store: store, library: library, options: .init(page: 1, limit: 2), search: "") }
        cancelledBeforeEntry.cancel()
        await cancelledBeforeEntry.value
        winnerGate.release.signal(); await winner.value
        try check(model.entries.map(\.item.id) == ["winner"] && FixtureProtocol.state.requests.count == 1, "Cancelled-before-entry load invalidated winning request or performed stale HTTP")
        print("PASS cancelled-before-entry load preserves winning request")
        let latestMetadataGate = Gate()
        FixtureProtocol.state.install([.init(json: "{\"genres\":[\"winner\"]}", gate: latestMetadataGate), .init(json: "{\"genres\":[\"obsolete\"]}")])
        let winnerMetadata = Task { await model.loadMetadata(store: store, library: library) }
        try await waitFor { latestMetadataGate.entered }
        let cancelledMetadata = Task { await model.loadMetadata(store: store, library: library) }
        cancelledMetadata.cancel(); await cancelledMetadata.value
        latestMetadataGate.release.signal(); await winnerMetadata.value
        try check(model.metadata?.genres == ["winner"] && !model.metadataLoading, "Cancelled-before-entry metadata load invalidated winning request")
        print("PASS cancelled-before-entry metadata preserves winning request")
        await model.load(store: store, library: libraryB, options: .init(), search: "")
        await model.loadMetadata(store: store, library: libraryB)
        try check(model.entries.map(\.item.id) == ["winner"] && model.metadata?.genres == ["winner"] && model.isBound(to: store, libraryID: "A"), "Wrong-library queued load invalidated winning state")
        print("PASS wrong-library queued load preserves winning state")
        try await percentageChecks(store: store, library: library, database: database, defaults: defaults)
        try await retainedCoverSourceCheck(database: database)
        print("PASS LibraryBrowserModel/Preferences 34 isolated scenarios (20 baseline + 13 percentage + retained cover source)")
    }
}
