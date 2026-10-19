import Foundation

public enum PublicShareError: Error, LocalizedError, Sendable, Equatable {
    case invalidLink, untrustedResource, unavailable, downloadForbidden, sessionChanged, stateConflict
    case localStateUnavailable
    case invalidResponse, responseTooLarge, invalidRange, rangeIgnored, closed, progressSuperseded
    case rangeNotSatisfiable(totalLength: Int64?)
    case http(Int), transport(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "公开分享链接无效。"
        case .untrustedResource: "分享资源地址超出了允许的来源或路径。"
        case .unavailable: "分享不存在、已失效或当前不可用。"
        case .downloadForbidden: "此分享不允许下载。"
        case .sessionChanged, .closed: "匿名分享上下文已关闭或发生变化。"
        case .stateConflict: "匿名进度已被其他上下文更新，请重新打开分享。"
        case .localStateUnavailable: "无法保存匿名分享的本机检查点。"
        case .invalidResponse: "分享服务器返回了无效的数据。"
        case .responseTooLarge: "分享响应超过允许的大小。"
        case .invalidRange: "音轨字节范围无效。"
        case .rangeIgnored: "服务器没有遵守有界音轨范围请求。"
        case .rangeNotSatisfiable: "音轨范围超出文件长度。"
        case .progressSuperseded: "此进度已被更新的本机检查点替代。"
        case .http(let status): "公开分享请求失败（HTTP \(status)）。"
        case .transport: "无法连接公开分享服务器。"
        }
    }
}

public struct PublicShareHandle: Hashable, Sendable {
    public let serverSessionID: String
    public let shareID: String
    let generation: UUID
}
public struct PublicShareTrack: Hashable, Sendable, Identifiable {
    public let index: Int
    public let title: String
    public let startOffset: Double
    public let duration: Double
    public let url: URL
    public let mimeType: String?
    public var contentType: String? { mimeType }
    public var id: Int { index }
}
public struct PublicShareChapter: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let start: Double
    public let end: Double
}
public struct PublicShareSnapshot: Hashable, Sendable {
    public let handle: PublicShareHandle
    public let shareID: String
    public let mediaID: String
    public let mediaType: String
    public let title: String
    public let author: String
    public let duration: Double
    /// Chosen resume position, including a durable anonymous checkpoint when applicable.
    public let currentTime: Double
    public let tracks: [PublicShareTrack]
    public let chapters: [PublicShareChapter]
    public let isDownloadable: Bool
    public let expiresAt: Date?
    public let hasCover: Bool
    public let serverVersion: String?
}
public struct PublicShareTrackRange: Sendable {
    public let data: Data
    public let totalLength: Int64
    public let contentType: String?
    /// Actual returned byte interval; the upper bound is exclusive.
    public let range: Range<Int64>
}
public struct PublicShareCheckpoint: Codable, Hashable, Sendable {
    public let id: UUID
    public let currentTime: Double
    public let savedAt: Date
    public let remoteAcknowledged: Bool
}
public struct PublicShareProgressSyncFailure: Error, Sendable {
    public let checkpoint: PublicShareCheckpoint
    public let reason: PublicShareError
}
public struct PublicShareExport: Sendable {
    /// An owned temporary file. The caller must move or remove it after explicit export.
    public let fileURL: URL
    public let suggestedFilename: String
    public let contentType: String?
}

struct ShareCookie: Codable, Sendable, Equatable {
    var value: String
    var expiresAt: Date
}
struct StoredShareProgress: Codable, Sendable {
    var shareID: String
    var mediaID: String
    var serverSessionID: String
    var checkpoint: PublicShareCheckpoint
}
struct StoredShareState: Codable, Sendable {
    var cookie: ShareCookie?
    var progress: StoredShareProgress?
}
struct ShareWireDocument: Decodable {
    var id: String
    var mediaItemId: String
    var mediaItemType: String
    var slug: String
    var expiresAt: String?
    var isDownloadable: Bool?
    var playbackSession: ShareWireSession
}
struct ShareWireSession: Decodable {
    var id: String
    var displayTitle: String?
    var displayAuthor: String?
    var duration: Double
    var currentTime: Double
    var audioTracks: [ShareWireTrack]
    var chapters: [PublicShareChapter]?
    var coverPath: String?
    var serverVersion: String?
}
struct ShareWireTrack: Decodable {
    var index: Int
    var startOffset: Double
    var duration: Double
    var title: String?
    var contentUrl: String
    var mimeType: String?
}
