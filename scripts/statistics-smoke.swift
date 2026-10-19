import Foundation
import Observation
import ShelfCore

// Uses the actual FeatureBrowserModel with an account-only AppStore harness.
// Every HTTP request is intercepted by URLProtocol; this executable has no live-server phase.
enum FeatureKind: String, Sendable { case authors, series, collections, playlists, history, statistics }
extension String { var shelfPlainText: String { self } }
@MainActor @Observable final class AppStore {
    var partition: AccountPartition?
    var currentLibrary: Library?
    var client: ABSClient?
    var database: ShelfDatabase?
    var user: UserAccount?
    var isOffline = false
    var isConnecting = false
    var search = ""
}
private struct SmokeFailure: Error { let reason: String }
private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw SmokeFailure(reason: reason) }
}
private struct Reply: Sendable {
    let status: Int
    let data: Data
    var held = false
    init(_ status: Int, _ json: String, held: Bool = false) { self.status = status; data = Data(json.utf8); self.held = held }
    init(_ json: String, held: Bool = false) { self.init(200, json, held: held) }
}
private final class FixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var pending: [String: [FixtureProtocol]] = [:]
    func install(_ replies: [String: Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; pending = [:] }
    func respond(_ request: URLRequest, loader: FixtureProtocol) throws -> Reply? {
        lock.lock(); defer { lock.unlock() }
        guard request.url?.host == "statistics.fixture.test", request.httpMethod == "GET", let path = request.url?.path,
              let reply = replies[path] else { throw SmokeFailure(reason: "Unexpected request") }
        if reply.held { pending[path, default: []].append(loader); return nil }
        return reply
    }
    func isHeld(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !(pending[path] ?? []).isEmpty }
    func release(_ path: String) {
        lock.lock(); let loaders = pending.removeValue(forKey: path) ?? []; let reply = replies[path]; lock.unlock()
        if let reply { for loader in loaders { loader.deliver(reply) } }
    }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = FixtureState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { if let reply = try Self.state.respond(request, loader: self) { deliver(reply) } }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func deliver(_ reply: Reply) {
        lock.lock(); let stopped = stopped; lock.unlock()
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
private func annualJSON(_ time: Int) -> String {
    """
    {"totalListeningSessions":2,"totalListeningTime":\(time),"totalBookListeningTime":\(time),"totalPodcastListeningTime":0,"topAuthors":[{"name":"Fixture Author","time":\(time)}],"topGenres":[{"genre":"Fiction","time":\(time)}],"mostListenedNarrator":{"name":"Fixture Narrator","time":\(time)},"mostListenedMonth":{"month":0,"time":\(time)},"numBooksFinished":1,"numBooksListened":2,"longestAudiobookFinished":{"id":"book","title":"Fixture Book","duration":3600,"finishedAt":"2024-01-02T00:00:00.000Z"},"booksWithCovers":[],"finishedBooksWithCovers":[]}
    """
}
private let overallJSON = #"{"totalTime":7200,"today":1800,"items":{},"days":{"2024-01-01":3600,"2024-01-02":3600},"dayOfWeek":{},"recentSessions":[]}"#
private let statsPath = "/compat/api/me/listening-stats"
private func yearPath(_ year: Int) -> String { "/compat/api/me/stats/year/\(year)" }
@MainActor private func store() async -> AppStore {
    let store = AppStore()
    let profile = ServerProfile(name: "Statistics fixture", baseURL: URL(string: "https://statistics.fixture.test/compat")!, serverVersion: "2.26.0")
    let tokens = MemoryTokenStore()
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
    let client = ABSClient(profile: profile, session: URLSession(configuration: configuration), tokenStore: tokens)
    await tokens.save(.init(accessToken: "synthetic-token", userID: "synthetic-user"), account: client.tokenAccount)
    store.client = client; store.partition = .init(serverID: profile.id, userID: "synthetic-user")
    // Purposely no currentLibrary: the endpoint reports account statistics across libraries.
    store.user = .init(id: "synthetic-user", username: "fixture", createdAt: 1_704_067_200_000)
    return store
}
private func waitHeld(_ path: String) async throws {
    for _ in 0..<200 {
        if FixtureProtocol.state.isHeld(path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SmokeFailure(reason: "Request did not reach fixture gate")
}
@main private struct StatisticsSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch let failure as SmokeFailure { print("FAIL statistics: \(failure.reason)"); exit(1) }
        catch { print("FAIL statistics: unexpected fixture error"); exit(1) }
    }
    @MainActor static func run() async throws {
        let current = Calendar(identifier: .gregorian).component(.year, from: Date())
        try require(current >= 2026, "Fixture calendar requires 2026 or later")
        let account = await store(), model = FeatureBrowserModel()
        FixtureProtocol.state.install([statsPath: Reply(overallJSON), yearPath(current): Reply(404, "{}")])
        await model.load(store: account, kind: .statistics)
        try require(model.statistics?.totalTime == 7200 && model.yearly == nil && model.yearlyError != nil && model.statisticsError == nil, "Annual 404 discarded lifetime data")
        try require(model.availableYears == Array((2024...current).reversed()), "Years do not span account creation through current year")
        print("PASS statistics annual404-preserves-lifetime-without-library")

        FixtureProtocol.state.install([statsPath: Reply(503, "{}"), yearPath(current): Reply(annualJSON(3600))])
        await model.load(store: account, kind: .statistics)
        try require(model.statistics == nil && model.statisticsError != nil && model.yearly?.totalListeningTime == 3600 && model.yearlyError == nil, "Lifetime 503 discarded annual data")
        print("PASS statistics lifetime503-preserves-annual")

        FixtureProtocol.state.install([statsPath: Reply(overallJSON), yearPath(current): Reply(annualJSON(3600), held: true)])
        let loading = Task { await model.load(store: account, kind: .statistics) }
        try await waitHeld(yearPath(current))
        for _ in 0..<200 where model.statistics == nil { try await Task.sleep(for: .milliseconds(10)) }
        try require(model.statistics != nil && model.yearly == nil && model.isYearLoading, "Lifetime waits unnecessarily for annual response")
        FixtureProtocol.state.release(yearPath(current)); await loading.value
        print("PASS statistics independent-publication")

        FixtureProtocol.state.install([yearPath(2025): Reply(annualJSON(25), held: true), yearPath(2024): Reply(annualJSON(24))])
        model.selectedYear = 2025
        let oldYear = Task { await model.loadYear(store: account, year: 2025) }
        try await waitHeld(yearPath(2025))
        model.selectedYear = 2024; await model.loadYear(store: account, year: 2024)
        FixtureProtocol.state.release(yearPath(2025)); await oldYear.value
        try require(model.selectedYear == 2024 && model.yearly?.totalListeningTime == 24 && !model.isYearLoading, "Late annual response replaced new selection")
        // Even a task not yet entered must not restore a previously selected year.
        await model.loadYear(store: account, year: 2025)
        try require(model.selectedYear == 2024 && model.yearly?.totalListeningTime == 24, "Queued old selection restarted")
        print("PASS statistics rapid-year-selection-rejects-old-results")

        try require(model.currentYearly(store: account)?.totalListeningTime == 24, "Published annual source is not visible")
        model.selectedYear = 2025
        try require(model.currentYearly(store: account) == nil, "Old annual data was relabelled before the new year task entered")
        model.selectedYear = 2024
        let savedClient = account.client, savedPartition = account.partition
        let otherAccount = await store()
        account.client = otherAccount.client
        try require(model.currentYearly(store: account) == nil, "Old annual data survived a client change before reloading")
        account.client = savedClient
        account.partition = .init(serverID: UUID(), userID: "different-user")
        try require(model.currentYearly(store: account) == nil, "Old annual data survived an account change before reloading")
        account.partition = savedPartition
        account.isOffline = true
        try require(model.currentYearly(store: account) == nil, "Annual share source remained live while offline")
        account.isOffline = false
        account.isConnecting = true
        try require(model.currentYearly(store: account) == nil, "Annual share source remained live during account connection")
        account.isConnecting = false
        let savedUser = account.user
        account.user = .init(id: "different-user", username: "other")
        try require(model.currentYearly(store: account) == nil, "Annual share source ignored live user identity")
        account.user = savedUser
        try require(model.currentYearly(store: account)?.totalListeningTime == 24, "Restoring exact source did not expose matching statistics")
        print("PASS statistics annual-source-provenance-before-task-entry")

        let alreadyCancelled = Task { await model.load(store: account, kind: .statistics) }
        alreadyCancelled.cancel(); await alreadyCancelled.value
        try require(model.currentYearly(store: account)?.totalListeningTime == 24, "An already cancelled root task cleared the winning source")
        let cancelledYear = Task { await model.loadYear(store: account, year: 2024) }
        cancelledYear.cancel(); await cancelledYear.value
        try require(model.currentYearly(store: account)?.totalListeningTime == 24, "An already cancelled annual task cleared the winning source")
        print("PASS statistics cancelled-entry-preserves-winning-annual-source")

        FixtureProtocol.state.install([yearPath(2025): Reply(annualJSON(25), held: true)])
        model.selectedYear = 2025
        let oldAccount = Task { await model.loadYear(store: account, year: 2025) }
        try await waitHeld(yearPath(2025))
        account.partition = .init(serverID: UUID(), userID: "other-user")
        FixtureProtocol.state.release(yearPath(2025)); await oldAccount.value
        try require(model.yearly == nil && model.yearlyError == nil, "Late response crossed account boundary")
        print("PASS statistics account-change-rejects-old-response")

        FixtureProtocol.state.install([statsPath: Reply(overallJSON), yearPath(2025): Reply(annualJSON(25), held: true)])
        let cancelled = Task { await model.load(store: account, kind: .statistics) }
        try await waitHeld(yearPath(2025)); cancelled.cancel()
        FixtureProtocol.state.release(yearPath(2025)); await cancelled.value
        try require(model.yearly == nil && model.yearlyError == nil && !model.isLoading && !model.isYearLoading, "Cancelled load published data or retained busy state")
        print("PASS statistics cancellation-clears-busy-without-error")
    }
}
