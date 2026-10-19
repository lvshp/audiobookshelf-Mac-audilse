import Foundation

extension ABSClient {
    public func itemPersonalDetails(id: String) async throws -> ItemPersonalDetails {
        try await getJSON(path: "api/items/\(FeaturePath.id(id))?expanded=1&include=rssfeed,share")
    }
}
