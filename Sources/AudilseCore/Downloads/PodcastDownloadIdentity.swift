import Foundation

public struct PodcastDownloadIdentity: Hashable, Sendable {
    public let itemID: String
    public let episodeID: String
    private static let prefix = "podcast-episode-v1_"
    public init(itemID: String, episodeID: String) { self.itemID = itemID; self.episodeID = episodeID }
    public static func key(itemID: String, episodeID: String) -> String {
        // Length-prefixed UTF-8 fields keep arbitrary IDs unambiguous without retaining URLs.
        let first = Data(itemID.utf8)
        var payload = Data(String(first.count).utf8)
        payload.append(0x3a); payload.append(first); payload.append(Data(episodeID.utf8))
        return prefix + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public init?(key: String) {
        guard key.hasPrefix(Self.prefix) else { return nil }
        var encoded = String(key.dropFirst(Self.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded), let separator = payload.firstIndex(of: 0x3a),
              let countString = String(data: payload[..<separator], encoding: .utf8), let count = Int(countString), count >= 0 else { return nil }
        let start = payload.index(after: separator)
        guard count <= payload.count - start else { return nil }
        let end = start + count
        guard let itemID = String(data: payload[start..<end], encoding: .utf8), !itemID.isEmpty,
              let episodeID = String(data: payload[end...], encoding: .utf8), !episodeID.isEmpty else { return nil }
        self.init(itemID: itemID, episodeID: episodeID)
    }
}
