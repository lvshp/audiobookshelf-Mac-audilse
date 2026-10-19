import Foundation

public struct DownloadTrack: Codable, Hashable, Sendable, Identifiable {
    public let ino: String
    public let title: String
    public let filename: String
    public let contentURL: URL
    public let duration: Double
    public let startOffset: Double
    public let expectedBytes: Int64?
    public var id: String { ino }

    public init(ino: String, title: String, filename: String, contentURL: URL, duration: Double, startOffset: Double, expectedBytes: Int64? = nil) {
        self.ino = ino
        self.title = title
        self.filename = filename
        self.contentURL = contentURL
        self.duration = duration
        self.startOffset = startOffset
        self.expectedBytes = expectedBytes
    }
}

public enum DownloadState: String, Codable, Sendable {
    case queued, downloading, paused, ready, failed
}

public struct DownloadFile: Codable, Hashable, Sendable, Identifiable {
    public let track: DownloadTrack
    public let localRelativePath: String
    public var bytesWritten: Int64
    public var expectedBytes: Int64?
    public var completed: Bool
    public var validator: String?
    public var id: String { track.ino }

    public init(track: DownloadTrack, localRelativePath: String) {
        self.track = track
        self.localRelativePath = localRelativePath
        bytesWritten = 0
        expectedBytes = track.expectedBytes
        completed = false
        validator = nil
    }
}

public struct DownloadRecord: Codable, Hashable, Sendable, Identifiable {
    public let itemID: String
    public let title: String
    public var files: [DownloadFile]
    public var state: DownloadState
    public var error: String? { didSet { errorDiagnostic = nil } }
    public var errorDiagnostic: ClientDiagnostic?
    public let createdAt: Date
    public var updatedAt: Date
    public var id: String { itemID }
    public var bytesWritten: Int64 { files.reduce(0) { $0 + $1.bytesWritten } }
    public var expectedBytes: Int64 { files.reduce(0) { $0 + ($1.expectedBytes ?? 0) } }
    public var progress: Double {
        guard expectedBytes > 0 else { return state == .ready ? 1 : 0 }
        return min(1, Double(bytesWritten) / Double(expectedBytes))
    }

    public mutating func setError(_ diagnostic: ClientDiagnostic) {
        error = diagnostic.fallbackMessage
        errorDiagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case itemID, title, files, state, error, errorDiagnostic, createdAt, updatedAt
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try values.decode(String.self, forKey: .itemID)
        title = try values.decode(String.self, forKey: .title)
        files = try values.decode([DownloadFile].self, forKey: .files)
        state = try values.decode(DownloadState.self, forKey: .state)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // A diagnostic is optional decoration. A future or corrupt diagnostic
        // must not hide otherwise valid originals; mandatory fields stay strict.
        errorDiagnostic = try? values.decodeIfPresent(ClientDiagnostic.self, forKey: .errorDiagnostic)
    }

    public init(itemID: String, title: String, files: [DownloadFile], state: DownloadState = .queued) {
        self.itemID = itemID
        self.title = title
        self.files = files
        self.state = state
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

public struct DownloadedTrack: Sendable, Hashable {
    public let ino: String
    public let title: String
    public let url: URL
    public let duration: Double
    public let startOffset: Double

    public init(ino: String, title: String, url: URL, duration: Double, startOffset: Double) {
        self.ino = ino
        self.title = title
        self.url = url
        self.duration = duration
        self.startOffset = startOffset
    }
}

public enum DownloadPaths {
    public static func safeURL(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
              !relativePath.utf8.contains(0) else { throw OfflineStorageError.unsafePath }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = resolvedRoot
        // Foundation may leave an intermediate symlink unresolved when the final leaf does not
        // exist yet. Downloads only use generated directories, so reject any nested symlink.
        for component in relativePath.split(separator: "/") {
            candidate.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                throw OfflineStorageError.unsafePath
            }
        }
        candidate = candidate.standardizedFileURL
        guard candidate.path.hasPrefix(resolvedRoot.path + "/") else { throw OfflineStorageError.unsafePath }
        return candidate
    }

    public static func validatedTracks(record: DownloadRecord, root: URL) throws -> [DownloadedTrack] {
        guard record.state == .ready, !record.files.isEmpty else { throw OfflineStorageError.incompleteDownload }
        return try record.files.map { file in
            guard file.completed else { throw OfflineStorageError.incompleteDownload }
            let url = try safeURL(relativePath: file.localRelativePath, root: root)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  Int64(size) == file.bytesWritten,
                  file.expectedBytes == nil || file.expectedBytes == Int64(size) else { throw OfflineStorageError.incompleteDownload }
            return DownloadedTrack(ino: file.track.ino, title: file.track.title, url: url, duration: file.track.duration, startOffset: file.track.startOffset)
        }
    }
}
