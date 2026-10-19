import Foundation

extension ABSClient {
    /// Fixed ABS 2.26–2.37 library statistics. The native screen follows the Web
    /// admin/root visibility rule; the server also checks access to this library.
    public func libraryStatistics(libraryID: String) async throws -> LibraryStatistics {
        guard !libraryID.isEmpty else { throw ABSError.invalidResourcePath }
        return try await getJSON(path: "api/libraries/\(FeaturePath.id(libraryID))/stats")
    }
}
