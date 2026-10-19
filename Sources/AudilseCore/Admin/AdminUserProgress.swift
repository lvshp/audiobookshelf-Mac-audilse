import Foundation

/// Administrator user-detail progress. A removed item's libraryItemId may be
/// null; the server progress UUID remains the row identity in that case.
public struct AdminUserProgress: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var userId: String?
    public var libraryItemId: String?
    public var episodeId: String?
    public var mediaItemId: String?
    public var mediaItemType: String?
    public var duration: Double
    public var progress: Double
    public var currentTime: Double
    public var isFinished: Bool
    public var hideFromContinueListening: Bool?
    public var ebookLocation: String?
    public var ebookProgress: Double?
    public var lastUpdate: Double?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var displayTitle: String?
    public var displaySubtitle: String?
    public var coverPath: String?
    public var mediaUpdatedAt: Double?
}

/// Playback history contains browser, mobile, and desktop device shapes. These
/// optional fields do not require Audilse's own device handshake payload.
public struct AdminSessionDeviceInfo: Codable, Hashable, Sendable {
    public var clientName: String?
    public var clientVersion: String?
    public var deviceId: String?
    public var ipAddress: String?
    public var sdkVersion: String?
    public var deviceName: String?
    public var manufacturer: String?
    public var model: String?
    public var browserName: String?
    public var browserVersion: String?
    public var osName: String?
    public var osVersion: String?
    public var deviceType: String?
}
