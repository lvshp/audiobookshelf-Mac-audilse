import Foundation
import ShelfCore

/// Captured with the items, never recreated from the live store for an old row.
struct CoverSource: Hashable {
    let partition: AccountPartition?
    let baseURL: URL?
    let userID: String?
    let clientID: ObjectIdentifier?
    let offline: Bool

    @MainActor init(store: AppStore) {
        partition = store.partition; baseURL = store.profile?.baseURL
        userID = store.user?.id; clientID = store.client.map(ObjectIdentifier.init)
        offline = store.isOffline
    }

    @MainActor func isCurrent(_ store: AppStore) -> Bool {
        partition != nil && baseURL != nil && !store.isDemo && !store.isConnecting &&
        store.user?.isActive == true && self == CoverSource(store: store)
    }

    @MainActor func request(item: ShelfCore.LibraryItem, store: AppStore) -> CoverRequest? {
        guard isCurrent(store), let partition, let baseURL else { return nil }
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("")
        guard let url = URL(string: "api/items/\(ServerEndpoint.component(item.id))/cover", relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = [URLQueryItem(name: "width", value: "440"), URLQueryItem(name: "format", value: "jpeg")]
        if let stamp = item.updatedAt, stamp.isFinite { query.append(.init(name: "ts", value: String(stamp))) }
        components.queryItems = query
        guard let url = components.url else { return nil }
        return CoverRequest(url: url, client: offline ? nil : store.client, accountKey: partition.directoryName)
    }
}

struct CoverRequest {
    let url: URL
    let client: ABSClient?
    let accountKey: String
}
