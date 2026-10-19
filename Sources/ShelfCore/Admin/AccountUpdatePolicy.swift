import Foundation

/// Matches the protected root fields in the 2.26 and 2.37.1 account editor.
public enum AccountUpdatePolicy {
    public static func update(_ proposed: UserUpdate, for user: AdminUser) -> UserUpdate {
        guard user.type == "root" else { return proposed }
        var result = UserUpdate()
        result.username = proposed.username
        result.email = proposed.email
        return result
    }

    /// The generic administrator endpoint does not return replacement tokens.
    public static func requiresSignIn(user: AdminUser, update: UserUpdate, actorID: String) -> Bool {
        guard user.id == actorID else { return false }
        let payload = self.update(update, for: user)
        return payload.password.map { !$0.isEmpty } == true ||
            payload.username.map { !$0.isEmpty && $0 != user.username } == true
    }

    public static func hasSameAccess(_ lhs: UserAccount, _ rhs: UserAccount) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.isActive == rhs.isActive &&
        lhs.permissions == rhs.permissions && Set(lhs.librariesAccessible) == Set(rhs.librariesAccessible) &&
        Set(lhs.itemTagsSelected) == Set(rhs.itemTagsSelected)
    }

    public static func isUnchanged(_ lhs: AdminUser, since rhs: AdminUser) -> Bool {
        lhs.id == rhs.id && lhs.username == rhs.username && lhs.type == rhs.type && lhs.email == rhs.email &&
        lhs.isActive == rhs.isActive && lhs.permissions == rhs.permissions &&
        Set(lhs.librariesAccessible ?? []) == Set(rhs.librariesAccessible ?? []) &&
        Set(lhs.itemTagsSelected ?? []) == Set(rhs.itemTagsSelected ?? [])
    }

    /// Usernames can change; only a canonical server plus the authenticated user
    /// identifies a persisted data partition. An explicit target wins duplicates.
    public static func reusingProfile(_ authenticated: ServerProfile, profiles: [ServerProfile], preferredID: UUID?) throws -> ServerProfile {
        let endpoint = try ServerRestoreBatch.canonicalURL(authenticated.baseURL.absoluteString)
        let matches = profiles.filter {
            $0.userID == authenticated.userID && authenticated.userID != nil &&
            (try? ServerRestoreBatch.canonicalURL($0.baseURL.absoluteString)) == endpoint
        }
        let selected: ServerProfile?
        if let preferredID, let preferred = matches.first(where: { $0.id == preferredID }) { selected = preferred }
        else if matches.count == 1 { selected = matches[0] }
        else if matches.count > 1 { throw AccountProfileReuseError.ambiguous }
        else { selected = nil }
        var result = authenticated
        if let selected { result.id = selected.id }
        else if profiles.contains(where: { $0.id == authenticated.id && $0.userID != nil && $0.userID != authenticated.userID }) {
            result.id = UUID()
        }
        return result
    }
}

public enum AccountProfileReuseError: LocalizedError, Sendable {
    case ambiguous
    public var errorDescription: String? { "此服务器存在多个属于同一账户的本机配置，请从账户菜单选择目标配置后重试登录。" }
}
