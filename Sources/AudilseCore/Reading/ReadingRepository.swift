import Foundation
import GRDB

public actor ReadingRepository {
    public let rootDirectory: URL
    private let queue: DatabaseQueue
    private let restoreEpochs: [String: String]
    private let session: URLSession
    private var syncing = false
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []

    public init(rootDirectory: URL, session: URLSession = URLSession(configuration: .ephemeral)) throws {
        self.rootDirectory = rootDirectory
        self.session = session
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: rootDirectory.appendingPathComponent("Reading.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("reading-v1") { db in
            for name in ["ebookFile", "readingPosition"] {
                try db.create(table: name) { table in
                    table.column("serverID", .text).notNull(); table.column("userID", .text).notNull()
                    table.column("itemID", .text).notNull(); table.column("payload", .blob).notNull()
                    table.column("pending", .boolean).notNull().defaults(to: false)
                    table.primaryKey(["serverID", "userID", "itemID"])
                }
            }
        }
        migrator.registerMigration("reading-v2-server-restore-archive", migrate: RestoreArchiveSQL.migrate)
        migrator.registerMigration("reading-v3-selected-files") { db in
            // Explicit-file reading never enters the main ebook's server-sync queue.
            // Keep the real book ID as data instead of inventing a synthetic book ID.
            for name in ["ebookOriginal", "selectedReadingPosition"] {
                try db.create(table: name) { table in
                    table.column("serverID", .text).notNull(); table.column("userID", .text).notNull()
                    table.column("itemID", .text).notNull(); table.column("ino", .text).notNull()
                    table.column("payload", .blob).notNull()
                    table.primaryKey(["serverID", "userID", "itemID", "ino"])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT serverID,userID,itemID,payload FROM ebookFile") {
                let payload: Data = row["payload"]
                guard let file = try? JSONDecoder().decode(CachedEbook.self, from: payload), !file.ino.isEmpty else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO ebookOriginal(serverID,userID,itemID,ino,payload) VALUES (?,?,?,?,?)", arguments: [row["serverID"] as String, row["userID"] as String, row["itemID"] as String, file.ino, payload])
            }
        }
        try migrator.migrate(queue)
        restoreEpochs = try queue.read(RestoreArchiveSQL.epochs)
    }

    public func beginServerRestore(_ batch: ServerRestoreBatch) throws -> ServerRestoreBatch {
        try queue.write { db in
            let existing = try RestoreArchiveSQL.batch(db, batch.id)
            if existing == nil, batch.state != .collecting { throw ServerRestoreArchiveError.incompleteArchive }
            // A receipt from the other database cannot stand in for this database's commit.
            var local = batch; local.readingReceipt = existing?.readingReceipt
            return try RestoreArchiveSQL.begin(local, db)
        }
    }

    /// Quarantine every server-syncable position, including acknowledged checkpoints.
    /// Original descriptors/files and explicit MOBI/AZW3 local-only positions remain intact.
    public func archiveForServerRestore(batch: ServerRestoreBatch) throws -> ServerRestoreArchiveReceipt {
        try queue.write { db in
            guard var local = try RestoreArchiveSQL.batch(db, batch.id) else { throw ServerRestoreArchiveError.missingBatch }
            guard local.canonicalBaseURL == batch.canonicalBaseURL, local.profileIDs == batch.profileIDs else { throw ServerRestoreArchiveError.scopeChanged }
            if let old = local.readingReceipt, old.profileIDs == local.profileIDs { return old }
            guard local.state == .collecting else { throw ServerRestoreArchiveError.scopeChanged }
            let sealed = Set(local.readingReceipt?.profileIDs ?? [])
            for id in local.profileIDs where !sealed.contains(id) {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM readingPosition WHERE serverID=?", arguments: [id.uuidString])
                for row in rows {
                    let payload: Data = row["payload"]
                    // Preserve only formats whose lack of server progress is known. Unknown or
                    // malformed rows are archived opaquely rather than silently left to sync.
                    let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                    let format = json?["format"] as? String
                    if format == "mobi" || format == "azw3" { continue }
                    let user: String = row["userID"]; let key: String = row["itemID"]
                    try db.execute(sql: "INSERT INTO serverRestoreArchiveRow(batchID,category,serverID,userID,rowKey,payload,pending) VALUES (?,'reading.readingPosition',?,?,?,?,?)", arguments: [local.id.uuidString, id.uuidString, user, key, payload, row["pending"] as Bool])
                    try db.execute(sql: "DELETE FROM readingPosition WHERE serverID=? AND userID=? AND itemID=?", arguments: [id.uuidString, user, key])
                }
                try RestoreArchiveSQL.advance(db, id: id, batch: local.id)
            }
            let receipt = try RestoreArchiveSQL.receipt(db, batch: local, store: .reading, profileIDs: local.profileIDs)
            local.readingReceipt = receipt
            try RestoreArchiveSQL.put(local, db); return receipt
        }
    }

    /// Reconcile this local barrier after the authoritative main database is completed.
    /// Idempotent, so a crash between the two commits is repaired on the next startup.
    public func completeServerRestore(batch: ServerRestoreBatch) throws {
        try queue.write { db in
            guard var local = try RestoreArchiveSQL.batch(db, batch.id) else { throw ServerRestoreArchiveError.missingBatch }
            guard batch.state == .completed, local.canonicalBaseURL == batch.canonicalBaseURL,
                  local.profileIDs == batch.profileIDs,
                  let audio = batch.audioReceipt, RestoreArchiveSQL.matches(audio, batch: batch, store: .shelf),
                  let reading = batch.readingReceipt, RestoreArchiveSQL.matches(reading, batch: batch, store: .reading),
                  reading == local.readingReceipt else { throw ServerRestoreArchiveError.incompleteArchive }
            local = batch; try RestoreArchiveSQL.put(local, db)
        }
    }

    public func archiveSnapshot(batchID: UUID) throws -> ServerRestoreArchiveSnapshot {
        try queue.read { db in
            guard let batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            return .init(schemaVersion: 1, batch: batch, receipts: [batch.readingReceipt].compactMap { $0 }, entries: try RestoreArchiveSQL.entries(db, batchID: batchID))
        }
    }

    private func checkAccess(_ partition: AccountPartition) throws {
        try queue.read { try RestoreArchiveSQL.check($0, partition: partition, expectedEpochs: restoreEpochs, store: .reading) }
    }

    public func cachedFile(itemID: String, partition: AccountPartition) throws -> CachedEbook? {
        try load(CachedEbook.self, table: "ebookFile", itemID: itemID, partition: partition)
    }

    public func cachedFile(itemID: String, fileIno: String, partition: AccountPartition) throws -> CachedEbook? {
        try selectedValue(CachedEbook.self, table: "ebookOriginal", itemID: itemID, ino: fileIno, partition: partition)
    }

    /// An explicit file ID follows ABS's supplemental-reader contract: the selected
    /// original is read without changing primary status or shared ebook progress.
    public func original(item: LibraryItem, fileIno: String? = nil, partition: AccountPartition, client: ABSClient?) async throws -> (CachedEbook, URL) {
        try checkAccess(partition)
        try Task.checkCancellation()
        let ebook: MediaFile
        if let fileIno {
            guard !fileIno.isEmpty, let selected = item.libraryFiles.first(where: { $0.ino == fileIno }) ?? (item.media.ebookFile?.ino == fileIno ? item.media.ebookFile : nil) else { throw ReadingError.noEbook }
            ebook = selected
        } else {
            guard let primary = item.media.ebookFile else { throw ReadingError.noEbook }
            ebook = primary
        }
        let format = try EbookFormat(filename: ebook.metadata.filename)
        if let cached = try cachedFile(itemID: item.id, fileIno: ebook.ino, partition: partition), cached.ino == ebook.ino,
           cached.format == format, ebook.metadata.size == nil || ebook.metadata.size == cached.bytes,
           let url = try? validFile(cached) { return (cached, url) }
        guard let client else { throw ReadingError.unavailableOffline }
        let context = try await client.originalFileContext(partition: partition)
        let path = "api/items/\(ServerEndpoint.component(item.id))/ebook" + (fileIno.map { "/" + ServerEndpoint.component($0) } ?? "")
        var request = try await client.authorizedRequest(path: path)
        request.httpShouldHandleCookies = false
        try checkAccess(partition); try Task.checkCancellation()
        let endpoint = try ServerEndpoint(baseURL: await client.profile.baseURL)
        try checkAccess(partition); try Task.checkCancellation()
        let (temporary, response) = try await session.download(for: request, delegate: ReadingRedirectDelegate(endpoint: endpoint, authorization: request.value(forHTTPHeaderField: "Authorization")))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await client.validateOriginalFileContext(context)
        try checkAccess(partition); try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let bytes = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value,
              bytes > 0, ebook.metadata.size == nil || ebook.metadata.size == bytes else { throw ReadingError.invalidDownload }
        let relative = partition.directoryName + "/" + UUID().uuidString.lowercased() + "." + format.rawValue
        let final = try DownloadPaths.safeURL(relativePath: relative, root: rootDirectory)
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: final)
        let descriptor = CachedEbook(itemID: item.id, ino: ebook.ino, format: format, filename: ebook.metadata.filename, relativePath: relative, bytes: bytes)
        do {
            try saveSelected(descriptor, table: "ebookOriginal", itemID: item.id, ino: ebook.ino, partition: partition)
            if fileIno == nil { try save(descriptor, table: "ebookFile", itemID: item.id, pending: false, partition: partition) }
        } catch { try? FileManager.default.removeItem(at: final); throw error }
        return (descriptor, final)
    }

    public func validFile(_ file: CachedEbook) throws -> URL {
        let url = try DownloadPaths.safeURL(relativePath: file.relativePath, root: rootDirectory)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? 0) == file.bytes, file.bytes > 0 else { throw ReadingError.invalidDownload }
        return url
    }

    public func position(itemID: String, partition: AccountPartition) throws -> ReadingCheckpoint? {
        try load(ReadingCheckpoint.self, table: "readingPosition", itemID: itemID, partition: partition)
    }

    public func position(itemID: String, fileIno: String, partition: AccountPartition) throws -> ReadingCheckpoint? {
        try selectedValue(ReadingCheckpoint.self, table: "selectedReadingPosition", itemID: itemID, ino: fileIno, partition: partition)
    }

    public func checkpoint(_ checkpoint: ReadingCheckpoint, fileIno: String, partition: AccountPartition) throws {
        guard !fileIno.isEmpty, checkpoint.progress.isFinite, checkpoint.updatedAt.isFinite else { throw ReadingError.invalidDownload }
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading, collectingWrite: true)
            let old = try Data.fetchOne(db, sql: "SELECT payload FROM selectedReadingPosition WHERE serverID=? AND userID=? AND itemID=? AND ino=?", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID, fileIno])
            if let old, try JSONDecoder().decode(ReadingCheckpoint.self, from: old).updatedAt > checkpoint.updatedAt { return }
            try db.execute(sql: "INSERT INTO selectedReadingPosition(serverID,userID,itemID,ino,payload) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,itemID,ino) DO UPDATE SET payload=excluded.payload", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID, fileIno, try Self.encode(checkpoint)])
        }
    }

    public func checkpoint(_ checkpoint: ReadingCheckpoint, partition: AccountPartition) throws {
        guard checkpoint.progress.isFinite, checkpoint.updatedAt.isFinite else { throw ReadingError.invalidDownload }
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading, collectingWrite: true)
            var saved = checkpoint
            if let row = try Row.fetchOne(db, sql: "SELECT payload,pending FROM readingPosition WHERE serverID=? AND userID=? AND itemID=?", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID]) {
                let old = try JSONDecoder().decode(ReadingCheckpoint.self, from: row["payload"] as Data)
                if old.updatedAt > checkpoint.updatedAt { return }
                if row["pending"] as Bool {
                    saved = ReadingCheckpoint(itemID: checkpoint.itemID, format: checkpoint.format, location: checkpoint.location, progress: checkpoint.progress, updatedAt: checkpoint.updatedAt, baselineLocation: old.baselineLocation, baselineProgress: old.baselineProgress, baselineUpdatedAt: old.baselineUpdatedAt)
                }
            }
            try db.execute(sql: "INSERT INTO readingPosition(serverID,userID,itemID,payload,pending) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,itemID) DO UPDATE SET payload=excluded.payload,pending=excluded.pending", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID, try Self.encode(saved), checkpoint.format.supportsServerProgress])
        }
    }

    public func pending(partition: AccountPartition) throws -> [ReadingCheckpoint] {
        let rows = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading)
            return try Data.fetchAll(db, sql: "SELECT payload FROM readingPosition WHERE serverID=? AND userID=? AND pending=1", arguments: [partition.serverID.uuidString, partition.userID])
        }
        return try rows.map { try JSONDecoder().decode(ReadingCheckpoint.self, from: $0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func synchronize(partition: AccountPartition, client: ABSClient,
                            authorize: (@Sendable () async throws -> Void)? = nil) async throws -> [ReadingConflict] {
        try await requireSynchronizationAccess(partition, authorize: authorize)
        await beginSynchronization()
        defer { endSynchronization() }
        try await requireSynchronizationAccess(partition, authorize: authorize)
        var conflicts: [ReadingConflict] = []
        for checkpoint in try pending(partition: partition) {
            try await requireSynchronizationAccess(partition, authorize: authorize)
            let remote = try await client.progress(itemID: checkpoint.itemID)
            try await requireSynchronizationAccess(partition, authorize: authorize)
            if let remote, Self.hasConflict(local: checkpoint, remote: remote) {
                conflicts.append(ReadingConflict(local: checkpoint, remote: remote)); continue
            }
            try await client.updateReadingProgress(itemID: checkpoint.itemID, location: checkpoint.location, progress: checkpoint.progress)
            // An uncertain write is never replayed here. Losing the caller's source
            // leaves its durable checkpoint pending for a later explicit sync.
            try await requireSynchronizationAccess(partition, authorize: authorize)
            let verified = try await client.progress(itemID: checkpoint.itemID)
            try await requireSynchronizationAccess(partition, authorize: authorize)
            guard let saved = verified, saved.ebookLocation == checkpoint.location,
                  abs((saved.ebookProgress ?? 0) - checkpoint.progress) < 0.002 else { throw OfflineSyncError.verificationFailed }
            try acknowledge(checkpoint, remote: saved, partition: partition)
        }
        return conflicts
    }

    private func requireSynchronizationAccess(_ partition: AccountPartition,
                                              authorize: (@Sendable () async throws -> Void)?) async throws {
        try Task.checkCancellation()
        try checkAccess(partition)
        try await authorize?()
        try Task.checkCancellation()
        try checkAccess(partition)
    }

    public func resolve(_ conflict: ReadingConflict, useLocal: Bool, partition: AccountPartition, client: ABSClient,
                        authorize: (@Sendable () async throws -> Void)? = nil) async throws {
        try await requireSynchronizationAccess(partition, authorize: authorize)
        await beginSynchronization()
        defer { endSynchronization() }
        try await requireSynchronizationAccess(partition, authorize: authorize)
        let current = try await client.progress(itemID: conflict.local.itemID)
        try await requireSynchronizationAccess(partition, authorize: authorize)
        if let current, (current.ebookLocation != conflict.remote.ebookLocation || abs((current.ebookProgress ?? 0) - (conflict.remote.ebookProgress ?? 0)) > 0.002),
           (current.lastUpdate ?? 0) > (conflict.remote.lastUpdate ?? 0) { throw ReadingError.sourceChanged }
        if useLocal {
            let local = try position(itemID: conflict.local.itemID, partition: partition) ?? conflict.local
            try await client.updateReadingProgress(itemID: local.itemID, location: local.location, progress: local.progress)
            try await requireSynchronizationAccess(partition, authorize: authorize)
            let verified = try await client.progress(itemID: local.itemID)
            try await requireSynchronizationAccess(partition, authorize: authorize)
            guard let saved = verified, saved.ebookLocation == local.location else { throw OfflineSyncError.verificationFailed }
            try acknowledge(local, remote: saved, partition: partition)
        } else {
            let replacement = ReadingCheckpoint(itemID: conflict.local.itemID, format: conflict.local.format, location: conflict.remote.ebookLocation ?? "", progress: conflict.remote.ebookProgress ?? 0, baselineLocation: conflict.remote.ebookLocation, baselineProgress: conflict.remote.ebookProgress, baselineUpdatedAt: conflict.remote.lastUpdate)
            // Do not replace a position advanced while the conflict dialog was open.
            if try position(itemID: conflict.local.itemID, partition: partition) == conflict.local {
                try save(replacement, table: "readingPosition", itemID: replacement.itemID, pending: false, partition: partition)
            }
        }
    }

    public static func hasConflict(local: ReadingCheckpoint, remote: MediaProgress) -> Bool {
        let changed = remote.ebookLocation != local.baselineLocation || abs((remote.ebookProgress ?? 0) - (local.baselineProgress ?? 0)) > 0.002
        let same = remote.ebookLocation == local.location && abs((remote.ebookProgress ?? 0) - local.progress) < 0.002
        return changed && !same && (remote.lastUpdate ?? 0) > (local.baselineUpdatedAt ?? 0)
    }

    private func beginSynchronization() async {
        while syncing { await withCheckedContinuation { syncWaiters.append($0) } }
        syncing = true
    }
    private func endSynchronization() {
        syncing = false
        let waiters = syncWaiters
        syncWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func acknowledge(_ checkpoint: ReadingCheckpoint, remote: MediaProgress, partition: AccountPartition) throws {
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading)
            guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM readingPosition WHERE serverID=? AND userID=? AND itemID=?", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID]) else { return }
            let current = try JSONDecoder().decode(ReadingCheckpoint.self, from: payload)
            if current == checkpoint {
                try db.execute(sql: "UPDATE readingPosition SET pending=0 WHERE serverID=? AND userID=? AND itemID=?", arguments: [partition.serverID.uuidString, partition.userID, checkpoint.itemID])
            } else if current.baselineLocation == checkpoint.baselineLocation, current.baselineUpdatedAt == checkpoint.baselineUpdatedAt {
                // Navigation may advance while a PATCH is in flight. Preserve that newer location
                // and advance only its baseline to the position this client just verified.
                let merged = ReadingCheckpoint(itemID: current.itemID, format: current.format, location: current.location, progress: current.progress, updatedAt: current.updatedAt, baselineLocation: remote.ebookLocation, baselineProgress: remote.ebookProgress, baselineUpdatedAt: remote.lastUpdate)
                try db.execute(sql: "UPDATE readingPosition SET payload=? WHERE serverID=? AND userID=? AND itemID=?", arguments: [try Self.encode(merged), partition.serverID.uuidString, partition.userID, checkpoint.itemID])
            }
        }
    }

    private func save<T: Encodable>(_ value: T, table: String, itemID: String, pending: Bool, partition: AccountPartition) throws {
        let payload = try Self.encode(value)
        try queue.write { db in
            if table == "readingPosition" { try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading, collectingWrite: true) }
            try db.execute(sql: "INSERT INTO \(table) (serverID,userID,itemID,payload,pending) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,itemID) DO UPDATE SET payload=excluded.payload,pending=excluded.pending", arguments: [partition.serverID.uuidString, partition.userID, itemID, payload, pending])
        }
    }
    private func selectedValue<T: Decodable>(_ type: T.Type, table: String, itemID: String, ino: String, partition: AccountPartition) throws -> T? {
        let data = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading)
            return try Data.fetchOne(db, sql: "SELECT payload FROM \(table) WHERE serverID=? AND userID=? AND itemID=? AND ino=?", arguments: [partition.serverID.uuidString, partition.userID, itemID, ino])
        }
        return try data.map { try JSONDecoder().decode(type, from: $0) }
    }
    private func saveSelected<T: Encodable>(_ value: T, table: String, itemID: String, ino: String, partition: AccountPartition) throws {
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading)
            try db.execute(sql: "INSERT INTO \(table)(serverID,userID,itemID,ino,payload) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,itemID,ino) DO UPDATE SET payload=excluded.payload", arguments: [partition.serverID.uuidString, partition.userID, itemID, ino, try Self.encode(value)])
        }
    }
    private func load<T: Decodable>(_ type: T.Type, table: String, itemID: String, partition: AccountPartition) throws -> T? {
        let data = try queue.read { db in
            if table == "readingPosition" { try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .reading) }
            return try Data.fetchOne(db, sql: "SELECT payload FROM \(table) WHERE serverID=? AND userID=? AND itemID=?", arguments: [partition.serverID.uuidString, partition.userID, itemID]) }
        return try data.map { try JSONDecoder().decode(type, from: $0) }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
}

private final class ReadingRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let endpoint: ServerEndpoint
    let authorization: String?
    init(endpoint: ServerEndpoint, authorization: String?) { self.endpoint = endpoint; self.authorization = authorization }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? endpoint.url(path: url.absoluteString)) != nil else { completionHandler(nil); return }
        var request = request; request.httpShouldHandleCookies = false
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(request)
    }
}
