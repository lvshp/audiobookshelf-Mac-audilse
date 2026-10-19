import Foundation
import GRDB

/// Every row belongs to one account. Identical item IDs from other servers never collide.
public struct AccountPartition: Codable, Hashable, Sendable {
    public let serverID: UUID
    public let userID: String

    public init(serverID: UUID, userID: String) {
        self.serverID = serverID
        self.userID = userID
    }

    public var directoryName: String {
        // User IDs are opaque, never use them as file system path components.
        let encoded = Data(userID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return serverID.uuidString.lowercased() + "/" + encoded
    }
}

public actor ShelfDatabase {
    private let queue: DatabaseQueue
    private let restoreEpochs: [String: String]
    // An eviction failure must not resurrect metadata from before a confirmed
    // server write. This barrier lasts for this actor's lifetime and is cleared
    // only by a successful eviction of the same account partition.
    private var blockedCachePartitions = Set<AccountPartition>()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        queue = try DatabaseQueue(path: path.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-offline") { db in
            try db.create(table: "cachedValue") { table in
                table.column("serverID", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("key", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .double).notNull()
                table.primaryKey(["serverID", "userID", "key"])
            }
            try db.create(table: "offlineSession") { table in
                table.column("serverID", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("id", .text).notNull()
                table.column("mediaKey", .text).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["serverID", "userID", "id"])
            }
            try db.create(table: "download") { table in
                table.column("serverID", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["serverID", "userID", "itemID"])
            }
            try db.create(table: "syncConflict") { table in
                table.column("serverID", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("mediaKey", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["serverID", "userID", "mediaKey"])
            }
        }
        migrator.registerMigration("v2-server-restore-archive", migrate: RestoreArchiveSQL.migrate)
        try migrator.migrate(queue)
        restoreEpochs = try queue.read(RestoreArchiveSQL.epochs)
    }

    /// Persist this barrier before retiring clients or submitting the remote restore.
    /// Same-endpoint pending requests share one batch and explicitly union their profiles.
    public func beginServerRestore(_ batch: ServerRestoreBatch) throws -> ServerRestoreBatch {
        try queue.write { try RestoreArchiveSQL.begin(batch, $0) }
    }

    public func serverRestoreArchives() throws -> [ServerRestoreBatch] {
        try queue.read { try RestoreArchiveSQL.batches($0) }
    }

    public func pendingServerRestores() throws -> [ServerRestoreBatch] {
        try queue.read { try RestoreArchiveSQL.batches($0, pendingOnly: true) }
    }

    public func serverRestoreBatch(id: UUID) throws -> ServerRestoreBatch? {
        try queue.read { try RestoreArchiveSQL.batch($0, id) }
    }

    public func restoreGuard(profileID: UUID, canonicalBaseURL: String? = nil) throws -> ServerRestoreBatch? {
        let canonical = try canonicalBaseURL.map(ServerRestoreBatch.canonicalURL)
        return try queue.read { db in
            try RestoreArchiveSQL.batches(db, pendingOnly: true).first {
                $0.profileIDs.contains(profileID) || (canonical != nil && $0.canonicalBaseURL == canonical)
            }
        }
    }

    /// The copy, removal, epoch retirement and receipt commit are one SQLite transaction.
    /// Download records and their original files deliberately remain outside this archive.
    public func archiveForServerRestore(batchID: UUID) throws -> ServerRestoreArchiveReceipt {
        try queue.write { db in
            guard var batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            if let old = batch.audioReceipt, old.profileIDs == batch.profileIDs { return old }
            guard batch.state == .collecting else { throw ServerRestoreArchiveError.scopeChanged }
            let sealed = Set(batch.audioReceipt?.profileIDs ?? [])
            for id in batch.profileIDs where !sealed.contains(id) {
                let arguments: StatementArguments = [batch.id.uuidString, id.uuidString]
                try db.execute(sql: "INSERT INTO serverRestoreArchiveRow(batchID,category,serverID,userID,rowKey,payload,updatedAt) SELECT ?,'shelf.cachedValue',serverID,userID,key,payload,updatedAt FROM cachedValue WHERE serverID=?", arguments: arguments)
                try db.execute(sql: "INSERT INTO serverRestoreArchiveRow(batchID,category,serverID,userID,rowKey,payload,updatedAt,mediaKey) SELECT ?,'shelf.offlineSession',serverID,userID,id,payload,updatedAt,mediaKey FROM offlineSession WHERE serverID=?", arguments: arguments)
                try db.execute(sql: "INSERT INTO serverRestoreArchiveRow(batchID,category,serverID,userID,rowKey,payload,mediaKey) SELECT ?,'shelf.syncConflict',serverID,userID,mediaKey,payload,mediaKey FROM syncConflict WHERE serverID=?", arguments: arguments)
                for table in ["cachedValue", "offlineSession", "syncConflict"] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE serverID=?", arguments: [id.uuidString])
                }
                try RestoreArchiveSQL.advance(db, id: id, batch: batch.id)
            }
            let receipt = try RestoreArchiveSQL.receipt(db, batch: batch, store: .shelf, profileIDs: batch.profileIDs)
            batch.audioReceipt = receipt
            try RestoreArchiveSQL.put(batch, db)
            return receipt
        }
    }

    public func markRestoreAwaitingReconnect(batchID: UUID, readingReceipt: ServerRestoreArchiveReceipt) throws -> ServerRestoreBatch {
        try queue.write { db in
            guard var batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            guard RestoreArchiveSQL.matches(readingReceipt, batch: batch, store: .reading),
                  let audio = batch.audioReceipt, RestoreArchiveSQL.matches(audio, batch: batch, store: .shelf) else { throw ServerRestoreArchiveError.incompleteArchive }
            if batch.state == .completed { return batch }
            batch.readingReceipt = readingReceipt; batch.state = .awaitingReconnect
            try RestoreArchiveSQL.put(batch, db); return batch
        }
    }

    public func recordServerRestoreOrigin(batchID: UUID, origin: ServerRestoreOrigin) throws -> ServerRestoreBatch {
        try queue.write { db in
            guard var batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            batch.origin = origin; try RestoreArchiveSQL.put(batch, db); return batch
        }
    }

    /// Only the coordinator's explicit restart confirmation and fresh reconnect may call this.
    public func completeServerRestore(batchID: UUID) throws -> ServerRestoreBatch {
        try queue.write { db in
            guard var batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            if batch.state == .completed { return batch }
            guard batch.state == .awaitingReconnect,
                  let audio = batch.audioReceipt, RestoreArchiveSQL.matches(audio, batch: batch, store: .shelf),
                  let reading = batch.readingReceipt, RestoreArchiveSQL.matches(reading, batch: batch, store: .reading) else { throw ServerRestoreArchiveError.incompleteArchive }
            batch.state = .completed; batch.completedAt = Date()
            try RestoreArchiveSQL.put(batch, db); return batch
        }
    }

    public func archiveSnapshot(batchID: UUID) throws -> ServerRestoreArchiveSnapshot {
        try queue.read { db in
            guard let batch = try RestoreArchiveSQL.batch(db, batchID) else { throw ServerRestoreArchiveError.missingBatch }
            return .init(schemaVersion: 1, batch: batch, receipts: [batch.audioReceipt].compactMap { $0 }, entries: try RestoreArchiveSQL.entries(db, batchID: batchID))
        }
    }

    public func exportServerRestoreArchive(batchID: UUID, readingArchive: ServerRestoreArchiveSnapshot) throws -> Data {
        let shelf = try archiveSnapshot(batchID: batchID)
        guard readingArchive.schemaVersion == 1, readingArchive.batch.id == shelf.batch.id,
              readingArchive.batch.canonicalBaseURL == shelf.batch.canonicalBaseURL,
              readingArchive.batch.profileIDs == shelf.batch.profileIDs,
              let audio = shelf.batch.audioReceipt, RestoreArchiveSQL.matches(audio, batch: shelf.batch, store: .shelf),
              let reading = readingArchive.receipts.first(where: { $0.store == .reading }),
              RestoreArchiveSQL.matches(reading, batch: shelf.batch, store: .reading),
              shelf.batch.readingReceipt == nil || shelf.batch.readingReceipt == reading else { throw ServerRestoreArchiveError.incompleteArchive }
        return try encoder.encode(ServerRestoreArchiveSnapshot(schemaVersion: 1, batch: shelf.batch, receipts: [audio, reading], entries: shelf.entries + readingArchive.entries))
    }

    public func save<T: Encodable & Sendable>(_ value: T, key: String, partition: AccountPartition) throws {
        let payload = try encoder.encode(value)
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: true)
            try db.execute(sql: "INSERT INTO cachedValue (serverID,userID,key,payload,updatedAt) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt", arguments: [partition.serverID.uuidString, partition.userID, key, payload, Date().timeIntervalSince1970])
        }
    }

    public func load<T: Decodable & Sendable>(_ type: T.Type, key: String, partition: AccountPartition) throws -> T? {
        let isCacheBlocked = blockedCachePartitions.contains(partition) && !key.hasPrefix("resume:")
        let payload = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            if isCacheBlocked { return nil as Data? }
            return try Data.fetchOne(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key=?", arguments: [partition.serverID.uuidString, partition.userID, key])
        }
        return try payload.map { try decoder.decode(type, from: $0) }
    }

    /// Only server-returned progress belongs here. Local resume checkpoints are
    /// deliberately separate, including after an offline restart.
    @discardableResult public func saveConfirmedProgress(_ progress: MediaProgress, partition: AccountPartition) throws -> MediaProgress {
        guard !progress.libraryItemId.isEmpty, let timestamp = progress.lastUpdate,
              timestamp.isFinite, timestamp >= 0, progress.currentTime.isFinite,
              progress.currentTime >= 0, progress.duration.isFinite, progress.duration >= 0,
              progress.progress.isFinite else { throw OfflineStorageError.invalidSession }
        let key = "confirmed-progress:" + OfflinePlaybackSession.mediaKey(itemID: progress.libraryItemId, episodeID: progress.episodeId)
        return try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key=?", arguments: [partition.serverID.uuidString, partition.userID, key]) {
                let previous = try decoder.decode(MediaProgress.self, from: data)
                // A repeated or out-of-order event cannot replace a confirmed point.
                if let previousTimestamp = previous.lastUpdate, previousTimestamp >= timestamp { return previous }
            }
            try db.execute(sql: "INSERT INTO cachedValue (serverID,userID,key,payload,updatedAt) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt", arguments: [partition.serverID.uuidString, partition.userID, key, try encoder.encode(progress), Date().timeIntervalSince1970])
            return progress
        }
    }

    public func confirmedProgress(itemID: String, episodeID: String? = nil, partition: AccountPartition) throws -> MediaProgress? {
        try load(MediaProgress.self, key: "confirmed-progress:" + OfflinePlaybackSession.mediaKey(itemID: itemID, episodeID: episodeID), partition: partition)
    }

    public func confirmedProgress(partition: AccountPartition) throws -> [MediaProgress] {
        let blocked = blockedCachePartitions.contains(partition)
        return try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            guard !blocked else { return [] }
            let rows = try Data.fetchAll(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key GLOB 'confirmed-progress:*'", arguments: [partition.serverID.uuidString, partition.userID])
            return try rows.map { try decoder.decode(MediaProgress.self, from: $0) }
        }
    }

    /// Download preparation may adopt server progress only while there is no
    /// unsynchronized local session or newer local checkpoint. Recheck in the
    /// same transaction as the write: either can arrive after a network await.
    public func saveDownloadedResume(_ progress: MediaProgress, partition: AccountPartition) throws -> MediaProgress? {
        guard let timestamp = progress.lastUpdate, timestamp.isFinite, timestamp >= 0,
              progress.currentTime.isFinite, progress.currentTime >= 0 else { return nil }
        let mediaKey = OfflinePlaybackSession.mediaKey(itemID: progress.libraryItemId, episodeID: progress.episodeId)
        return try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM offlineSession WHERE serverID=? AND userID=? AND mediaKey=?)", arguments: [partition.serverID.uuidString, partition.userID, mediaKey]) == false else { return nil }
            func cached(_ key: String) throws -> MediaProgress? {
                try Data.fetchOne(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key=?", arguments: [partition.serverID.uuidString, partition.userID, key]).map { try decoder.decode(MediaProgress.self, from: $0) }
            }
            var selected = progress
            if let confirmed = try cached("confirmed-progress:" + mediaKey), (confirmed.lastUpdate ?? -1) >= timestamp { selected = confirmed }
            if let existing = try cached("resume:" + mediaKey) {
                guard (existing.lastUpdate ?? -1) <= (selected.lastUpdate ?? -1) else { return nil }
                if selected.ebookLocation == nil { selected.ebookLocation = existing.ebookLocation }
                if selected.ebookProgress == nil { selected.ebookProgress = existing.ebookProgress }
                selected = selected.preservingLocalContinuationMetadata(from: existing)
            }
            try db.execute(sql: "INSERT INTO cachedValue (serverID,userID,key,payload,updatedAt) VALUES (?,?,?,?,?) ON CONFLICT(serverID,userID,key) DO UPDATE SET payload=excluded.payload,updatedAt=excluded.updatedAt", arguments: [partition.serverID.uuidString, partition.userID, "resume:" + mediaKey, try encoder.encode(selected), Date().timeIntervalSince1970])
            return selected
        }
    }

    /// Metadata eviction preserves local resume positions, queued listening history and downloads.
    public func clearCache(partition: AccountPartition) throws {
        blockedCachePartitions.insert(partition)
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            try db.execute(sql: "DELETE FROM cachedValue WHERE serverID=? AND userID=? AND key NOT GLOB 'resume:*'", arguments: [partition.serverID.uuidString, partition.userID])
        }
        blockedCachePartitions.remove(partition)
    }

    /// Reopening a metadata page can repair a previously failed eviction. An
    /// ordinary load with no failed eviction must not delete its valid cache.
    public func retryFailedCacheInvalidation(partition: AccountPartition) throws {
        guard blockedCachePartitions.contains(partition) else { return }
        try clearCache(partition: partition)
    }

    public func saveDownload(_ record: DownloadRecord, partition: AccountPartition) throws {
        let payload = try encoder.encode(record)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO download (serverID,userID,itemID,payload) VALUES (?,?,?,?) ON CONFLICT(serverID,userID,itemID) DO UPDATE SET payload=excluded.payload", arguments: [partition.serverID.uuidString, partition.userID, record.itemID, payload])
        }
    }

    public func downloads(partition: AccountPartition) throws -> [DownloadRecord] {
        let data = try queue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM download WHERE serverID=? AND userID=? ORDER BY itemID", arguments: [partition.serverID.uuidString, partition.userID])
        }
        return try data.map { try decoder.decode(DownloadRecord.self, from: $0) }
    }

    public func removeDownload(itemID: String, partition: AccountPartition) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM download WHERE serverID=? AND userID=? AND itemID=?", arguments: [partition.serverID.uuidString, partition.userID, itemID])
        }
    }

    public func enqueue(_ session: OfflinePlaybackSession, partition: AccountPartition) throws {
        try session.validate()
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: true)
            var saved = session
            // Retried writes cannot replace a newer cumulative snapshot or count it twice.
            if let oldData = try Data.fetchOne(db, sql: "SELECT payload FROM offlineSession WHERE serverID=? AND userID=? AND id=?", arguments: [partition.serverID.uuidString, partition.userID, session.id]) {
                let old = try JSONDecoder().decode(OfflinePlaybackSession.self, from: oldData)
                guard session.updatedAt >= old.updatedAt, session.timeListening >= old.timeListening else { return }
                guard old.startedAt == session.startedAt, old.mediaKey == session.mediaKey else {
                    throw OfflineStorageError.sessionIdentityChanged
                }
                // The baseline is from session start, even if a caller has since refreshed progress.
                saved = OfflinePlaybackSession(id: session.id, itemID: session.itemID, episodeID: session.episodeID, startedAt: session.startedAt, updatedAt: session.updatedAt, currentTime: session.currentTime, timeListening: session.timeListening, duration: session.duration, serverProgressUpdatedAt: old.serverProgressUpdatedAt, serverCurrentTime: old.serverCurrentTime, serverFinished: old.serverFinished, sessionPayload: session.sessionPayload, ownAcknowledgement: old.ownAcknowledgement)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(saved)
            try db.execute(sql: "INSERT INTO offlineSession (serverID,userID,id,mediaKey,updatedAt,payload) VALUES (?,?,?,?,?,?) ON CONFLICT(serverID,userID,id) DO UPDATE SET updatedAt=excluded.updatedAt,payload=excluded.payload", arguments: [partition.serverID.uuidString, partition.userID, session.id, session.mediaKey, session.updatedAt, payload])
        }
    }

    public func enqueue(_ session: LocalPlaybackSession, partition: AccountPartition, baseline: MediaProgress? = nil, ownAcknowledgement: PlaybackSyncAcknowledgement? = nil) throws {
        let snapshot = OfflinePlaybackSession(id: session.id, itemID: session.libraryItemId, episodeID: session.episodeId, startedAt: session.startedAt, updatedAt: session.updatedAt, currentTime: session.currentTime, timeListening: session.timeListening, duration: session.duration, serverProgressUpdatedAt: baseline?.lastUpdate, serverCurrentTime: baseline?.currentTime, serverFinished: baseline?.isFinished, sessionPayload: try encoder.encode(session), ownAcknowledgement: ownAcknowledgement)
        try enqueue(snapshot, partition: partition)
    }

    public func removePendingSession(id: String, partition: AccountPartition) throws {
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            try db.execute(sql: "DELETE FROM offlineSession WHERE serverID=? AND userID=? AND id=?", arguments: [partition.serverID.uuidString, partition.userID, id])
        }
    }

    public func saveResume(_ progress: MediaProgress, partition: AccountPartition) throws {
        var merged = progress
        if let existing = try loadResumeForCheckpoint(itemID: progress.libraryItemId, episodeID: progress.episodeId, partition: partition) {
            // Audio checkpoints do not contain ebook fields; preserve the reader's position.
            if merged.ebookLocation == nil { merged.ebookLocation = existing.ebookLocation }
            if merged.ebookProgress == nil { merged.ebookProgress = existing.ebookProgress }
            merged = merged.preservingLocalContinuationMetadata(from: existing)
        }
        try save(merged, key: "resume:" + OfflinePlaybackSession.mediaKey(itemID: progress.libraryItemId, episodeID: progress.episodeId), partition: partition)
    }

    private func loadResumeForCheckpoint(itemID: String, episodeID: String?, partition: AccountPartition) throws -> MediaProgress? {
        let payload = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: true)
            return try Data.fetchOne(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key=?", arguments: [partition.serverID.uuidString, partition.userID, "resume:" + OfflinePlaybackSession.mediaKey(itemID: itemID, episodeID: episodeID)])
        }
        return try payload.map { try decoder.decode(MediaProgress.self, from: $0) }
    }

    /// Merge only visibility metadata into the newest cached values in one actor
    /// operation. Never save a delayed UI snapshot over an active resume position.
    public func applyContinuationMetadata(_ change: ContinuationMetadataChange, partition: AccountPartition) throws {
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: true)
            func merge<T: Codable>(_ type: T.Type, key: String, transform: (T) -> T) throws {
                guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM cachedValue WHERE serverID=? AND userID=? AND key=?", arguments: [partition.serverID.uuidString, partition.userID, key]) else { return }
                let updated = try encoder.encode(transform(decoder.decode(type, from: payload)))
                try db.execute(sql: "UPDATE cachedValue SET payload=?,updatedAt=? WHERE serverID=? AND userID=? AND key=?", arguments: [updated, Date().timeIntervalSince1970, partition.serverID.uuidString, partition.userID, key])
            }
            try merge(UserAccount.self, key: "user") { change.applying(to: $0) }
            try merge([MediaProgress].self, key: "progress") { change.applying(to: $0) }
            if case .progress(let metadata) = change {
                let key = "resume:" + OfflinePlaybackSession.mediaKey(itemID: metadata.libraryItemId, episodeID: metadata.episodeId)
                try merge(MediaProgress.self, key: key) { $0.withContinuationMetadata(from: metadata) }
            }
        }
    }

    public func loadResume(itemID: String, episodeID: String? = nil, partition: AccountPartition) throws -> MediaProgress? {
        try load(MediaProgress.self, key: "resume:" + OfflinePlaybackSession.mediaKey(itemID: itemID, episodeID: episodeID), partition: partition)
    }

    public func pendingSessions(partition: AccountPartition) throws -> [OfflinePlaybackSession] {
        let data = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            return try Data.fetchAll(db, sql: "SELECT payload FROM offlineSession WHERE serverID=? AND userID=? ORDER BY updatedAt DESC,id ASC", arguments: [partition.serverID.uuidString, partition.userID])
        }
        return try data.map { try decoder.decode(OfflinePlaybackSession.self, from: $0) }
    }

    /// Delete only the uploaded snapshot. Playback may have advanced while the network was busy.
    public func acknowledge(_ session: OfflinePlaybackSession, partition: AccountPartition) throws {
        let payload = try encoder.encode(session)
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            try db.execute(sql: "DELETE FROM offlineSession WHERE serverID=? AND userID=? AND id=? AND payload=?", arguments: [partition.serverID.uuidString, partition.userID, session.id, payload])
        }
    }

    public func saveConflict(_ conflict: SyncConflict, partition: AccountPartition) throws {
        let payload = try encoder.encode(conflict)
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: true)
            try db.execute(sql: "INSERT INTO syncConflict (serverID,userID,mediaKey,payload) VALUES (?,?,?,?) ON CONFLICT(serverID,userID,mediaKey) DO UPDATE SET payload=excluded.payload", arguments: [partition.serverID.uuidString, partition.userID, conflict.mediaKey, payload])
        }
    }

    public func conflicts(partition: AccountPartition) throws -> [SyncConflict] {
        let data = try queue.read { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            return try Data.fetchAll(db, sql: "SELECT payload FROM syncConflict WHERE serverID=? AND userID=? ORDER BY mediaKey", arguments: [partition.serverID.uuidString, partition.userID])
        }
        return try data.map { try decoder.decode(SyncConflict.self, from: $0) }
    }

    public func removeConflict(mediaKey: String, partition: AccountPartition) throws {
        try queue.write { db in
            try RestoreArchiveSQL.check(db, partition: partition, expectedEpochs: restoreEpochs, store: .shelf, collectingWrite: false)
            try db.execute(sql: "DELETE FROM syncConflict WHERE serverID=? AND userID=? AND mediaKey=?", arguments: [partition.serverID.uuidString, partition.userID, mediaKey])
        }
    }
}

public enum OfflineStorageError: Error, LocalizedError, Sendable {
    case invalidSession
    case sessionIdentityChanged
    case unsafePath
    case incompleteDownload
    case insufficientSpace
    case accountChanged

    public var errorDescription: String? {
        switch self {
        case .invalidSession: "离线播放记录无效。"
        case .sessionIdentityChanged: "播放会话身份已改变，无法覆盖原有记录。"
        case .unsafePath: "下载文件路径无效。"
        case .incompleteDownload: "下载尚未完成，或本地文件已改变。"
        case .insufficientSpace: "磁盘可用空间不足。"
        case .accountChanged: "账户已切换，先前的下载操作已取消。"
        }
    }
}
