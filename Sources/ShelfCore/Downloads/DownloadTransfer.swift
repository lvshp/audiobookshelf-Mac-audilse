import Foundation

struct DownloadTransferResult: Sendable {
    let size: Int64
    let validator: String?
}

/// Streams original bytes into a persistent partial file, so restart never depends on opaque
/// URLSession resume archives (which can contain bearer tokens).
actor DownloadTransfer {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    init(session: URLSession) { self.session = session }

    func run(request: URLRequest, partialURL: URL, expectedBytes: Int64?, validator: String?, allowsEmpty: Bool = false, progress: @escaping @Sendable (Int64, Int64, String?) async -> Void) async throws -> DownloadTransferResult {
        try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
            if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw DownloadTransferError.invalidResponse }
        let newValidator = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified")
        var total: Int64
        if response.statusCode == 206 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.contentRange(range), parsed.start == existing else { throw DownloadTransferError.invalidRange }
            total = parsed.total
            if let validator, let newValidator, validator != newValidator { throw DownloadTransferError.sourceChanged }
        } else if response.statusCode == 200 {
            // A server that ignores Range, or changed its validator, sends the complete original.
            existing = 0
            total = response.expectedContentLength
        } else if response.statusCode == 416,
                  let range = response.value(forHTTPHeaderField: "Content-Range"),
                  range.hasPrefix("bytes */"), let length = Int64(range.dropFirst(8)), length > 0, length == existing,
                  expectedBytes == nil || expectedBytes == length {
            if let validator, let newValidator, validator != newValidator { throw DownloadTransferError.sourceChanged }
            return DownloadTransferResult(size: existing, validator: validator)
        } else { throw DownloadTransferError.http(response.statusCode) }
        if let expectedBytes, total > 0, expectedBytes != total { throw DownloadTransferError.sourceChanged }
        if total <= 0 { total = expectedBytes ?? -1 }
        if !FileManager.default.fileExists(atPath: partialURL.path) { FileManager.default.createFile(atPath: partialURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        if existing == 0 { try handle.truncate(atOffset: 0) }
        else { try handle.seekToEnd() }
        var written = existing
        var buffer = Data()
        buffer.reserveCapacity(65_536)
        var lastReport = Date.distantPast
        await progress(written, total, newValidator)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count == 65_536 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.3 {
                    lastReport = Date()
                    await progress(written, total, newValidator)
                }
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
        try handle.synchronize()
        await progress(written, total, newValidator)
        guard written > 0 || allowsEmpty, total <= 0 || written == total else { throw OfflineStorageError.incompleteDownload }
        return DownloadTransferResult(size: written, validator: newValidator)
    }

    static func contentRange(_ value: String) -> (start: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { return nil }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, start <= end, end < total else { return nil }
        return (start, total)
    }
}

enum DownloadTransferError: Error, LocalizedError, Sendable {
    case invalidResponse, invalidRange, sourceChanged, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "下载服务器返回了无效响应。"
        case .invalidRange: "下载服务器返回的续传范围无效。"
        case .sourceChanged: "服务器原始文件已改变，请移除下载后重新下载。"
        case .http(let status): "下载请求失败（HTTP \(status)）。"
        }
    }
}
