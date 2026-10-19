import Foundation

public enum EbookFormat: String, Codable, Sendable, CaseIterable {
    case epub, pdf, cbz, cbr, mobi, azw3
    public init(filename: String) throws {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard let format = Self(rawValue: ext) else { throw ReadingError.unsupportedFormat(ext) }
        self = format
    }
    public var supportsServerProgress: Bool { self != .mobi && self != .azw3 }
    public var isComic: Bool { self == .cbz || self == .cbr }
}

public struct ReadingCheckpoint: Codable, Hashable, Sendable {
    public let itemID: String
    public let format: EbookFormat
    public let location: String
    public let progress: Double
    public let updatedAt: Double
    public let baselineLocation: String?
    public let baselineProgress: Double?
    public let baselineUpdatedAt: Double?
    public init(itemID: String, format: EbookFormat, location: String, progress: Double, updatedAt: Double = Date().timeIntervalSince1970 * 1000, baselineLocation: String? = nil, baselineProgress: Double? = nil, baselineUpdatedAt: Double? = nil) {
        self.itemID = itemID; self.format = format; self.location = location
        self.progress = min(1, max(0, progress)); self.updatedAt = updatedAt
        self.baselineLocation = baselineLocation; self.baselineProgress = baselineProgress; self.baselineUpdatedAt = baselineUpdatedAt
    }
    public static func pageProgress(page: Int, count: Int) -> Double { count > 0 ? min(1, max(0, Double(page - 1) / Double(count))) : 0 }
}

public struct ReadingConflict: Identifiable, Sendable, Hashable {
    public let local: ReadingCheckpoint
    public let remote: MediaProgress
    public var id: String { local.itemID }
    public init(local: ReadingCheckpoint, remote: MediaProgress) { self.local = local; self.remote = remote }
}

public struct CachedEbook: Codable, Hashable, Sendable {
    public let itemID: String
    public let ino: String
    public let format: EbookFormat
    public let filename: String
    public let relativePath: String
    public let bytes: Int64
    public init(itemID: String, ino: String, format: EbookFormat, filename: String, relativePath: String, bytes: Int64) {
        self.itemID = itemID; self.ino = ino; self.format = format; self.filename = filename; self.relativePath = relativePath; self.bytes = bytes
    }
}

public enum ReadingError: Error, LocalizedError, Sendable {
    case noEbook, unavailableOffline, unsupportedFormat(String), invalidDownload, invalidArchive(String), oversizedArchive, missingLibrary, sourceChanged
    public var errorDescription: String? {
        switch self {
        case .noEbook: "此内容没有可阅读的电子书。"
        case .unavailableOffline: "电子书尚未缓存，请联网打开一次后再离线阅读。"
        case .unsupportedFormat(let format): "暂不支持此电子书格式：\(format)。"
        case .invalidDownload: "电子书原件下载失败或文件不完整。"
        case .invalidArchive(let detail): "无法打开压缩书籍：\(detail)"
        case .oversizedArchive: "压缩书籍超出本地安全解包限制。"
        case .missingLibrary: "系统 libarchive 不可用，无法解包漫画。"
        case .sourceChanged: "阅读位置在其他设备发生变化，请选择要保留的位置。"
        }
    }
}
