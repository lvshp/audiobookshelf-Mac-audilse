import AppKit
import Darwin
import Observation
import AudilseCore

@MainActor @Observable
final class PublicShareExportCoordinator {
    private(set) var isBusy = false
    private(set) var saved = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: NSSavePanel?
    @ObservationIgnored private var operation = UUID()

    func start(from source: PublicShareCoordinator) {
        guard !isBusy, source.snapshot?.isDownloadable == true else { return }
        let attempt = UUID(), identity = source.identity
        operation = attempt; isBusy = true; saved = false; error = nil
        task = Task { [weak self, weak source] in
            guard let self, let source else { return }
            defer { if self.operation == attempt { self.isBusy = false; self.task = nil } }
            do {
                let exported = try await source.export()
                defer { try? FileManager.default.removeItem(at: exported.fileURL.deletingLastPathComponent()) }
                try Task.checkCancellation()
                guard source.identity == identity, self.operation == attempt else { throw CancellationError() }
                let panel = NSSavePanel(); self.panel = panel
                panel.title = L10n.tr("保存分享文件")
                let name = exported.suggestedFilename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
                panel.nameFieldStringValue = name ?? "Shared audio"
                panel.canCreateDirectories = true
                let result = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                if self.operation == attempt { self.panel = nil }
                try Task.checkCancellation()
                guard result == .OK, let destination = panel.url,
                      self.operation == attempt, source.identity == identity else { return }
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                try await PublicShareFileCommitter().commit(source: exported.fileURL, destination: destination) { [weak source, weak self] in
                    try await MainActor.run {
                        guard let source, source.identity == identity, self?.operation == attempt else { throw CancellationError() }
                    }
                }
                if self.operation == attempt { self.saved = true }
            } catch is CancellationError { }
            catch {
                if self.operation == attempt { self.error = L10n.error(error) }
            }
        }
    }

    func cancel() {
        operation = UUID()
        task?.cancel(); task = nil
        panel?.cancel(nil); panel = nil
        isBusy = false
    }

    /// A new share must not inherit another share's export result presentation.
    func reset() {
        cancel()
        saved = false
        error = nil
    }
}

/// File copying stays off MainActor and never publishes a partial destination.
private actor PublicShareFileCommitter {
    func commit(source: URL, destination: URL, authorize: @Sendable () async throws -> Void) async throws {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".", destination.lastPathComponent != ".." else { throw LibraryFileExportError.unsafeDestination }
        let parent = destination.deletingLastPathComponent()
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw LibraryFileExportError.unsafeDestination }
        defer { Darwin.close(directory) }
        let parentIdentity = try ShareDirectorySnapshot(descriptor: directory)
        let name = destination.lastPathComponent
        let before = try ShareDestinationSnapshot(name: name, directory: directory)
        let partial = ".shelf-share-" + UUID().uuidString + ".partial"
        let descriptor = openat(directory, partial, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        // The directory descriptor still identifies the original directory if its
        // path moves while authorize suspends; cleanup cannot follow a new path.
        defer { try? output.close(); unlinkat(directory, partial, 0) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize(); try output.close()
        try Task.checkCancellation()
        try await authorize()
        try Task.checkCancellation()
        let currentDirectory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard currentDirectory >= 0 else { throw LibraryFileExportError.destinationChanged }
        defer { Darwin.close(currentDirectory) }
        guard try ShareDirectorySnapshot(descriptor: currentDirectory) == parentIdentity,
              try ShareDestinationSnapshot(name: name, directory: directory) == before else { throw LibraryFileExportError.destinationChanged }
        let result: Int32
        if before.exists { result = renameat(directory, partial, directory, name) }
        else { result = renameatx_np(directory, partial, directory, name, UInt32(RENAME_EXCL)) }
        guard result == 0 else {
            if errno == EEXIST || errno == ENOENT { throw LibraryFileExportError.destinationChanged }
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct ShareDirectorySnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    init(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        device = UInt64(truncatingIfNeeded: info.st_dev); inode = UInt64(info.st_ino)
    }
}

private struct ShareDestinationSnapshot: Equatable {
    let exists: Bool
    let device: UInt64?
    let inode: UInt64?
    let bytes: Int64?
    let modifiedSeconds: Int64?
    let modifiedNanoseconds: Int64?
    init(name: String, directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            exists = false; device = nil; inode = nil; bytes = nil
            modifiedSeconds = nil; modifiedNanoseconds = nil
            return
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LibraryFileExportError.unsafeDestination }
        exists = true; device = UInt64(truncatingIfNeeded: info.st_dev); inode = UInt64(info.st_ino); bytes = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
}
