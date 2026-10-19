import Foundation

public struct PlaybackChapter: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var start: Double
    public var end: Double

    public init(id: Int, title: String, start: Double, end: Double) {
        self.id = id; self.title = title; self.start = start; self.end = end
    }
}

public struct PlaybackMedia: Hashable, Sendable, Identifiable {
    public var itemID: String
    public var episodeID: String?
    public var title: String
    public var author: String
    public var duration: Double
    public var chapters: [PlaybackChapter]
    public var coverURL: URL?
    public var id: String { itemID + (episodeID.map { ":" + $0 } ?? "") }

    public init(itemID: String, episodeID: String? = nil, title: String, author: String = "", duration: Double = 0, chapters: [PlaybackChapter] = [], coverURL: URL? = nil) {
        self.itemID = itemID; self.episodeID = episodeID; self.title = title
        self.author = author; self.duration = duration; self.chapters = chapters; self.coverURL = coverURL
    }
}

public struct PlaybackTrack: Hashable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    public var url: URL
    public var duration: Double
    public var startOffset: Double
    public var mimeType: String?
    public var isLocal: Bool
    public var id: Int { index }

    public init(index: Int, title: String = "", url: URL, duration: Double, startOffset: Double, mimeType: String? = nil, isLocal: Bool = false) {
        self.index = index; self.title = title; self.url = url; self.duration = duration
        self.startOffset = startOffset; self.mimeType = mimeType; self.isLocal = isLocal
    }
}

public struct PreparedPlayback: Sendable {
    public var media: PlaybackMedia
    public var tracks: [PlaybackTrack]
    public var sessionID: String?
    public var initialPosition: Double
    public var startedAt: Double

    public init(media: PlaybackMedia, tracks: [PlaybackTrack], sessionID: String?, initialPosition: Double, startedAt: Double = Date().timeIntervalSince1970 * 1_000) {
        self.media = media; self.tracks = tracks; self.sessionID = sessionID
        self.initialPosition = initialPosition; self.startedAt = startedAt
    }
}

/// The app resolves account-scoped downloads without exposing storage to the
/// player. Returning nil allows the configured online service to prepare it.
public typealias PlaybackLocalProvider = @Sendable (PlaybackMedia) async throws -> PreparedPlayback?

/// A progressive media file with cancellable, bounded random access. Implementations
/// own transport credentials/cookies; AVFoundation never receives an HTTP URL.
public protocol PlaybackResourceSource: Sendable {
    func read(offset: Int64, length: Int) async throws -> PlaybackResourceChunk
}

public struct PlaybackResourceChunk: Sendable {
    public let offset: Int64
    public let data: Data
    public let totalLength: Int64
    /// MIME type, not an AVFoundation UTI.
    public let contentType: String
    public init(offset: Int64, data: Data, totalLength: Int64, contentType: String) {
        self.offset = offset; self.data = data; self.totalLength = totalLength; self.contentType = contentType
    }
}

/// Every sync/close call receives listening seconds since the previous successful
/// call, as required by ABS. Seeking does not contribute to that number.
public protocol PlaybackService: Sendable {
    func prepare(media: PlaybackMedia) async throws -> PreparedPlayback
    func authorize(track: PlaybackTrack) async throws -> PlaybackTrack
    func resourceSource(for track: PlaybackTrack) async throws -> (any PlaybackResourceSource)?
    func prepareToSeek(track: PlaybackTrack, localTime: Double) async throws
    func sync(sessionID: String, currentTime: Double, timeListened: Double) async throws
    func close(sessionID: String, currentTime: Double, timeListened: Double) async throws
}

public extension PlaybackService {
    func resourceSource(for track: PlaybackTrack) async throws -> (any PlaybackResourceSource)? { nil }
    func prepareToSeek(track: PlaybackTrack, localTime: Double) async throws { }
}

public enum PlaybackFailure: LocalizedError, Equatable {
    case noTracks
    case invalidTimeline
    case invalidStartPosition
    case unsupportedLocalFormat(String)
    case unavailableService
    case invalidLocalFile
    case invalidHLSManifest
    case streamNotReady
    case seekInterrupted

    public var errorDescription: String? {
        switch self {
        case .noTracks: "没有可播放的音轨。"
        case .invalidTimeline: "音轨的时长或时间轴无效。"
        case .invalidStartPosition: "播放起始位置必须是有效的非负秒数。"
        case .unsupportedLocalFormat(let format): "本地音频格式 \(format) 需要 VLCKit 3.7.3；当前构建未包含兼容引擎。"
        case .unavailableService: "尚未连接播放服务器。"
        case .invalidLocalFile: "下载文件不存在或不完整，请重新下载。"
        case .invalidHLSManifest: "服务器返回的音频播放清单无效。"
        case .streamNotReady: "服务器尚未生成可播放的音频片段，请稍后重试。"
        case .seekInterrupted: "播放定位被中断，请重试。"
        }
    }
}
