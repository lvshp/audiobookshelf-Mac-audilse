import CryptoKit
import Darwin
import Foundation

public enum LocalCredentialError: Error, LocalizedError, Sendable, Equatable {
    case invalidStorage
    case invalidCredentials
    case missingKey
    case busy
    case io(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidStorage: "本地凭据目录或文件不安全，已停止读取。"
        case .invalidCredentials: "本地凭据文件无法解密，请重新登录或检查本地凭据备份。"
        case .missingKey: "本地凭据加密密钥缺失，已保留原有凭据文件。"
        case .busy: "另一个 ShelfMac 进程正在使用本地凭据，请稍后重试。"
        case .io(let code): "无法读写本地凭据（\(code)）。"
        }
    }
}

/// The encryption key and ciphertext stay on this Mac. Filesystem permissions
/// are the access boundary; this does not protect against software running as
/// the same user that can read both files.
public actor LocalFileTokenStore: TokenStore {
    public static let shared = LocalFileTokenStore()
    private let directory: URL
    private let keyName = "master.key"
    private let maximumFileSize = 1_048_576

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }
    private static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ShelfMac/Credentials", isDirectory: true)
    }

    public func load(account: String) throws -> AuthTokens? {
        guard let descriptor = try openDirectory(create: false) else { return nil }
        defer { close(descriptor) }
        return try withLock(descriptor) { try load(account: account, directoryFD: descriptor) }
    }

    public func save(_ tokens: AuthTokens, account: String) throws {
        guard let descriptor = try openDirectory(create: true) else { throw LocalCredentialError.invalidStorage }
        defer { close(descriptor) }
        try withLock(descriptor) {
            let key = try encryptionKey(directoryFD: descriptor, create: true)
            let payload = try JSONEncoder().encode(tokens)
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: authenticationData(account))
            guard let combined = sealed.combined else { throw LocalCredentialError.invalidCredentials }
            var data = Data([1]); data.append(combined)
            guard data.count <= maximumFileSize else { throw LocalCredentialError.invalidCredentials }
            try writeAtomically(data, name: filename(account), directoryFD: descriptor)
        }
    }

    public func remove(account: String) throws {
        guard let descriptor = try openDirectory(create: false) else { return }
        defer { close(descriptor) }
        try withLock(descriptor) { try removeFile(filename(account), directoryFD: descriptor) }
    }

    public func remove(account: String, matching tokens: AuthTokens) throws {
        guard let descriptor = try openDirectory(create: false) else { return }
        defer { close(descriptor) }
        // No suspension between comparison and deletion; the file lock also
        // protects this operation from another store instance or process.
        try withLock(descriptor) {
            if try load(account: account, directoryFD: descriptor) == tokens {
                try removeFile(filename(account), directoryFD: descriptor)
            }
        }
    }

    private func filename(_ account: String) -> String {
        "token-" + SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined() + ".credential"
    }
    private func authenticationData(_ account: String) -> Data { Data(("ShelfMac.Credentials.v1:" + account).utf8) }

    private func load(account: String, directoryFD: Int32) throws -> AuthTokens? {
        guard let data = try readFile(filename(account), directoryFD: directoryFD) else { return nil }
        let key = try encryptionKey(directoryFD: directoryFD, create: false)
        do {
            guard data.first == 1 else { throw LocalCredentialError.invalidCredentials }
            let sealed = try AES.GCM.SealedBox(combined: data.dropFirst())
            let payload = try AES.GCM.open(sealed, using: key, authenticating: authenticationData(account))
            return try JSONDecoder().decode(AuthTokens.self, from: payload)
        } catch { throw LocalCredentialError.invalidCredentials }
    }

    private func encryptionKey(directoryFD: Int32, create: Bool) throws -> SymmetricKey {
        if let data = try readFile(keyName, directoryFD: directoryFD) {
            guard data.count == 32 else { throw LocalCredentialError.invalidCredentials }
            return SymmetricKey(data: data)
        }
        guard create, try !containsCredentials(directoryFD: directoryFD) else { throw LocalCredentialError.missingKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try writeAtomically(data, name: keyName, directoryFD: directoryFD)
        return key
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard directory.isFileURL else { throw LocalCredentialError.invalidStorage }
        if create {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw LocalCredentialError.io((error as NSError).code == NSFileWriteNoPermissionError ? EACCES : EIO) }
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT, !create { return nil }
            throw LocalCredentialError.io(errno)
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw LocalCredentialError.io(errno) }
            guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw LocalCredentialError.invalidStorage }
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
        guard lockFD >= 0 else { throw LocalCredentialError.io(errno) }
        defer { close(lockFD) }
        try validate(lockFD)
        // Never wait indefinitely on a lock held by another process.
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw LocalCredentialError.busy }
            throw LocalCredentialError.io(errno)
        }
        defer { flock(lockFD, LOCK_UN) }
        return try operation()
    }

    private func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LocalCredentialError.io(errno) }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw LocalCredentialError.invalidStorage }
        try makePrivate(descriptor, mode: 0o600)
        guard info.st_size >= 0, info.st_size <= maximumFileSize else { throw LocalCredentialError.invalidStorage }
    }

    private func makePrivate(_ descriptor: Int32, mode: mode_t) throws {
        // chmod does not remove macOS ACL grants, including inherited grants.
        // Only operate on the owned directory/regular-file descriptor validated
        // by the caller, preserving all parent-directory permissions.
        guard let acl = acl_init(0) else { throw LocalCredentialError.io(errno) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else { throw LocalCredentialError.io(errno) }
        guard fchmod(descriptor, mode) == 0 else { throw LocalCredentialError.io(errno) }
    }

    private func readFile(_ name: String, directoryFD: Int32) throws -> Data? {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw LocalCredentialError.io(errno)
        }
        defer { close(descriptor) }
        try validate(descriptor)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw LocalCredentialError.io(errno) }
            if count == 0 { return data }
            guard data.count + count <= maximumFileSize else { throw LocalCredentialError.invalidStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAtomically(_ data: Data, name: String, directoryFD: Int32) throws {
        // Reject an existing symlink/non-regular destination before replacing it.
        _ = try readFile(name, directoryFD: directoryFD)
        let temporary = "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalCredentialError.io(errno) }
        defer { close(descriptor); unlinkat(directoryFD, temporary, 0) }
        try validate(descriptor)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw LocalCredentialError.io(errno) }
                guard count > 0 else { throw LocalCredentialError.io(EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw LocalCredentialError.io(errno) }
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw LocalCredentialError.io(errno) }
        guard fsync(directoryFD) == 0 else { throw LocalCredentialError.io(errno) }
    }

    private func removeFile(_ name: String, directoryFD: Int32) throws {
        guard try readFile(name, directoryFD: directoryFD) != nil else { return }
        guard unlinkat(directoryFD, name, 0) == 0 else { throw LocalCredentialError.io(errno) }
        guard fsync(directoryFD) == 0 else { throw LocalCredentialError.io(errno) }
    }

    private func containsCredentials(directoryFD: Int32) throws -> Bool {
        let copy = dup(directoryFD)
        guard copy >= 0 else { throw LocalCredentialError.io(errno) }
        guard let stream = fdopendir(copy) else { close(copy); throw LocalCredentialError.io(errno) }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            var rawName = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: rawName)
            let name = withUnsafePointer(to: &rawName) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name.hasPrefix("token-"), name.hasSuffix(".credential") { return true }
            errno = 0
        }
        if errno != 0 { throw LocalCredentialError.io(errno) }
        return false
    }
}
