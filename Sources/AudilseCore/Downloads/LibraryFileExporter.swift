import Foundation
import Darwin

/// Captures the authentication instance without putting credentials in persistent
/// download records, file names, progress callbacks or exported originals.
struct OriginalFileContext: Sendable {
    let partition: AccountPartition
    let generation: UInt64
}

extension ABSClient {
    func originalFileContext(partition: AccountPartition) throws -> OriginalFileContext {
        guard !isRetired, profile.id == partition.serverID, profile.userID == partition.userID else { throw ABSError.sessionChanged }
        return OriginalFileContext(partition: partition, generation: authenticationGeneration)
    }

    func validateOriginalFileContext(_ context: OriginalFileContext) throws {
        guard !isRetired, authenticationGeneration == context.generation,
              profile.id == context.partition.serverID, profile.userID == context.partition.userID else { throw ABSError.sessionChanged }
    }
}

public struct LibraryFileExportProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let expectedBytes: Int64?
    public var fraction: Double? { expectedBytes.flatMap { $0 > 0 ? min(1, Double(bytesWritten) / Double($0)) : nil } }
    public init(bytesWritten: Int64, expectedBytes: Int64?) { self.bytesWritten = bytesWritten; self.expectedBytes = expectedBytes }
}

public enum LibraryFileExportError: Error, LocalizedError, Sendable {
    case invalidFile, destinationChanged, unsafeDestination, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "无法保存此文件，请刷新文件列表后重试。"
        case .destinationChanged: "保存位置的文件已改变，请重新选择保存位置。"
        case .unsafeDestination: "请选择普通文件的保存位置。"
        case .http(let status): "保存原件失败（HTTP \(status)）。"
        }
    }
}

/// A user-selected Save As operation. It never creates or alters an offline-book
/// download record. Cancellation and failed validation remove only its own partial.
public actor LibraryFileExporter {
    private let sessionOverride: URLSession?
    public init(session: URLSession? = nil) { sessionOverride = session }

    public func export(itemID: String, file: MediaFile, partition: AccountPartition,
                       client: ABSClient, destination: URL,
                       progress: @escaping @Sendable (LibraryFileExportProgress) async -> Void,
                       authorizeCommit: @escaping @Sendable () async throws -> Void = {}) async throws {
        guard !itemID.isEmpty, !file.ino.isEmpty, file.metadata.size.map({ $0 >= 0 }) ?? true else { throw LibraryFileExportError.invalidFile }
        try Task.checkCancellation()
        let initialDestination = try ExportDestinationSnapshot(url: destination)
        let context = try await client.originalFileContext(partition: partition)
        let endpoint = try ServerEndpoint(baseURL: await client.profile.baseURL)
        let path = "api/items/\(ServerEndpoint.component(itemID))/file/\(ServerEndpoint.component(file.ino))/download"
        var request = try await client.authorizedRequest(path: path)
        request.httpShouldHandleCookies = false
        try await client.validateOriginalFileContext(context)
        try Task.checkCancellation()

        let partial = destination.deletingLastPathComponent().appendingPathComponent(".shelf-export-" + UUID().uuidString + ".partial")
        let descriptor = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        Darwin.close(descriptor)
        defer { try? FileManager.default.removeItem(at: partial) }
        let session: URLSession
        if let sessionOverride { session = sessionOverride }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            session = URLSession(configuration: config, delegate: OriginalFileRedirectDelegate(endpoint: endpoint, authorization: request.value(forHTTPHeaderField: "Authorization")), delegateQueue: nil)
        }
        defer { if sessionOverride == nil { session.invalidateAndCancel() } }
        let result: DownloadTransferResult
        do {
            result = try await DownloadTransfer(session: session).run(request: request, partialURL: partial, expectedBytes: file.metadata.size, validator: nil, allowsEmpty: file.metadata.size == 0) { written, total, _ in
                await progress(.init(bytesWritten: written, expectedBytes: total >= 0 ? total : nil))
            }
        } catch let error as DownloadTransferError {
            switch error {
            case .http(let status): throw LibraryFileExportError.http(status)
            case .invalidResponse: throw ABSError.invalidResponse
            case .invalidRange, .sourceChanged: throw LibraryFileExportError.invalidFile
            }
        }
        guard file.metadata.size == nil || file.metadata.size == result.size else { throw OfflineStorageError.incompleteDownload }
        try Task.checkCancellation()
        try await authorizeCommit()
        try await client.validateOriginalFileContext(context)
        try Task.checkCancellation()
        guard try ExportDestinationSnapshot(url: destination) == initialDestination else { throw LibraryFileExportError.destinationChanged }
        // Both paths are in the chosen directory, so publishing the completed
        // original is an atomic filesystem replacement, never a partial target.
        if initialDestination.exists {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }
}

private struct ExportDestinationSnapshot: Equatable {
    let exists: Bool
    let inode: UInt64?
    let bytes: UInt64?
    let modified: Date?
    init(url: URL) throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".." else { throw LibraryFileExportError.unsafeDestination }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryFileExportError.unsafeDestination }
            exists = true
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            bytes = (attributes[.size] as? NSNumber)?.uint64Value
            modified = attributes[.modificationDate] as? Date
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            exists = false; inode = nil; bytes = nil; modified = nil
        }
    }
}

private final class OriginalFileRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let endpoint: ServerEndpoint
    let authorization: String?
    init(endpoint: ServerEndpoint, authorization: String?) { self.endpoint = endpoint; self.authorization = authorization }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? endpoint.url(path: url.absoluteString)) != nil else { completionHandler(nil); return }
        // Foundation can remove Authorization even on a same-origin redirect.
        // Restore only this frozen request's bearer after validating the origin
        // and proxy prefix; never forward it to another host or outside ABS.
        var request = request; request.httpShouldHandleCookies = false
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(request)
    }
}
