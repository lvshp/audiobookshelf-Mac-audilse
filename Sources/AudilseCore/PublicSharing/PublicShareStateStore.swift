import CryptoKit
import Darwin
import Foundation

/// Payloads are anonymous state only. Implementations must not use an account token store.
public protocol PublicShareStateStore: Sendable {
    func load(key: String) async throws -> Data?
    /// Compare the previous plaintext under the same file lock as replacement/removal.
    func compareAndSwap(key: String, expected: Data?, replacement: Data?) async throws -> Bool
}
public actor MemoryPublicShareStateStore: PublicShareStateStore {
    private var values: [String: Data] = [:]
    public init() {}
    public func load(key: String) -> Data? { values[key] }
    public func compareAndSwap(key: String, expected: Data?, replacement: Data?) -> Bool {
        guard values[key] == expected else { return false }
        values[key] = replacement; return true
    }
}
public enum PublicShareStorageError: Error, Sendable, Equatable {
    case invalidStorage, invalidState, missingKey, busy
    case io(Int32)
}

/// Independent anonymous namespace; descriptor/ACL/atomic-write policy mirrors
/// LocalFileTokenStore, but no account tokens or account storage are accessed.
/// The local key protects at-rest state; same-user software can read key and data.
public actor LocalPublicShareStateStore: PublicShareStateStore {
    public static let shared = LocalPublicShareStateStore()
    private let directory: URL
    private let keyName = "master.key"
    private let maximumFileSize = 1_048_576
    public init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directory = directory ?? support.appendingPathComponent("Audilse/PublicShares", isDirectory: true)
    }
    public func load(key: String) throws -> Data? {
        guard let descriptor = try openDirectory(create: false) else { return nil }
        defer { close(descriptor) }
        return try withLock(descriptor) { try load(account: key, directoryFD: descriptor) }
    }
    public func compareAndSwap(key: String, expected: Data?, replacement: Data?) throws -> Bool {
        guard let descriptor = try openDirectory(create: replacement != nil) else { return expected == nil }
        defer { close(descriptor) }
        return try withLock(descriptor) {
            guard try load(account: key, directoryFD: descriptor) == expected else { return false }
            guard let replacement else { try removeFile(filename(key), directoryFD: descriptor); return true }
            guard replacement.count <= maximumFileSize - 64 else { throw PublicShareStorageError.invalidState }
            let encryption = try encryptionKey(directoryFD: descriptor, create: true)
            let sealed = try AES.GCM.seal(replacement, using: encryption, authenticating: authenticationData(key))
            guard let combined = sealed.combined else { throw PublicShareStorageError.invalidState }
            var data = Data([1]); data.append(combined)
            try writeAtomically(data, name: filename(key), directoryFD: descriptor)
            return true
        }
    }
    private func filename(_ account: String) -> String {
        "share-" + SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined() + ".state"
    }
    private func authenticationData(_ account: String) -> Data { Data(("Audilse.PublicShares.v1:" + account).utf8) }

    private func load(account: String, directoryFD: Int32) throws -> Data? {
        guard let data = try readFile(filename(account), directoryFD: directoryFD) else { return nil }
        let key = try encryptionKey(directoryFD: directoryFD, create: false)
        do {
            guard data.first == 1 else { throw PublicShareStorageError.invalidState }
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst()), using: key, authenticating: authenticationData(account))
        } catch { throw PublicShareStorageError.invalidState }
    }

    private func encryptionKey(directoryFD: Int32, create: Bool) throws -> SymmetricKey {
        if let data = try readFile(keyName, directoryFD: directoryFD) {
            guard data.count == 32 else { throw PublicShareStorageError.invalidState }
            return SymmetricKey(data: data)
        }
        guard create, try !containsStates(directoryFD: directoryFD) else { throw PublicShareStorageError.missingKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try writeAtomically(data, name: keyName, directoryFD: directoryFD)
        return key
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL else { throw PublicShareStorageError.invalidStorage }
        if create {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw PublicShareStorageError.io((error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO) }
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT, !create { return nil }
            throw PublicShareStorageError.io(errno)
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw PublicShareStorageError.io(errno) }
            guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PublicShareStorageError.invalidStorage }
            try makePrivate(descriptor, mode: 0o700)
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private func withLock<T>(_ directoryFD: Int32, operation: () throws -> T) throws -> T {
        // Concurrent O_CREAT | O_NOFOLLOW opens can return ENOENT on Darwin
        // while another caller publishes the new file. Separate exclusive
        // creation from opening an existing lock; neither path follows links.
        var lockFD = openat(directoryFD, ".lock", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if lockFD < 0, errno == EEXIST {
            lockFD = openat(directoryFD, ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        }
        guard lockFD >= 0 else { throw PublicShareStorageError.io(errno) }
        defer { close(lockFD) }
        try validate(lockFD)
        // Never wait indefinitely on a lock held by another process.
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw PublicShareStorageError.busy }
            throw PublicShareStorageError.io(errno)
        }
        defer { flock(lockFD, LOCK_UN) }
        return try operation()
    }

    private func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw PublicShareStorageError.io(errno) }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw PublicShareStorageError.invalidStorage }
        try makePrivate(descriptor, mode: 0o600)
        guard info.st_size >= 0, info.st_size <= maximumFileSize else { throw PublicShareStorageError.invalidStorage }
    }

    private func makePrivate(_ descriptor: Int32, mode: mode_t) throws {
        // chmod does not remove macOS ACL grants, including inherited grants.
        // Only operate on the owned directory/regular-file descriptor validated
        // by the caller, preserving all parent-directory permissions.
        guard let acl = acl_init(0) else { throw PublicShareStorageError.io(errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw PublicShareStorageError.io(errno) }
        guard fchmod(descriptor, mode) == 0 else { throw PublicShareStorageError.io(errno) }
    }

    private func readFile(_ name: String, directoryFD: Int32) throws -> Data? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw PublicShareStorageError.io(errno)
        }
        defer { close(descriptor) }
        try validate(descriptor)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw PublicShareStorageError.io(errno) }
            if count == 0 { return data }
            guard data.count + count <= maximumFileSize else { throw PublicShareStorageError.invalidStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAtomically(_ data: Data, name: String, directoryFD: Int32) throws {
        // Reject an existing symlink/non-regular destination before replacing it.
        _ = try readFile(name, directoryFD: directoryFD)
        let temporary = "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw PublicShareStorageError.io(errno) }
        defer { close(descriptor); unlinkat(directoryFD, temporary, 0) }
        try validate(descriptor)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw PublicShareStorageError.io(errno) }
                guard count > 0 else { throw PublicShareStorageError.io(EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw PublicShareStorageError.io(errno) }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw PublicShareStorageError.io(errno) }
        guard fsync(directoryFD) == 0 else { throw PublicShareStorageError.io(errno) }
    }

    private func removeFile(_ name: String, directoryFD: Int32) throws {
        guard try readFile(name, directoryFD: directoryFD) != nil else { return }
        guard unlinkat(directoryFD, name, 0) == 0 else { throw PublicShareStorageError.io(errno) }
        guard fsync(directoryFD) == 0 else { throw PublicShareStorageError.io(errno) }
    }

    private func containsStates(directoryFD: Int32) throws -> Bool {
        let copy = dup(directoryFD)
        guard copy >= 0 else { throw PublicShareStorageError.io(errno) }
        guard let stream = fdopendir(copy) else { close(copy); throw PublicShareStorageError.io(errno) }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            var rawName = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name.hasPrefix("share-"), name.hasSuffix(".state") { return true }
            errno = 0
        }
        if errno != 0 { throw PublicShareStorageError.io(errno) }
        return false
    }
}
