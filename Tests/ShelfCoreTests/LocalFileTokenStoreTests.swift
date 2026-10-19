import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ShelfCore

private let fixtureTokens = AuthTokens(accessToken: "fixture-secret-access", refreshToken: "fixture-secret-refresh", userID: "fixture-user")
private func credentialsDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ShelfLocalCredentials-" + UUID().uuidString, isDirectory: true)
}
private func tokenURL(_ account: String, in directory: URL) -> URL {
    let hash = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("token-" + hash + ".credential")
}
private func permissions(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
private func addReadACL(_ url: URL, inheritable: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    let permissions = inheritable
        ? "everyone allow read,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
        : "everyone allow read,readattr,readextattr,readsecurity"
    process.arguments = ["+a", permissions, url.path]
    process.standardOutput = Pipe(); process.standardError = Pipe()
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "LocalCredentialACLFixture", code: Int(process.terminationStatus)) }
}
private func hasExtendedACL(_ url: URL) throws -> Bool {
    guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
        // Darwin reports an absent ACL attribute as ENOENT, including when the
        // underlying file exists; distinguish this from a missing fixture.
        guard errno == ENOENT else { throw LocalCredentialError.io(errno) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw LocalCredentialError.io(errno) }
        return false
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) == 0
}

struct LocalFileTokenStoreTests {
    @Test func persistsAcrossInstancesWithPrivatePermissionsAndFreshNonces() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        #expect(try await store.load(account: "one") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try await store.save(fixtureTokens, account: "one")
        let first = try Data(contentsOf: tokenURL("one", in: directory))
        #expect(try await LocalFileTokenStore(directory: directory).load(account: "one") == fixtureTokens)
        try await store.save(fixtureTokens, account: "one")
        #expect(first != (try Data(contentsOf: tokenURL("one", in: directory))))
        #expect(try permissions(directory) == 0o700)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try permissions(url) == 0o600)
            let data = try Data(contentsOf: url)
            #expect(data.range(of: Data(fixtureTokens.accessToken.utf8)) == nil)
            #expect(data.range(of: Data(fixtureTokens.refreshToken!.utf8)) == nil)
            #expect(url.pathExtension != "tmp")
        }
    }

    @Test func bindsCiphertextToAccountAndHashesUntrustedAccountNames() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        let hostileAccount = "../../elsewhere/凭据"
        try await store.save(fixtureTokens, account: hostileAccount)
        let other = AuthTokens(accessToken: "another-fixture", userID: "different-user")
        try await store.save(other, account: "other")
        #expect(try await store.load(account: hostileAccount) == fixtureTokens)
        #expect(try await store.load(account: "other") == other)
        let cipher = try Data(contentsOf: tokenURL(hostileAccount, in: directory))
        try cipher.write(to: tokenURL("other", in: directory))
        await #expect(throws: LocalCredentialError.invalidCredentials) { try await store.load(account: "other") }
        #expect(try await store.load(account: hostileAccount) == fixtureTokens)
    }

    @Test func refusesTamperingAndPreservesDamagedFiles() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        let url = tokenURL("one", in: directory)
        var data = try Data(contentsOf: url); data[data.count - 1] ^= 0x01
        try data.write(to: url)
        await #expect(throws: LocalCredentialError.invalidCredentials) { try await store.load(account: "one") }
        #expect(try Data(contentsOf: url) == data)
        try await store.save(fixtureTokens, account: "one")
        #expect(try await store.load(account: "one") == fixtureTokens)
    }

    @Test func missingOrTruncatedKeyNeverOverwritesExistingCredentials() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        let before = try Data(contentsOf: tokenURL("one", in: directory))
        let keyURL = directory.appendingPathComponent("master.key")
        let key = try Data(contentsOf: keyURL)
        try FileManager.default.removeItem(at: keyURL)
        await #expect(throws: LocalCredentialError.missingKey) { try await store.load(account: "one") }
        await #expect(throws: LocalCredentialError.missingKey) { try await store.save(fixtureTokens, account: "different-account") }
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(try Data(contentsOf: tokenURL("one", in: directory)) == before)
        try Data(key.prefix(4)).write(to: keyURL)
        await #expect(throws: LocalCredentialError.invalidCredentials) { try await store.save(fixtureTokens, account: "one") }
        #expect(try Data(contentsOf: keyURL).count == 4)
        #expect(try Data(contentsOf: tokenURL("one", in: directory)) == before)
    }

    @Test func conditionalDeletionKeepsNewerAndOtherAccountTokens() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        let newer = AuthTokens(accessToken: "new-fixture")
        try await store.save(newer, account: "one")
        try await store.save(fixtureTokens, account: "two")
        try await store.remove(account: "one", matching: fixtureTokens)
        #expect(try await store.load(account: "one") == newer)
        try await store.remove(account: "one", matching: newer)
        #expect(try await store.load(account: "one") == nil)
        #expect(try await store.load(account: "two") == fixtureTokens)
        try await store.remove(account: "two")
        #expect(try await store.load(account: "two") == nil)
    }

    @Test func rejectsSymlinksAndFIFOsWithoutOpeningTheirContent() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        let url = tokenURL("one", in: directory)
        let original = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("master.key"))
        await #expect(throws: (any Error).self) { try await store.load(account: "one") }
        await #expect(throws: (any Error).self) { try await store.save(fixtureTokens, account: "one") }
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        await #expect(throws: LocalCredentialError.invalidStorage) { try await store.load(account: "one") }
        try FileManager.default.removeItem(at: url)
        try original.write(to: url)
        #expect(try await store.load(account: "one") == fixtureTokens)
    }

    @Test func refusesSymlinkDirectoryAndHardLinkedKey() async throws {
        let directory = credentialsDirectory(), link = credentialsDirectory()
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        await #expect(throws: (any Error).self) { try await LocalFileTokenStore(directory: link).load(account: "one") }
        try FileManager.default.linkItem(at: directory.appendingPathComponent("master.key"), to: directory.appendingPathComponent("key-link"))
        await #expect(throws: LocalCredentialError.invalidStorage) { try await store.load(account: "one") }
    }

    @Test func repairsOverlyBroadOwnedFilePermissions() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        #expect(try await store.load(account: "one") == fixtureTokens)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(directory.appendingPathComponent("master.key")) == 0o600)
        #expect(try permissions(tokenURL("one", in: directory)) == 0o600)
    }

    @Test func removesExistingACLGrantsFromCredentialsAndOwnedDirectory() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try addReadACL(directory)
        for file in files { try addReadACL(file); #expect(try hasExtendedACL(file)) }
        #expect(try hasExtendedACL(directory))
        #expect(try await store.load(account: "one") == fixtureTokens)
        #expect(try !hasExtendedACL(directory))
        #expect(try permissions(directory) == 0o700)
        for file in files {
            #expect(try !hasExtendedACL(file))
            #expect(try permissions(file) == 0o600)
        }
    }

    @Test func removesInheritedACLBeforeCreatingCredentialFilesWithoutChangingParent() async throws {
        let parent = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try addReadACL(parent, inheritable: true)
        let directory = parent.appendingPathComponent("Credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try hasExtendedACL(parent))
        #expect(try hasExtendedACL(directory))
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        #expect(try await store.load(account: "one") == fixtureTokens)
        #expect(try hasExtendedACL(parent))
        #expect(try permissions(parent) == 0o700)
        #expect(try !hasExtendedACL(directory))
        #expect(try permissions(directory) == 0o700)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            #expect(try !hasExtendedACL(file))
            #expect(try permissions(file) == 0o600)
        }
    }

    @Test func lockedDirectoryReturnsPromptlyAndDoesNotChangeKey() async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalFileTokenStore(directory: directory)
        try await store.save(fixtureTokens, account: "one")
        let keyURL = directory.appendingPathComponent("master.key"), key = try Data(contentsOf: keyURL)
        let descriptor = Darwin.open(directory.appendingPathComponent(".lock").path, O_RDWR)
        #expect(descriptor >= 0); defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: LocalCredentialError.busy) { try await LocalFileTokenStore(directory: directory).save(fixtureTokens, account: "two") }
        #expect(try Data(contentsOf: keyURL) == key)
        #expect(flock(descriptor, LOCK_UN) == 0)
        try await LocalFileTokenStore(directory: directory).save(fixtureTokens, account: "two")
        #expect(try await store.load(account: "one") == fixtureTokens)
        #expect(try await store.load(account: "two") == fixtureTokens)
    }

    // Each case starts without .lock, exercising concurrent first creation rather
    // than only contention on a previously opened lock file.
    @Test(arguments: 0..<16) func competingStoreInstancesKeepOneUsableKey(round: Int) async throws {
        let directory = credentialsDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let store = LocalFileTokenStore(directory: directory)
                    for _ in 0..<100 {
                        do { try await store.save(fixtureTokens, account: String(index)); return }
                        catch LocalCredentialError.busy { try await Task.sleep(for: .milliseconds(5)) }
                    }
                    throw LocalCredentialError.busy
                }
            }
            try await group.waitForAll()
        }
        let store = LocalFileTokenStore(directory: directory)
        for index in 0..<6 { #expect(try await store.load(account: String(index)) == fixtureTokens) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("master.key")).count == 32)
    }
}
