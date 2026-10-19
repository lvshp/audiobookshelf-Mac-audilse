import Foundation

extension ABSClient {
    /// Searches one accessible library using the unchanged ABS 2.26–2.37 contract.
    /// `limit` bounds each category separately (1...500); ABS has no search paging.
    /// An empty trimmed query clears the results without making a network request.
    public func searchLibrary(libraryID: String, query: String, limit: Int = 12) async throws -> LibrarySearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .init() }
        return try await getJSON(path: FeaturePath.query("api/libraries/\(FeaturePath.id(libraryID))/search", [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(min(500, max(1, limit))))
        ]))
    }
}
