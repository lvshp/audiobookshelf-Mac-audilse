import Foundation

public struct AdminUploadFile: Hashable, Sendable {
    public var localURL: URL
    public var filename: String
    public var mimeType: String
    public init(localURL: URL, filename: String? = nil, mimeType: String = "application/octet-stream") {
        self.localURL = localURL; self.filename = filename ?? localURL.lastPathComponent; self.mimeType = mimeType
    }
}
public struct LibraryUploadDetails: Hashable, Sendable {
    public var libraryID: String; public var folderID: String; public var title: String; public var author: String?; public var series: String?
    public init(libraryID: String, folderID: String, title: String, author: String? = nil, series: String? = nil) { self.libraryID = libraryID; self.folderID = folderID; self.title = title; self.author = author; self.series = series }
}
public struct LibraryUploadProgress: Sendable {
    public enum Phase: Sendable, Equatable { case preparing, uploading }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double? { totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : nil }
    public init(phase: Phase, completedBytes: Int64, totalBytes: Int64) { self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes }
}
extension ABSClient {
    public func uploadLibraryFiles(_ files: [AdminUploadFile], details: LibraryUploadDetails, progress: (@Sendable (LibraryUploadProgress) -> Void)? = nil) async throws {
        let expectedGeneration = authenticationGeneration
        guard !details.libraryID.isEmpty, !details.folderID.isEmpty, !details.title.isEmpty else { throw AdminFeatureError.invalidUpload }
        var fields = ["library": details.libraryID, "folder": details.folderID, "title": details.title]
        fields["author"] = details.author; fields["series"] = details.series
        let parts = files.enumerated().map { MultipartFilePart(name: "file\($0.offset)", file: $0.element) }
        let multipart = try await MultipartFileBuilder().build(fields: fields, files: parts, progress: { written, total in progress?(.init(phase: .preparing, completedBytes: written, totalBytes: total)) })
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        try Task.checkCancellation()
        progress?(.init(phase: .uploading, completedBytes: 0, totalBytes: multipart.size))
        _ = try await uploadMultipart(path: "api/upload", fileURL: multipart.url, contentType: multipart.contentType, expectedGeneration: expectedGeneration, progress: { written, total in progress?(.init(phase: .uploading, completedBytes: written, totalBytes: total)) })
    }
    public func uploadItemCover(id: String, file: AdminUploadFile) async throws -> CoverUpdateResult {
        let expectedGeneration = authenticationGeneration
        let multipart = try await MultipartFileBuilder().build(fields: [:], files: [.init(name: "cover", file: file)])
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        return try JSONDecoder().decode(CoverUpdateResult.self, from: await uploadMultipart(path: "api/items/\(FeaturePath.id(id))/cover", fileURL: multipart.url, contentType: multipart.contentType, expectedGeneration: expectedGeneration))
    }
    public func uploadBackup(file: AdminUploadFile) async throws -> BackupListing {
        let expectedGeneration = authenticationGeneration
        guard file.filename.lowercased().hasSuffix(".audiobookshelf") else { throw AdminFeatureError.invalidUpload }
        let multipart = try await MultipartFileBuilder().build(fields: [:], files: [.init(name: "file", file: file)])
        defer { try? FileManager.default.removeItem(at: multipart.url) }
        return try JSONDecoder().decode(BackupListing.self, from: await uploadMultipart(path: "api/backups/upload", fileURL: multipart.url, contentType: multipart.contentType, expectedGeneration: expectedGeneration))
    }
}

struct MultipartFilePart: Sendable { let name: String; let file: AdminUploadFile }
struct PreparedMultipart: Sendable { let url: URL; let contentType: String; let size: Int64 }
/// Copy through a bounded buffer on an actor. Large audio uploads never become a single Data value.
actor MultipartFileBuilder {
    func build(fields: [String: String], files: [MultipartFilePart], progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws -> PreparedMultipart {
        try Task.checkCancellation()
        guard !files.isEmpty else { throw AdminFeatureError.invalidUpload }
        let total = try files.reduce(Int64(0)) { sum, part in
            guard part.file.localURL.isFileURL else { throw AdminFeatureError.invalidUpload }
            let values = try part.file.localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw AdminFeatureError.invalidUpload }
            let size = values.fileSize ?? 0
            let (next, overflow) = sum.addingReportingOverflow(Int64(size))
            guard !overflow else { throw AdminFeatureError.invalidUpload }
            return next
        }
        var copied: Int64 = 0
        var lastReported: Int64 = 0
        progress?(0, total)
        let boundary = "ShelfMac-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfMac-upload-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AdminFeatureError.invalidUpload }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            for key in fields.keys.sorted() {
                guard Self.validHeader(key) else { throw AdminFeatureError.invalidUpload }
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
            }
            for part in files {
                try Task.checkCancellation()
                let file = part.file
                guard file.localURL.isFileURL, Self.validHeader(part.name), Self.validHeader(file.filename), Self.validHeader(file.mimeType),
                      try file.localURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw AdminFeatureError.invalidUpload }
                let input = try FileHandle(forReadingFrom: file.localURL)
                do {
                    try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n")
                    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        try Task.checkCancellation(); try output.write(contentsOf: chunk)
                        copied += Int64(chunk.count)
                        if copied - lastReported >= 1024 * 1024 { progress?(copied, total); lastReported = copied }
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                try write("\r\n")
            }
            try write("--\(boundary)--\r\n")
            try Task.checkCancellation()
            progress?(copied, total)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return PreparedMultipart(url: url, contentType: "multipart/form-data; boundary=" + boundary, size: Int64(size))
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    private static func validHeader(_ value: String) -> Bool {
        // CRLF is one extended grapheme cluster in Swift; checking Character
        // equality against separate CR/LF values would miss the injection pair.
        !value.isEmpty && !value.utf8.contains { $0 == 13 || $0 == 10 || $0 == 34 || $0 == 0 }
    }
}
