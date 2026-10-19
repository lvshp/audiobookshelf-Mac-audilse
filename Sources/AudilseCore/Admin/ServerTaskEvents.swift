import Foundation

public struct ServerTaskProgress: Codable, Hashable, Sendable {
    public let libraryItemId: String
    /// Official task/track progress events use 0...100, not a 0...1 fraction.
    public let progress: Double
}

public struct ServerTaskTrackEvent: Codable, Hashable, Sendable {
    public let libraryItemId: String
    public let ino: String
    public let progress: Double?
    private enum CodingKeys: String, CodingKey { case libraryItemId, ino, progress }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryItemId = try c.decode(String.self, forKey: .libraryItemId)
        if let text = try? c.decode(String.self, forKey: .ino) { ino = text }
        else { ino = String(try c.decode(Int64.self, forKey: .ino)) }
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
    }
}

public struct ServerTaskEmbedQueueEvent: Codable, Hashable, Sendable {
    public let libraryItemId: String
    public let queued: Bool
}

public struct ServerTaskInitialization: Codable, Hashable, Sendable {
    public let userId: String
    public let username: String?
    // The official init payload contains no task snapshot.
}

public enum ServerTaskEvent: Hashable, Sendable {
    case initialized(ServerTaskInitialization)
    case started(ServerTask)
    case finished(ServerTask)
    case progress(ServerTaskProgress)
    case trackStarted(ServerTaskTrackEvent)
    case trackProgress(ServerTaskTrackEvent)
    case trackFinished(ServerTaskTrackEvent)
    case embedQueue(ServerTaskEmbedQueueEvent)
    case disconnected
    case authenticationFailed

    public static func decode(_ event: RealtimeEvent) throws -> Self? {
        if event.name == "disconnected" { return .disconnected }
        if event.name == "auth_failed" { return .authenticationFailed }
        let recognized = ["init", "task_started", "task_finished", "task_progress", "track_started", "track_progress", "track_finished", "metadata_embed_queue_update"]
        guard recognized.contains(event.name) else { return nil }
        guard let data = event.payload else { throw ABSError.invalidResponse }
        let decoder = JSONDecoder()
        switch event.name {
        case "init": return .initialized(try decoder.decode(ServerTaskInitialization.self, from: data))
        case "task_started": return .started(try decoder.decode(ServerTask.self, from: data))
        case "task_finished": return .finished(try decoder.decode(ServerTask.self, from: data))
        case "task_progress": return .progress(try decoder.decode(ServerTaskProgress.self, from: data))
        case "track_started": return .trackStarted(try decoder.decode(ServerTaskTrackEvent.self, from: data))
        case "track_progress": return .trackProgress(try decoder.decode(ServerTaskTrackEvent.self, from: data))
        case "track_finished": return .trackFinished(try decoder.decode(ServerTaskTrackEvent.self, from: data))
        default: return .embedQueue(try decoder.decode(ServerTaskEmbedQueueEvent.self, from: data))
        }
    }
}

public struct ServerQueuedEmbed: Hashable, Identifiable, Sendable {
    public let libraryItemId: String
    public let title: String?
    public var id: String { libraryItemId }
}

public struct ServerTaskTrackState: Hashable, Identifiable, Sendable {
    public let ino: String
    public var progress: Double?
    public var isFinished: Bool
    public var id: String { ino }
}

/// Coalesces frequent ffmpeg events without losing their order relative to a
/// task start/finish or queue update. The journal covers one in-flight GET.
public struct ServerTaskEventJournal: Sendable {
    private struct Entry: Sendable { let sequence: UInt64; let event: ServerTaskEvent }
    private enum Key: Hashable, Sendable { case task(String), progress(String), track(String, String), queue(String) }
    private var sequence: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    public init() {}
    public var events: [ServerTaskEvent] { entries.values.sorted { $0.sequence < $1.sequence }.map(\.event) }
    public mutating func append(_ event: ServerTaskEvent) {
        let key: Key
        switch event {
        case .started(let task), .finished(let task): key = .task(task.id)
        case .progress(let value): key = .progress(value.libraryItemId)
        case .trackStarted(let value), .trackProgress(let value), .trackFinished(let value): key = .track(value.libraryItemId, value.ino)
        case .embedQueue(let value): key = .queue(value.libraryItemId)
        default: return
        }
        sequence &+= 1
        entries[key] = Entry(sequence: sequence, event: event)
    }
}

/// Volatile server state for a single authenticated connection. Completed
/// events are retained for this visit; the GET only lists currently active tasks.
public struct ServerTasksState: Sendable {
    private var byID: [String: ServerTask] = [:]
    private var progressByItem: [String: Double] = [:]
    private var tracksByItem: [String: [String: ServerTaskTrackState]] = [:]
    private var queuedByItem: [String: ServerQueuedEmbed] = [:]
    public init() {}

    public var tasks: [ServerTask] {
        byID.values.sorted {
            if $0.isFinished != $1.isFinished { return !$0.isFinished }
            let left = $0.finishedAt ?? $0.startedAt ?? 0, right = $1.finishedAt ?? $1.startedAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
    }
    public var queuedEmbeds: [ServerQueuedEmbed] { queuedByItem.values.sorted { $0.id < $1.id } }
    public func task(id: String) -> ServerTask? { byID[id] }

    public func progress(for task: ServerTask) -> Double? {
        guard let itemID = itemID(for: task), uniquelyReportsProgress(itemID: itemID), !task.isFinished,
              Self.progressActions.contains(task.action ?? "") else { return nil }
        return progressByItem[itemID]
    }
    public func tracks(for task: ServerTask) -> [ServerTaskTrackState] {
        guard let itemID = itemID(for: task), uniquelyReportsProgress(itemID: itemID), !task.isFinished,
              Self.progressActions.contains(task.action ?? "") else { return [] }
        return (tracksByItem[itemID] ?? [:]).values.sorted { $0.ino.localizedStandardCompare($1.ino) == .orderedAscending }
    }
    public func scanLibraryID(for task: ServerTask) -> String? {
        guard !task.isFinished, !task.isFailed, ["library-scan", "library-match-all"].contains(task.action ?? ""),
              case .string(let value) = task.data?["libraryId"], !value.isEmpty else { return nil }
        return value
    }
    public func itemID(for task: ServerTask) -> String? {
        guard case .string(let value) = task.data?["libraryItemId"], !value.isEmpty else { return nil }
        return value
    }
    private static let progressActions: Set<String> = ["encode-m4b", "embed-metadata"]
    private func uniquelyReportsProgress(itemID: String) -> Bool {
        byID.values.filter { !$0.isFinished && Self.progressActions.contains($0.action ?? "") && self.itemID(for: $0) == itemID }.count == 1
    }

    public mutating func replaceSnapshot(_ snapshot: ServerTaskListing, replaying journal: ServerTaskEventJournal) {
        // Never revive a task whose terminal event arrived before this GET.
        let terminal = byID.filter { $0.value.isFinished }
        byID = terminal
        for task in snapshot.tasks where terminal[task.id] == nil { byID[task.id] = task }
        queuedByItem = [:]
        if case .array(let entries) = snapshot.queuedTaskData?["embedMetadata"] {
            for entry in entries {
                guard case .object(let data) = entry, case .string(let id) = data["libraryItemId"], !id.isEmpty else { continue }
                var title: String?
                if case .object(let metadata) = data["metadataObject"], case .string(let value) = metadata["title"] { title = value }
                queuedByItem[id] = .init(libraryItemId: id, title: title)
            }
        }
        for event in journal.events { apply(event) }
        trimCompleted()
    }

    public mutating func apply(_ event: ServerTaskEvent) {
        switch event {
        case .started(let task):
            guard byID[task.id]?.isFinished != true else { return }
            let isNew = byID[task.id] == nil
            byID[task.id] = task
            if isNew, let item = itemID(for: task), Self.progressActions.contains(task.action ?? "") {
                progressByItem[item] = nil; tracksByItem[item] = nil
            }
        case .finished(let task): byID[task.id] = task
        case .progress(let value):
            if uniquelyReportsProgress(itemID: value.libraryItemId), value.progress.isFinite { progressByItem[value.libraryItemId] = min(100, max(0, value.progress)) }
            else { progressByItem[value.libraryItemId] = nil }
        case .trackStarted(let value): setTrack(value, finished: false, started: true)
        case .trackProgress(let value): setTrack(value, finished: false, started: false)
        case .trackFinished(let value): setTrack(value, finished: true, started: false)
        case .embedQueue(let value):
            if value.queued { queuedByItem[value.libraryItemId] = queuedByItem[value.libraryItemId] ?? .init(libraryItemId: value.libraryItemId, title: nil) }
            else { queuedByItem[value.libraryItemId] = nil }
        default: break
        }
        trimCompleted()
    }
    private mutating func setTrack(_ value: ServerTaskTrackEvent, finished: Bool, started: Bool) {
        guard uniquelyReportsProgress(itemID: value.libraryItemId) else { tracksByItem[value.libraryItemId] = nil; return }
        let percent = value.progress.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let previous = tracksByItem[value.libraryItemId]?[value.ino]
        let record = ServerTaskTrackState(ino: value.ino, progress: finished ? 100 : (started ? nil : percent ?? previous?.progress), isFinished: finished)
        tracksByItem[value.libraryItemId, default: [:]][value.ino] = record
    }
    private mutating func trimCompleted() {
        let finished = tasks.filter(\.isFinished)
        for task in finished.dropFirst(100) { byID[task.id] = nil }
        let activeItems = Set(byID.values.filter { !$0.isFinished }.compactMap { itemID(for: $0) })
        progressByItem = progressByItem.filter { activeItems.contains($0.key) }
        tracksByItem = tracksByItem.filter { activeItems.contains($0.key) }
    }
}

/// Account-session activity, independent of whether a task page is currently open.
/// Connection identity also changes when replacing a socket for the same account.
public struct ServerTaskActivitySession: Sendable {
    public struct Source: Equatable, Sendable {
        public let partition: AccountPartition
        public let generation: UUID
        public let connection: UUID
        public init(partition: AccountPartition, generation: UUID, connection: UUID = UUID()) {
            self.partition = partition; self.generation = generation; self.connection = connection
        }
    }
    public private(set) var source: Source?
    public private(set) var state = ServerTasksState()
    public private(set) var isAuthenticated = false
    public init() {}
    public mutating func begin(_ source: Source) {
        self = Self(); self.source = source
    }
    public mutating func reset() { self = Self() }
    @discardableResult public mutating func consume(_ raw: RealtimeEvent, from expected: Source) throws -> Bool {
        guard source == expected, let event = try ServerTaskEvent.decode(raw) else { return false }
        switch event {
        case .initialized(let identity):
            guard identity.userId == expected.partition.userID else {
                state = .init(); isAuthenticated = false
                return false
            }
            isAuthenticated = true
        case .authenticationFailed:
            state = .init(); isAuthenticated = false
        case .disconnected:
            isAuthenticated = false
        default:
            guard isAuthenticated else { return false }
            state.apply(event)
        }
        return true
    }
    /// Replay already observed tasks before a page starts its HTTP snapshot.
    /// Finished failures delivered as task_started are intentionally included.
    public func replay() throws -> [RealtimeEvent] {
        guard let source else { return [] }
        let identity = try JSONSerialization.data(withJSONObject: ["userId": source.partition.userID])
        let initialization: [RealtimeEvent] = isAuthenticated ? [.init(name: "init", payload: identity)] : []
        return initialization + (try state.tasks.map {
            .init(name: $0.isFinished ? "task_finished" : "task_started", payload: try JSONEncoder().encode($0))
        })
    }
}
