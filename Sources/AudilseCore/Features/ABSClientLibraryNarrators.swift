import Foundation

extension ABSClient {
    public func libraryNarrators(libraryID: String) async throws -> [LibraryNarrator] {
        try Task.checkCancellation()
        guard !isRetired else { throw ABSError.sessionChanged }
        guard !libraryID.isEmpty else { throw ABSError.invalidResourcePath }
        let response: LibraryNarratorDirectory = try await getJSON(path: "api/libraries/\(FeaturePath.id(libraryID))/narrators")
        try Task.checkCancellation()
        guard response.narrators.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.numBooks >= 0 }) else { throw ABSError.invalidResponse }
        return response.narrators
    }

    public func renameLibraryNarrator(libraryID: String, currentName: String, newName: String) async throws -> NarratorMutationResult {
        try Task.checkCancellation()
        guard !isRetired else { throw ABSError.sessionChanged }
        guard LibraryNarratorPolicy.allowsMutation(serverVersion: profile.serverVersion) else { throw LibraryNarratorError.unsafeServerVersion }
        guard !libraryID.isEmpty else { throw ABSError.invalidResourcePath }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentName.isEmpty, !name.isEmpty else { throw LibraryNarratorError.emptyName }
        // Preserve an exact old name (including significant whitespace) and encode
        // its UTF-8 base64 once. Returned directory IDs are already URI encoded.
        guard currentName != name else { return .init(updated: 0) }
        let data = try await requestData(path: "api/libraries/\(FeaturePath.id(libraryID))/narrators/\(LibraryNarratorPolicy.identifier(for: currentName))",
                                         method: "PATCH", body: JSONEncoder().encode(NarratorRename(name: name)), retryAfterAuthentication: false)
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(NarratorMutationResult.self, from: data)
        guard result.updated >= 0 else { throw ABSError.invalidResponse }
        return result
    }

    public func removeLibraryNarrator(libraryID: String, name: String) async throws -> NarratorMutationResult {
        try Task.checkCancellation()
        guard !isRetired else { throw ABSError.sessionChanged }
        guard LibraryNarratorPolicy.allowsMutation(serverVersion: profile.serverVersion) else { throw LibraryNarratorError.unsafeServerVersion }
        guard !libraryID.isEmpty else { throw ABSError.invalidResourcePath }
        guard !name.isEmpty else { throw LibraryNarratorError.emptyName }
        let data = try await requestData(path: "api/libraries/\(FeaturePath.id(libraryID))/narrators/\(LibraryNarratorPolicy.identifier(for: name))", method: "DELETE", retryAfterAuthentication: false)
        try Task.checkCancellation()
        let result = try JSONDecoder().decode(NarratorMutationResult.self, from: data)
        guard result.updated >= 0 else { throw ABSError.invalidResponse }
        return result
    }
}

private struct NarratorRename: Encodable { let name: String }
