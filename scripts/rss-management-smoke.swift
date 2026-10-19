// Compiles the actual RSSManagementModel and PersonalAccountScope. Identity-only AppStore is supplied here.
// Every request is intercepted; only synthetic MemoryTokenStore credentials are used.
import Foundation
import ShelfCore

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
            guard let url = request.url, url.scheme == "https", url.host == "rss.fixture.test", url.path.hasPrefix("/api/feeds"),
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
private let mini = #"{"id":"feed","entityType":"libraryItem","entityId":"item","feedUrl":"/feed/feed","meta":{"title":"Fixture"}}"#
private let full = #"{"id":"feed","entityType":"libraryItem","entityId":"item","feedUrl":"/feed/feed","meta":{"title":"Fixture"},"episodes":[{"id":"episode","title":"Track"}],"updatedAt":1234}"#
@main private struct Smoke {
    @MainActor static func setup() async -> (AppStore, RSSManagementModel) {
        let store = AppStore()
        let profile = ServerProfile(name: "Fixture", baseURL: URL(string: "https://rss.fixture.test")!, serverVersion: "2.37.1")
        let tokens = MemoryTokenStore()
        await tokens.save(.init(accessToken: "synthetic-rss-token", userID: "user"), account: profile.id.uuidString)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        store.profile = profile; store.partition = .init(serverID: profile.id, userID: "user")
        store.user = .init(id: "user", username: "Fixture", type: "admin")
        store.client = ABSClient(profile: profile, session: URLSession(configuration: config), tokenStore: tokens)
        return (store, RSSManagementModel(store: store, target: .init(entity: .item, id: "item", title: "Fixture")))
    }
    @MainActor static func prepare(_ model: RSSManagementModel, previous: RSSFeed? = nil) throws -> PersonalConfirmation {
        guard let editor = model.editor(for: previous) else { throw Failure(message: "Missing editor") }
        model.publish(editor: editor, slug: "fixture", preventIndexing: true, ownerName: "", ownerEmail: "")
        guard let confirmation = model.scope.confirmation else { throw Failure(message: "Missing confirmation") }
        model.scope.confirmation = nil
        return confirmation
    }
    @MainActor static func main() async throws {
        let state = FixtureProtocol.state
        do {
            let (_, model) = await setup()
            state.install([Reply(json: "{\"feed\":" + mini + "}"), Reply(json: "{\"feeds\":[" + full + "]}")])
            try await prepare(model).action()
            try require(model.feeds.first?.episodes?.first?.title == "Track" && state.requests == 2 && state.unexpectedRequests == 0, "Publication must hydrate detail")
        }
        do {
            let (_, model) = await setup()
            state.install([Reply(json: "{\"feed\":" + mini + "}"), Reply(json: "{}", status: 500)])
            try await prepare(model).action()
            try require(model.feeds.count == 1 && model.scope.notice == L10n.tr("RSS 订阅已发布。") && model.scope.error != nil && state.requests == 2, "Read failure must preserve published feed and report separate error")
        }
        for revoke in [false, true] {
            let (store, model) = await setup(); state.install([])
            let action: PersonalConfirmation
            if revoke {
                model.revoke(try JSONDecoder().decode(RSSFeed.self, from: Data(full.utf8)))
                action = model.scope.confirmation!
            } else { action = try prepare(model) }
            store.user = .init(id: "user", username: "Fixture", type: "user")
            await action.action()
            try require(state.requests == 0 && state.unexpectedRequests == 0, "Downgrade after confirmation must not send mutation")
        }
        do {
            let (store, model) = await setup(); state.install([])
            let action = try prepare(model)
            store.partition = .init(serverID: UUID(), userID: "other")
            await action.action()
            try require(state.unexpectedRequests == 0, "Stale account must not publish")
        }
        do {
            let (_, model) = await setup(); state.install([])
            let action = try prepare(model); model.scope.cancel()
            await action.action()
            try require(state.unexpectedRequests == 0, "Cancelled scope must not publish")
        }
        do {
            let (store, model) = await setup()
            let old = try JSONDecoder().decode(RSSFeed.self, from: Data(full.utf8)); model.feeds = [old]
            let gate = Gate(); state.install([Reply(json: "{}", gate: gate)])
            let action = try prepare(model, previous: old)
            let running = Task { await action.action() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !gate.isEntered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard gate.isEntered else { gate.release.signal(); throw Failure(message: "Close request not reached") }
            store.user = .init(id: "user", username: "Fixture", type: "user")
            gate.release.signal(); await running.value
            try require(model.feeds.isEmpty && state.requests == 1 && state.unexpectedRequests == 0, "Downgrade during close must prevent reopen")
        }
        for cancel in [false, true] {
            let (store, model) = await setup()
            let gate = Gate()
            state.install([Reply(json: "{\"feed\":" + mini + "}"), Reply(json: "{\"feeds\":[" + full + "]}", gate: gate)])
            let action = try prepare(model)
            let running = Task { await action.action() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !gate.isEntered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            guard gate.isEntered else { gate.release.signal(); throw Failure(message: "Hydration not reached") }
            if cancel { model.scope.cancel() }
            else { store.partition = .init(serverID: UUID(), userID: "other") }
            gate.release.signal(); await running.value
            try require(model.feeds.first?.episodes == nil && state.requests == 2 && state.unexpectedRequests == 0, "Stale hydration must not apply")
        }
        print("PASS 9 RSS model scenarios: hydration, read failure, publish/revoke downgrade, account switch, cancellation, downgrade between close/open, in-flight hydration account switch/cancellation")
    }
}
