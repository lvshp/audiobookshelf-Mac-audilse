// Compiles the production CoverSource with an in-memory AppStore identity fixture.
// No SwiftUI scheduling, network requests, credentials, user defaults or database access.
import Foundation
import AudilseCore

@MainActor final class AppStore {
    var partition: AccountPartition?
    var profile: ServerProfile?
    var user: UserAccount?
    var client: ABSClient?
    var isOffline = false
    var isConnecting = false
    var isDemo = false
}

@main struct CoverSourceSmoke {
    @MainActor static func main() {
        let store = AppStore()
        let profile = ServerProfile(name: "fixture", baseURL: URL(string: "https://a.invalid/proxy")!, userID: "a")
        let client = ABSClient(profile: profile, tokenStore: MemoryTokenStore())
        store.profile = profile; store.client = client
        store.partition = AccountPartition(serverID: profile.id, userID: "a")
        store.user = UserAccount(id: "a", username: "a")
        let item = LibraryItem(id: "old-item", libraryId: "old-library", updatedAt: 123)
        let source = CoverSource(store: store)
        func check(_ ok: Bool, _ message: String) {
            guard ok else { print("FAIL " + message); exit(1) }
            print("PASS " + message)
        }
        let normal = source.request(item: item, store: store)
        check(normal?.url.absoluteString == "https://a.invalid/proxy/api/items/old-item/cover?width=440&format=jpeg&ts=123.0" && normal?.client === client && normal?.accountKey == store.partition?.directoryName, "normal A source URL/client/cache partition")
        store.profile?.baseURL = URL(string: "https://b.invalid")!
        check(source.request(item: item, store: store) == nil, "A to B server invalidates old source even with reused identity")
        store.profile = profile
        store.user = UserAccount(id: "b", username: "b")
        check(source.request(item: item, store: store) == nil, "same server different user invalidates old source before partition changes")
        store.partition = AccountPartition(serverID: profile.id, userID: "b")
        check(source.request(item: item, store: store) == nil, "same server different user partition invalidates old source")
        store.user = UserAccount(id: "a", username: "a"); store.partition = source.partition
        store.client = ABSClient(profile: profile, tokenStore: MemoryTokenStore())
        check(source.request(item: item, store: store) == nil, "replacement client invalidates old source")
        store.client = client; store.isOffline = true
        check(source.request(item: item, store: store) == nil, "online source invalidated by offline transition")
        let offline = CoverSource(store: store).request(item: item, store: store)
        check(offline?.url == normal?.url && offline?.accountKey == normal?.accountKey && offline?.client == nil, "current offline source preserves cache URL/key without client")
        store.isOffline = false; store.isConnecting = true
        check(source.request(item: item, store: store) == nil, "connecting gate blocks retained source")
        print("LIMIT: actual production helper; in-memory AppStore fixture; no SwiftUI task scheduling or native account transition exercised")
    }
}
