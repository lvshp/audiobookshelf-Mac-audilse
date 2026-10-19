import Foundation
import Testing
@testable import AudilseCore

struct AccountUpdatePolicyTests {
    private func user(_ type: String = "admin", id: String = "u1", username: String = "Reader") throws -> AdminUser {
        try JSONDecoder().decode(AdminUser.self, from: JSONEncoder().encode(["id": id, "type": type, "username": username]))
    }

    @Test func rootPayloadContainsOnlyEditableIdentityFields() throws {
        var update = UserUpdate()
        update.username = "Renamed"; update.email = "synthetic@example.test"; update.password = "synthetic"
        update.type = .admin; update.isActive = false; update.permissions = .restrictedCreationDefaults
        update.librariesAccessible = ["l1"]; update.itemTagsSelected = ["tag"]
        let safe = AccountUpdatePolicy.update(update, for: try user("root"))
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(safe)) as? [String: Any])
        #expect(Set(fields.keys) == ["username", "email"])
    }

    @Test func administratorPayloadRemainsUnchanged() throws {
        var update = UserUpdate(); update.password = "synthetic"; update.permissions = .restrictedCreationDefaults
        #expect(AccountUpdatePolicy.update(update, for: try user()) == update)
    }

    @Test func ownCredentialChangesRequireExplicitSignIn() throws {
        let original = try user()
        var update = UserUpdate(); update.username = original.username; update.password = ""
        #expect(!AccountUpdatePolicy.requiresSignIn(user: original, update: update, actorID: original.id))
        update.username = "Renamed"
        #expect(AccountUpdatePolicy.requiresSignIn(user: original, update: update, actorID: original.id))
        #expect(!AccountUpdatePolicy.requiresSignIn(user: original, update: update, actorID: "another"))
        update.username = nil; update.password = "synthetic"
        #expect(AccountUpdatePolicy.requiresSignIn(user: original, update: update, actorID: original.id))
        #expect(!AccountUpdatePolicy.requiresSignIn(user: try user("root"), update: update, actorID: original.id))
    }

    @Test func accessComparisonExcludesProgressButIncludesEveryPermissionAndScope() {
        let original = UserAccount(id: "u1", username: "Reader", librariesAccessible: ["b", "a"], itemTagsSelected: ["y", "x"])
        var latest = original; latest.librariesAccessible.reverse(); latest.itemTagsSelected.reverse()
        latest.mediaProgress = [.init(libraryItemId: "book", currentTime: 1)]
        #expect(AccountUpdatePolicy.hasSameAccess(latest, original))
        latest.permissions.createEreader = true
        #expect(!AccountUpdatePolicy.hasSameAccess(latest, original))
        latest = original; latest.isActive = false
        #expect(!AccountUpdatePolicy.hasSameAccess(latest, original))
        latest = original; latest.type = "admin"
        #expect(!AccountUpdatePolicy.hasSameAccess(latest, original))
        latest = original; latest.itemTagsSelected = []
        #expect(!AccountUpdatePolicy.hasSameAccess(latest, original))
    }

    @Test func staleEditorCannotOverwriteChangedAccess() throws {
        let original = try user()
        var latest = original; latest.lastSeen = 100
        #expect(AccountUpdatePolicy.isUnchanged(latest, since: original))
        latest.permissions = .restrictedCreationDefaults
        #expect(!AccountUpdatePolicy.isUnchanged(latest, since: original))
        latest = original; latest.username = "Renamed"
        #expect(!AccountUpdatePolicy.isUnchanged(latest, since: original))
    }

    @Test func renamedLoginReusesServerAndUserPartitionWithCanonicalEndpoint() throws {
        let existing = ServerProfile(name: "Saved", baseURL: URL(string: "https://example.test/abs/")!, username: "Old", userID: "u1")
        let authenticated = ServerProfile(name: "Login", baseURL: URL(string: "https://EXAMPLE.test:443/abs")!, username: "Renamed", userID: "u1")
        #expect(try AccountUpdatePolicy.reusingProfile(authenticated, profiles: [existing], preferredID: nil).id == existing.id)
        var wrongServer = existing; wrongServer.baseURL = URL(string: "https://another.test/abs")!
        #expect(try AccountUpdatePolicy.reusingProfile(authenticated, profiles: [wrongServer], preferredID: nil).id == authenticated.id)
    }

    @Test func duplicateProfilesRequireExplicitMatchingTarget() throws {
        let first = ServerProfile(name: "First", baseURL: URL(string: "https://example.test/abs")!, username: "Old", userID: "u1")
        var second = first; second.id = UUID()
        var authenticated = first; authenticated.id = UUID(); authenticated.username = "Renamed"
        #expect(throws: AccountProfileReuseError.self) { try AccountUpdatePolicy.reusingProfile(authenticated, profiles: [first, second], preferredID: nil) }
        #expect(try AccountUpdatePolicy.reusingProfile(authenticated, profiles: [first, second], preferredID: second.id).id == second.id)
    }

    @Test func reassignedUsernameNeverReusesAnotherUsersProfileID() throws {
        let original = ServerProfile(name: "Old user", baseURL: URL(string: "https://example.test/abs")!, username: "Reader", userID: "old-user")
        var authenticated = original; authenticated.userID = "new-user"
        #expect(try AccountUpdatePolicy.reusingProfile(authenticated, profiles: [original], preferredID: original.id).id != original.id)
    }
}
