import Foundation
import GRDB

public enum ServerRestoreOrigin: String, Codable, Hashable, Sendable { case requested, observed, uncertain }
public enum ServerRestoreState: String, Codable, Hashable, Sendable { case collecting, awaitingReconnect, completed }
public enum ServerRestoreArchiveStore: String, Codable, Hashable, Sendable { case shelf, reading }

public struct ServerRestoreArchiveReceipt: Codable, Hashable, Sendable {
    public let batchID: UUID
    public let profileIDs: [UUID]
    public let store: ServerRestoreArchiveStore
    public let sealedAt: Date
    public let counts: [String: Int]
}

public struct ServerRestoreBatch: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let canonicalBaseURL: String
    public internal(set) var profileIDs: [UUID]
    public let createdAt: Date
    public internal(set) var origin: ServerRestoreOrigin
    public let reason: String
    public let backupID: String?
    public internal(set) var state: ServerRestoreState = .collecting
    public internal(set) var audioReceipt: ServerRestoreArchiveReceipt?
    public internal(set) var readingReceipt: ServerRestoreArchiveReceipt?
    public internal(set) var completedAt: Date?

    public init(id: UUID = UUID(), canonicalBaseURL: String, profileIDs: [UUID], createdAt: Date = Date(),
                origin: ServerRestoreOrigin, reason: String = "serverBackupRestore", backupID: String? = nil) throws {
        guard !profileIDs.isEmpty, createdAt.timeIntervalSince1970.isFinite, !reason.isEmpty, reason.count <= 200 else { throw ServerRestoreArchiveError.invalidBatch }
        self.id = id; self.canonicalBaseURL = try Self.canonicalURL(canonicalBaseURL)
        self.profileIDs = Self.sorted(profileIDs); self.createdAt = createdAt; self.origin = origin
        self.reason = reason; self.backupID = backupID
    }
    public static func canonicalURL(_ value: String) throws -> String {
        guard let url = URL(string: value), let input = URLComponents(url: url, resolvingAgainstBaseURL: false),
              input.query == nil, input.fragment == nil else { throw ServerRestoreArchiveError.invalidBatch }
        var normalized = URLComponents(url: try ServerEndpoint(baseURL: url).baseURL, resolvingAgainstBaseURL: false)!
        normalized.host = normalized.host?.lowercased()
        if normalized.port == (normalized.scheme == "https" ? 443 : 80) { normalized.port = nil }
        guard let result = normalized.url else { throw ServerRestoreArchiveError.invalidBatch }
        return result.absoluteString
    }
    static func sorted(_ ids: [UUID]) -> [UUID] { Array(Set(ids)).sorted { $0.uuidString < $1.uuidString } }
}

/// Exact opaque row payloads, including fields unknown to this client, remain recoverable.
public struct ServerRestoreArchiveEntry: Codable, Hashable, Sendable {
    public let category: String
    public let profileID: UUID
    public let userID: String
    public let rowKey: String
    public let payload: Data
    public let updatedAt: Double?
    public let mediaKey: String?
    public let pending: Bool?
}
public struct ServerRestoreArchiveSnapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let batch: ServerRestoreBatch
    public let receipts: [ServerRestoreArchiveReceipt]
    public let entries: [ServerRestoreArchiveEntry]
}
public enum ServerRestoreArchiveError: Error, LocalizedError, Sendable, Equatable {
    case invalidBatch, missingBatch, scopeChanged, pendingRestore, retiredSource, incompleteArchive
    public var errorDescription: String? {
        switch self {
        case .invalidBatch: "备份恢复隔离记录无效。"
        case .missingBatch: "找不到备份恢复隔离记录。"
        case .scopeChanged: "备份恢复隔离范围已变化，请重新读取记录。"
        case .pendingRestore: "服务器恢复尚未完成，请确认服务器重启后重新连接。"
        case .retiredSource: "此本地数据连接已因服务器恢复退役，请重新载入账户。"
        case .incompleteArchive: "本机进度尚未完整归档，不能重新连接服务器。"
        }
    }
}

/// Shared SQL only; the main database owns the authoritative restore workflow.
/// The reading database stores a matching local barrier and receipt.
enum RestoreArchiveSQL {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE serverRestoreBatch (id TEXT PRIMARY KEY NOT NULL, canonicalBaseURL TEXT NOT NULL, state TEXT NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE serverRestoreEpoch (serverID TEXT PRIMARY KEY NOT NULL, epoch TEXT NOT NULL);
            CREATE TABLE serverRestoreArchiveRow (batchID TEXT NOT NULL, category TEXT NOT NULL, serverID TEXT NOT NULL, userID TEXT NOT NULL, rowKey TEXT NOT NULL, payload BLOB NOT NULL, updatedAt DOUBLE, mediaKey TEXT, pending BOOLEAN, PRIMARY KEY(batchID,category,serverID,userID,rowKey));
            """)
    }
    static func epochs(_ db: Database) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT serverID,epoch FROM serverRestoreEpoch").map { ($0["serverID"] as String, $0["epoch"] as String) })
    }
    static func batches(_ db: Database, pendingOnly: Bool = false) throws -> [ServerRestoreBatch] {
        try Data.fetchAll(db, sql: "SELECT payload FROM serverRestoreBatch" + (pendingOnly ? " WHERE state!='completed'" : "") + " ORDER BY id").map { try JSONDecoder().decode(ServerRestoreBatch.self, from: $0) }
    }
    static func batch(_ db: Database, _ id: UUID) throws -> ServerRestoreBatch? {
        try Data.fetchOne(db, sql: "SELECT payload FROM serverRestoreBatch WHERE id=?", arguments: [id.uuidString]).map { try JSONDecoder().decode(ServerRestoreBatch.self, from: $0) }
    }
    static func put(_ batch: ServerRestoreBatch, _ db: Database) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: "INSERT INTO serverRestoreBatch(id,canonicalBaseURL,state,payload) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET canonicalBaseURL=excluded.canonicalBaseURL,state=excluded.state,payload=excluded.payload", arguments: [batch.id.uuidString, batch.canonicalBaseURL, batch.state.rawValue, try encoder.encode(batch)])
    }
    static func begin(_ proposed: ServerRestoreBatch, _ db: Database) throws -> ServerRestoreBatch {
        guard !proposed.profileIDs.isEmpty, proposed.createdAt.timeIntervalSince1970.isFinite, !proposed.reason.isEmpty, proposed.reason.count <= 200, proposed.canonicalBaseURL == (try ServerRestoreBatch.canonicalURL(proposed.canonicalBaseURL)) else { throw ServerRestoreArchiveError.invalidBatch }
        let all = try batches(db)
        if let exact = all.first(where: { $0.id == proposed.id }) {
            guard exact.canonicalBaseURL == proposed.canonicalBaseURL else { throw ServerRestoreArchiveError.scopeChanged }
            if exact.state == .completed {
                guard Set(exact.profileIDs) == Set(proposed.profileIDs) else { throw ServerRestoreArchiveError.scopeChanged }
                return exact
            }
        }
        let active = all.filter { $0.state != .completed && ($0.canonicalBaseURL == proposed.canonicalBaseURL || !Set($0.profileIDs).isDisjoint(with: proposed.profileIDs)) }
        guard active.count <= 1, active.first?.canonicalBaseURL == proposed.canonicalBaseURL || active.isEmpty else { throw ServerRestoreArchiveError.scopeChanged }
        if active.isEmpty, !all.contains(where: { $0.id == proposed.id }), proposed.state != .collecting { throw ServerRestoreArchiveError.invalidBatch }
        var value = active.first ?? proposed
        guard value.state != .completed || active.isEmpty else { throw ServerRestoreArchiveError.scopeChanged }
        let merged = ServerRestoreBatch.sorted(value.profileIDs + proposed.profileIDs)
        if merged != value.profileIDs { value.profileIDs = merged; value.state = .collecting }
        if proposed.origin == .uncertain { value.origin = .uncertain }
        try put(value, db); return value
    }
    static func check(_ db: Database, partition: AccountPartition, expectedEpochs: [String: String], store: ServerRestoreArchiveStore, collectingWrite: Bool = false) throws {
        let id = partition.serverID.uuidString
        let current = try String.fetchOne(db, sql: "SELECT epoch FROM serverRestoreEpoch WHERE serverID=?", arguments: [id]) ?? "initial"
        guard current == (expectedEpochs[id] ?? "initial") else { throw ServerRestoreArchiveError.retiredSource }
        for batch in try batches(db, pendingOnly: true) where batch.profileIDs.contains(partition.serverID) {
            let sealed = (store == .shelf ? batch.audioReceipt : batch.readingReceipt)?.profileIDs.contains(partition.serverID) == true
            guard collectingWrite && batch.state == .collecting && !sealed else { throw ServerRestoreArchiveError.pendingRestore }
        }
    }
    static func advance(_ db: Database, id: UUID, batch: UUID) throws {
        try db.execute(sql: "INSERT INTO serverRestoreEpoch(serverID,epoch) VALUES (?,?) ON CONFLICT(serverID) DO UPDATE SET epoch=excluded.epoch", arguments: [id.uuidString, batch.uuidString])
    }
    static func entries(_ db: Database, batchID: UUID) throws -> [ServerRestoreArchiveEntry] {
        try Row.fetchAll(db, sql: "SELECT * FROM serverRestoreArchiveRow WHERE batchID=? ORDER BY category,serverID,userID,rowKey", arguments: [batchID.uuidString]).map { row in
            guard let id = UUID(uuidString: row["serverID"]) else { throw ServerRestoreArchiveError.invalidBatch }
            return .init(category: row["category"], profileID: id, userID: row["userID"], rowKey: row["rowKey"], payload: row["payload"], updatedAt: row["updatedAt"], mediaKey: row["mediaKey"], pending: row["pending"])
        }
    }
    static func matches(_ receipt: ServerRestoreArchiveReceipt, batch: ServerRestoreBatch, store: ServerRestoreArchiveStore) -> Bool {
        receipt.batchID == batch.id && receipt.store == store && receipt.profileIDs == batch.profileIDs && receipt.sealedAt.timeIntervalSince1970.isFinite
    }
    static func receipt(_ db: Database, batch: ServerRestoreBatch, store: ServerRestoreArchiveStore, profileIDs: [UUID]) throws -> ServerRestoreArchiveReceipt {
        let prefix = store.rawValue + "."
        let counts = Dictionary(grouping: try entries(db, batchID: batch.id).filter { $0.category.hasPrefix(prefix) }, by: \.category).mapValues(\.count)
        return .init(batchID: batch.id, profileIDs: ServerRestoreBatch.sorted(profileIDs), store: store, sealedAt: Date(), counts: counts)
    }
}
