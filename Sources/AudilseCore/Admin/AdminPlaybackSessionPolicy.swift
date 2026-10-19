import Foundation

public enum AdminPlaybackSessionSort: String, CaseIterable, Hashable, Sendable {
    case displayTitle, duration, playMethod, startTime, currentTime, timeListening, updatedAt, createdAt
}

/// The list that supplied a row determines the available actions. A persisted
/// history row and its currently open session can have the same server ID.
public enum AdminPlaybackSessionKind: String, Hashable, Sendable {
    case history, open, share
}

public enum AdminPlaybackSessionInputError: Error, LocalizedError, Sendable, Equatable {
    case invalidUserID, invalidSessionIDs
    public var errorDescription: String? {
        switch self {
        case .invalidUserID: "收听会话的用户筛选标识无效。请重新选择用户。"
        case .invalidSessionIDs: "收听会话标识无效。请刷新后重新选择。"
        }
    }
}

public enum AdminPlaybackSessionPolicy {
    /// Matches the fixed ABS uuid.validate contract, including its nil UUID.
    /// Reject rather than letting the server silently discard an invalid user
    /// filter and broaden a query to every user's history.
    public static func isValidIdentifier(_ value: String) -> Bool {
        value.range(of: #"^(?:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}|00000000-0000-0000-0000-000000000000)$"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
    public static func canDelete(_ session: AdminPlaybackSession, kind: AdminPlaybackSessionKind, actor: UserAccount) -> Bool {
        kind == .history && session.mediaPlayer != "web-share" && isValidIdentifier(session.id)
            && AdminPolicy.allows(.deleteContent, user: actor)
    }
    /// ABS's batch route checks admin/root, independently of canDelete. Native
    /// callers supply selected history rows only; open/share lists are read-only
    /// for this action.
    public static func canBatchDelete(_ sessions: [AdminPlaybackSession], actor: UserAccount) -> Bool {
        !sessions.isEmpty && AdminPolicy.allows(.manageServer, user: actor)
            && sessions.allSatisfy { isValidIdentifier($0.id) && $0.mediaPlayer != "web-share" }
    }
    public static func supportsAdministratorClose(serverVersion: String?) -> Bool {
        guard let version = serverVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              version.range(of: #"^[vV]?[0-9]+\.[0-9]+\.[0-9]+(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else { return false }
        return ServerVersion(version) >= ServerVersion("2.36.1")
    }
    public static func canClose(_ session: AdminPlaybackSession, kind: AdminPlaybackSessionKind, actor: UserAccount, serverVersion: String?) -> Bool {
        guard kind == .open, session.mediaPlayer != "web-share", isValidIdentifier(session.id), actor.isActive else { return false }
        // The fixed 2.26 open-session middleware permits only the owner. Both
        // fixed 2.36.1 and 2.37.1 additionally permit an administrator.
        return session.userId == actor.id
            || AdminPolicy.allows(.manageServer, user: actor) && supportsAdministratorClose(serverVersion: serverVersion)
    }
}
