import Foundation
import Observation

public typealias DownloadAuthorization = @Sendable (URL) async throws -> URLRequest

@MainActor @Observable public final class DownloadManager {
    public private(set) var records: [DownloadRecord] = []
    public private(set) var partition: AccountPartition?
    public private(set) var storageDiagnostic: ClientDiagnostic?
    public var storageError: String? { storageDiagnostic?.fallbackMessage }
    public let rootDirectory: URL
    @ObservationIgnored private let database: ShelfDatabase
    @ObservationIgnored private let transfer: DownloadTransfer
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var authorizations: [String: DownloadAuthorization] = [:]
    @ObservationIgnored private var generations: [String: UUID] = [:]
    @ObservationIgnored private var lastSave: [String: Date] = [:]
    @ObservationIgnored private var accountEpoch = UUID()

    public init(database: ShelfDatabase, rootDirectory: URL) {
        self.database = database
        self.rootDirectory = rootDirectory
        transfer = DownloadTransfer()
    }

    /// Internal transport injection keeps tests on synthetic HTTP without changing validation.
    init(database: ShelfDatabase, rootDirectory: URL, transfer: DownloadTransfer) {
        self.database = database; self.rootDirectory = rootDirectory; self.transfer = transfer
    }

    /// Reconcile persisted files before exposing offline playback. Interrupted transfers stay paused.
    public func restore(partition: AccountPartition) async throws {
        let epoch = UUID()
        accountEpoch = epoch
        self.partition = nil
        storageDiagnostic = nil
        records = []
        generations.removeAll()
        let active = Array(tasks.values)
        tasks.removeAll()
        for task in active { task.cancel() }
        for task in active {
            await task.value
            try checkEpoch(epoch)
        }
        authorizations.removeAll()
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        var restored = try await database.downloads(partition: partition)
        try checkEpoch(epoch)
        for index in restored.indices {
            for fileIndex in restored[index].files.indices where !restored[index].files[fileIndex].completed {
                let file = restored[index].files[fileIndex]
                let finalURL = try DownloadPaths.safeURL(relativePath: file.localRelativePath, root: rootDirectory)
                let partialURL = try DownloadPaths.safeURL(relativePath: file.localRelativePath + ".partial", root: rootDirectory)
                let finalSize = (try? finalURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
                if finalSize?.isRegularFile == true, let size = finalSize?.fileSize, size > 0, file.expectedBytes == Int64(size) {
                    restored[index].files[fileIndex].completed = true
                    restored[index].files[fileIndex].bytesWritten = Int64(size)
                } else {
                    let size = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    restored[index].files[fileIndex].bytesWritten = Int64(size)
                }
            }
            if !restored[index].files.isEmpty, restored[index].files.allSatisfy(\.completed) { restored[index].state = .ready }
            if restored[index].state == .downloading || restored[index].state == .queued { restored[index].state = .paused }
            if restored[index].state == .ready {
                do { _ = try DownloadPaths.validatedTracks(record: restored[index], root: rootDirectory) }
                catch { restored[index].state = .failed; restored[index].setError(.capture(error)) }
            }
            try await database.saveDownload(restored[index], partition: partition)
            try checkEpoch(epoch)
        }
        self.partition = partition
        records = restored
    }

    public func start(partition: AccountPartition, itemID: String, title: String, tracks: [DownloadTrack], authorize: @escaping DownloadAuthorization) async throws {
        if self.partition != partition { try await restore(partition: partition) }
        let epoch = accountEpoch
        guard self.partition == partition else { throw OfflineStorageError.accountChanged }
        guard !tracks.isEmpty, !itemID.isEmpty, Set(tracks.map(\.ino)).count == tracks.count,
              tracks.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.startOffset.isFinite && $0.startOffset >= 0 }) else { throw OfflineStorageError.incompleteDownload }
        if let existing = records.first(where: { $0.itemID == itemID }), existing.files.map(\.track) == tracks {
            if existing.state == .ready { _ = try DownloadPaths.validatedTracks(record: existing, root: rootDirectory); return }
            try await resume(itemID: itemID, authorize: authorize)
            try checkEpoch(epoch)
            return
        }
        if records.contains(where: { $0.itemID == itemID }) {
            try await remove(itemID: itemID)
            try checkEpoch(epoch)
        }
        let directory = partition.directoryName + "/" + UUID().uuidString.lowercased()
        let files = tracks.enumerated().map { index, track in
            let suffix = URL(fileURLWithPath: track.filename).pathExtension
            let safeSuffix = suffix.allSatisfy { $0.isLetter || $0.isNumber } && suffix.count < 12 ? suffix : "audio"
            return DownloadFile(track: track, localRelativePath: "\(directory)/\(index).\(safeSuffix)")
        }
        records.append(DownloadRecord(itemID: itemID, title: title, files: files))
        authorizations[itemID] = authorize
        try await persist(itemID)
        try checkEpoch(epoch)
        await next(itemID)
        try checkEpoch(epoch)
    }

    public func resume(itemID: String, authorize: @escaping DownloadAuthorization) async throws {
        let epoch = accountEpoch
        guard let index = records.firstIndex(where: { $0.itemID == itemID }), partition != nil else { return }
        guard tasks[itemID] == nil else { return }
        authorizations[itemID] = authorize
        records[index].state = .queued
        records[index].error = nil
        try await persist(itemID)
        try checkEpoch(epoch)
        await next(itemID)
        try checkEpoch(epoch)
    }

    public func pause(itemID: String) async throws {
        let epoch = accountEpoch
        guard let index = records.firstIndex(where: { $0.itemID == itemID }) else { return }
        generations[itemID] = UUID()
        records[index].state = .paused
        if let task = tasks.removeValue(forKey: itemID) {
            task.cancel()
            await task.value
            try checkEpoch(epoch)
        }
        if let row = records.firstIndex(where: { $0.itemID == itemID }) {
            for fileIndex in records[row].files.indices where !records[row].files[fileIndex].completed {
                let partialURL = try DownloadPaths.safeURL(relativePath: records[row].files[fileIndex].localRelativePath + ".partial", root: rootDirectory)
                let size = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                records[row].files[fileIndex].bytesWritten = Int64(size)
            }
        }
        try await persist(itemID)
    }

    public func remove(itemID: String) async throws {
        let epoch = accountEpoch
        guard let partition, let record = records.first(where: { $0.itemID == itemID }) else { return }
        try await pause(itemID: itemID)
        try checkEpoch(epoch)
        for file in record.files {
            let url = try DownloadPaths.safeURL(relativePath: file.localRelativePath, root: rootDirectory)
            let partialURL = try DownloadPaths.safeURL(relativePath: file.localRelativePath + ".partial", root: rootDirectory)
            for fileURL in [url, partialURL] where FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        }
        try await database.removeDownload(itemID: itemID, partition: partition)
        try checkEpoch(epoch)
        records.removeAll { $0.itemID == itemID }
        authorizations.removeValue(forKey: itemID)
    }

    public func readyTracks(partition: AccountPartition, itemID: String) async throws -> [DownloadedTrack] {
        guard let record = try await database.downloads(partition: partition).first(where: { $0.itemID == itemID }) else { throw OfflineStorageError.incompleteDownload }
        return try DownloadPaths.validatedTracks(record: record, root: rootDirectory)
    }

    private func checkEpoch(_ epoch: UUID) throws {
        guard accountEpoch == epoch else { throw OfflineStorageError.accountChanged }
    }

    private func persist(_ itemID: String) async throws {
        guard let partition, let index = records.firstIndex(where: { $0.itemID == itemID }) else { return }
        records[index].updatedAt = Date()
        try await database.saveDownload(records[index], partition: partition)
    }

    private func next(_ itemID: String) async {
        let epoch = accountEpoch
        guard let row = records.firstIndex(where: { $0.itemID == itemID }), let authorize = authorizations[itemID] else { return }
        guard let index = records[row].files.firstIndex(where: { !$0.completed }) else {
            records[row].state = .ready
            do { _ = try DownloadPaths.validatedTracks(record: records[row], root: rootDirectory); try await persist(itemID) }
            catch { if accountEpoch == epoch { await fail(itemID, error: error) } }
            return
        }
        let generation = UUID()
        generations[itemID] = generation
        records[row].state = .downloading
        do {
            let file = records[row].files[index]
            let destination = try DownloadPaths.safeURL(relativePath: file.localRelativePath, root: rootDirectory)
            let partialURL = try DownloadPaths.safeURL(relativePath: file.localRelativePath + ".partial", root: rootDirectory)
            let partialSize = (try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let expected = file.expectedBytes {
                let capacity = try rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let capacity, capacity < max(0, expected - partialSize) + 32 * 1024 * 1024 { throw OfflineStorageError.insufficientSpace }
            }
            let request = try await authorize(file.track.contentURL)
            guard generations[itemID] == generation, let currentRow = records.firstIndex(where: { $0.itemID == itemID }), records[currentRow].state == .downloading else { return }
            try await persist(itemID)
            guard generations[itemID] == generation else { return }
            tasks[itemID] = Task { [weak self, transfer] in
                do {
                    let result = try await transfer.run(request: request, partialURL: partialURL, expectedBytes: file.track.expectedBytes, validator: file.validator) { [weak self] written, total, validator in
                        await self?.update(itemID: itemID, index: index, generation: generation, written: written, expected: total, validator: validator)
                    }
                    guard let self, self.generations[itemID] == generation else { return }
                    try FileManager.default.moveItem(at: partialURL, to: destination)
                    guard let currentRow = self.records.firstIndex(where: { $0.itemID == itemID }) else { return }
                    self.records[currentRow].files[index].bytesWritten = result.size
                    self.records[currentRow].files[index].expectedBytes = result.size
                    self.records[currentRow].files[index].validator = result.validator
                    self.records[currentRow].files[index].completed = true
                    self.tasks.removeValue(forKey: itemID)
                    try await self.persist(itemID)
                    guard self.generations[itemID] == generation else { return }
                    await self.next(itemID)
                } catch {
                    guard let self, self.generations[itemID] == generation else { return }
                    self.tasks.removeValue(forKey: itemID)
                    await self.fail(itemID, error: error)
                }
            }
        } catch {
            guard generations[itemID] == generation else { return }
            await fail(itemID, error: error)
        }
    }

    private func update(itemID: String, index: Int, generation: UUID, written: Int64, expected: Int64, validator: String?) async {
        guard generations[itemID] == generation, let row = records.firstIndex(where: { $0.itemID == itemID }), records[row].state == .downloading else { return }
        records[row].files[index].bytesWritten = written
        records[row].files[index].validator = validator
        if expected > 0 { records[row].files[index].expectedBytes = expected }
        if Date().timeIntervalSince(lastSave[itemID] ?? .distantPast) > 1 {
            lastSave[itemID] = Date()
            let epoch = accountEpoch
            do { try await persist(itemID) } catch { if accountEpoch == epoch { storageDiagnostic = .capture(error) } }
        }
    }

    private func fail(_ itemID: String, error: any Error) async {
        let epoch = accountEpoch
        guard let row = records.firstIndex(where: { $0.itemID == itemID }) else { return }
        records[row].state = .failed
        records[row].setError(.capture(error))
        do { try await persist(itemID) }
        catch { if accountEpoch == epoch { storageDiagnostic = .capture(error) } }
    }
}
