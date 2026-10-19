import Foundation

/// The complete library-wide narrator directory. Counts come from the catalog,
/// before the current user's item-level tag and explicit-content filters.
public struct LibraryNarrator: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let numBooks: Int
    public init(id: String, name: String, numBooks: Int) {
        self.id = id; self.name = name; self.numBooks = numBooks
    }
}

public struct NarratorMutationResult: Codable, Hashable, Sendable {
    public let updated: Int
    public init(updated: Int) { self.updated = updated }
}

public enum LibraryNarratorError: Error, LocalizedError, Sendable, Equatable {
    case unsafeServerVersion
    case emptyName
    public var errorDescription: String? {
        switch self {
        case .unsafeServerVersion: "此服务端版本的朗读者修改可能影响其他书库。请升级到 2.36.1 或更新版本后修改。"
        case .emptyName: "朗读者名称不能为空。"
        }
    }
}

public enum LibraryNarratorPolicy {
    /// 2.26 writes query all libraries. Both fixed 2.36.1 and 2.37.1 scope
    /// writes to this library; unknown/malformed versions remain read-only.
    public static func allowsMutation(serverVersion: String?) -> Bool {
        guard let value = serverVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: #"^[vV]?[0-9]+\.[0-9]+\.[0-9]+(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else { return false }
        return ServerVersion(value) >= ServerVersion("2.36.1")
    }
    /// ABS uses canUpdate for both rename and association removal, not canDelete.
    public static func allowsMutation(user: UserAccount, serverVersion: String?) -> Bool {
        AdminPolicy.allows(.updateContent, user: user) && allowsMutation(serverVersion: serverVersion)
    }
    public static func identifier(for name: String) -> String {
        ServerEndpoint.component(Data(name.utf8).base64EncodedString())
    }
}

struct LibraryNarratorDirectory: Decodable, Sendable { let narrators: [LibraryNarrator] }
