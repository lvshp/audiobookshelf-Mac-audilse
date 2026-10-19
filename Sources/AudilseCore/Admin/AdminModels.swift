import Foundation

/// Extensible diagnostic data (FFprobe, task details); native forms use typed update models below.
public enum ABSDiagnosticValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), array([Self]), object([String: Self]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([Self].self) { self = .array(value) }
        else { self = .object(try c.decode([String: Self].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}

public enum AdminAction: Sendable { case updateContent, deleteContent, upload, manageLibraries, manageServer, createEreader }
public enum AdminPolicy {
    public static func allows(_ action: AdminAction, user: UserAccount) -> Bool {
        guard user.isActive else { return false }
        return switch action {
        case .updateContent: user.permissions.update
        case .deleteContent: user.permissions.delete
        case .upload: user.permissions.upload
        case .manageLibraries, .manageServer: user.isAdmin
        case .createEreader: user.permissions.createEreader
        }
    }
}
public struct AdminCapabilities: Sendable {
    public let version: ServerVersion
    public init(version: String?) { self.version = ServerVersion(version ?? "2.26.0") }
    public var hasAPIKeys: Bool { version >= ServerVersion("2.37.1") }
    public var hasAuthenticationSessions: Bool { version >= ServerVersion("2.37.1") }
}

/// Nil fields are omitted so editing a title cannot erase other metadata.
public struct MetadataUpdate: Codable, Hashable, Sendable {
    public var title: String?; public var subtitle: String?; public var authors: [NamedEntity]?; public var narrators: [String]?
    public var series: [NamedEntity]?; public var genres: [String]?; public var publishedYear: String?; public var publishedDate: String?
    public var publisher: String?; public var description: String?; public var isbn: String?; public var asin: String?
    public var language: String?; public var explicit: Bool?; public var abridged: Bool?
    public var author: String?; public var feedUrl: String?; public var imageUrl: String?; public var type: String?
    public init() {}
}
public struct MediaUpdate: Codable, Hashable, Sendable {
    public var metadata: MetadataUpdate?; public var tags: [String]?; public var url: String?
    public init(metadata: MetadataUpdate? = nil, tags: [String]? = nil, coverURL: String? = nil) { self.metadata = metadata; self.tags = tags; self.url = coverURL }
}
public struct ItemMediaUpdateResult: Decodable, Sendable {
    public let updated: Bool
    public let libraryItem: LibraryItem
    private enum CodingKeys: String, CodingKey { case updated, libraryItem }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // ABS omits an undefined `updated` when the sparse payload changes nothing.
        // A present value must still be a boolean; malformed responses remain errors.
        updated = values.contains(.updated) ? try values.decode(Bool.self, forKey: .updated) : false
        libraryItem = try values.decode(LibraryItem.self, forKey: .libraryItem)
    }
}
public struct OrderedAudioFile: Codable, Hashable, Identifiable, Sendable {
    public var ino: String; public var exclude: Bool; public var id: String { ino }
    public init(ino: String, exclude: Bool = false) { self.ino = ino; self.exclude = exclude }
}
public struct MatchItemOptions: Codable, Hashable, Sendable {
    public var provider: String?; public var title: String?; public var author: String?; public var isbn: String?; public var asin: String?
    public var overrideCover: Bool?; public var overrideDetails: Bool?
    public init() {}
}
public struct ItemMatchResult: Decodable, Sendable { public let updated: Bool?; public let warning: String?; public let error: String?; public let libraryItem: LibraryItem? }
public struct CoverUpdateResult: Codable, Hashable, Sendable { public let success: Bool?; public let cover: String? }
public struct ChapterUpdateResult: Codable, Hashable, Sendable { public let success: Bool; public let updated: Bool }
public struct ItemScanResult: Codable, Hashable, Sendable { public let result: String }
public struct M4BEncodeOptions: Codable, Hashable, Sendable {
    public var codec: String?; public var channels: String?; public var bitrate: String?
    public init() {}
}
public struct MetadataProvider: Codable, Hashable, Identifiable, Sendable { public let value: String; public let text: String; public var id: String { value } }
public struct MetadataProviderCatalog: Codable, Hashable, Sendable { public var books: [MetadataProvider]; public var booksCovers: [MetadataProvider]; public var podcasts: [MetadataProvider] }
public struct MetadataSearchQuery: Sendable {
    public var title: String; public var author: String; public var provider: String; public var itemID: String?
    public init(title: String, author: String = "", provider: String = "google", itemID: String? = nil) { self.title = title; self.author = author; self.provider = provider; self.itemID = itemID }
}
public struct MetadataSearchBook: Codable, Hashable, Sendable {
    public var title: String?; public var subtitle: String?; public var author: String?; public var narrator: String?
    public var description: String?; public var publisher: String?; public var publishedYear: String?; public var isbn: String?; public var asin: String?
    public var cover: String?; public var covers: [String]?; public var genres: [String]?; public var language: String?; public var duration: Double?
    public struct Series: Codable, Hashable, Sendable { public var series: String; public var sequence: String? }
    public var series: [Series]?; public var tags: [String]?; public var explicit: Bool?; public var abridged: Bool?; public var region: String?
}
public struct LibrarySettingsUpdate: Codable, Hashable, Sendable {
    public var coverAspectRatio: Int?; public var disableWatcher: Bool?; public var skipMatchingMediaWithAsin: Bool?; public var skipMatchingMediaWithIsbn: Bool?
    public var autoScanCronExpression: String?; public var audiobooksOnly: Bool?; public var hideSingleBookSeries: Bool?
    public var onlyShowLaterBooksInContinueSeries: Bool?; public var epubsAllowScriptedContent: Bool?; public var podcastSearchRegion: String?
    public var metadataPrecedence: [String]?; public var markAsFinishedTimeRemaining: Double?; public var markAsFinishedPercentComplete: Double?
    public var clearMarkAsFinishedTimeRemaining = false
    public var clearMarkAsFinishedPercentComplete = false
    public var clearAutoScanCronExpression = false
    public init() {}
    enum CodingKeys: String, CodingKey { case coverAspectRatio, disableWatcher, skipMatchingMediaWithAsin, skipMatchingMediaWithIsbn, autoScanCronExpression, audiobooksOnly, hideSingleBookSeries, onlyShowLaterBooksInContinueSeries, epubsAllowScriptedContent, podcastSearchRegion, metadataPrecedence, markAsFinishedTimeRemaining, markAsFinishedPercentComplete }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(coverAspectRatio, forKey: .coverAspectRatio); try c.encodeIfPresent(disableWatcher, forKey: .disableWatcher)
        try c.encodeIfPresent(skipMatchingMediaWithAsin, forKey: .skipMatchingMediaWithAsin); try c.encodeIfPresent(skipMatchingMediaWithIsbn, forKey: .skipMatchingMediaWithIsbn)
        if clearAutoScanCronExpression { try c.encodeNil(forKey: .autoScanCronExpression) } else { try c.encodeIfPresent(autoScanCronExpression, forKey: .autoScanCronExpression) }
        try c.encodeIfPresent(audiobooksOnly, forKey: .audiobooksOnly); try c.encodeIfPresent(hideSingleBookSeries, forKey: .hideSingleBookSeries)
        try c.encodeIfPresent(onlyShowLaterBooksInContinueSeries, forKey: .onlyShowLaterBooksInContinueSeries); try c.encodeIfPresent(epubsAllowScriptedContent, forKey: .epubsAllowScriptedContent)
        try c.encodeIfPresent(podcastSearchRegion, forKey: .podcastSearchRegion); try c.encodeIfPresent(metadataPrecedence, forKey: .metadataPrecedence)
        if clearMarkAsFinishedTimeRemaining { try c.encodeNil(forKey: .markAsFinishedTimeRemaining) } else { try c.encodeIfPresent(markAsFinishedTimeRemaining, forKey: .markAsFinishedTimeRemaining) }
        if clearMarkAsFinishedPercentComplete { try c.encodeNil(forKey: .markAsFinishedPercentComplete) } else { try c.encodeIfPresent(markAsFinishedPercentComplete, forKey: .markAsFinishedPercentComplete) }
    }
}
public struct LibraryFolderDraft: Codable, Hashable, Sendable {
    public var id: String?; public var fullPath: String
    public init(id: String? = nil, fullPath: String) { self.id = id; self.fullPath = fullPath }
}
public struct LibraryDraft: Codable, Hashable, Sendable {
    public var name: String; public var folders: [LibraryFolderDraft]; public var mediaType: String; public var icon: String; public var provider: String; public var settings: LibrarySettingsUpdate?
    public init(name: String, folders: [LibraryFolderDraft], mediaType: String = "book", icon: String = "database", provider: String = "google", settings: LibrarySettingsUpdate? = nil) { self.name = name; self.folders = folders; self.mediaType = mediaType; self.icon = icon; self.provider = provider; self.settings = settings }
}
public struct LibraryUpdate: Codable, Hashable, Sendable {
    public var name: String?; public var folders: [LibraryFolderDraft]?; public var icon: String?; public var provider: String?; public var displayOrder: Int?; public var settings: LibrarySettingsUpdate?
    public init() {}
}
public struct LibraryOrderEntry: Codable, Hashable, Sendable { public var id: String; public var newOrder: Int; public init(id: String, newOrder: Int) { self.id = id; self.newOrder = newOrder } }
public struct ServerDirectory: Codable, Hashable, Identifiable, Sendable { public var path: String; public var dirname: String; public var level: Int; public var id: String { path } }
public struct ServerDirectories: Codable, Hashable, Sendable { public var posix: Bool; public var directories: [ServerDirectory] }
public struct ServerPathCheck: Codable, Hashable, Sendable { public var exists: Bool; public var libraryItemTitle: String? }
public struct AdminLibrary: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var name: String; public var mediaType: String; public var folders: [LibraryFolderDraft]
    public var icon: String?; public var provider: String?; public var displayOrder: Int?; public var settings: LibrarySettingsUpdate?
    public var lastScan: Double?; public var lastScanVersion: String?
}
public struct BatchMediaUpdate: Codable, Hashable, Sendable {
    public var id: String; public var mediaPayload: MediaUpdate
    public init(id: String, mediaPayload: MediaUpdate) { self.id = id; self.mediaPayload = mediaPayload }
}
public struct BatchUpdateResult: Codable, Hashable, Sendable { public var success: Bool; public var updates: Int }
public struct EmbeddedMetadata: Codable, Hashable, Sendable {
    public var title: String?; public var artist: String?; public var album_artist: String?; public var album: String?
    public var TIT3: String?; public var genre: String?; public var date: String?; public var comment: String?; public var description: String?
    public var composer: String?; public var copyright: String?; public var publisher: String?; public var TRACKTOTAL: String?; public var grouping: String?
}
public struct ChapterSearchResult: Codable, Hashable, Sendable {
    public struct Match: Codable, Hashable, Sendable { public var lengthMs: Double?; public var startOffsetMs: Double?; public var startOffsetSec: Double?; public var title: String }
    public var asin: String?; public var runtimeLengthMs: Double?; public var runtimeLengthSec: Double?; public var brandIntroDurationMs: Double?; public var brandOutroDurationMs: Double?
    public var chapters: [Match]?; public var error: String?; public var stringKey: String?
}
public enum AdminFeatureError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(feature: String, minimumVersion: String), invalidUpload, permissionDenied
    public var errorDescription: String? {
        switch self {
        case let .unavailable(feature, version): "\(feature)需要 Audiobookshelf \(version) 或更高版本。"
        case .invalidUpload: "上传文件或表单字段无效。"
        case .permissionDenied: "账户没有执行此操作的权限。"
        }
    }
}

public enum AccountType: String, Codable, Sendable { case admin, user, guest }
public struct UserPermissionUpdate: Codable, Hashable, Sendable {
    public var download: Bool?; public var update: Bool?; public var delete: Bool?; public var upload: Bool?; public var createEreader: Bool?
    public var accessAllLibraries: Bool?; public var accessAllTags: Bool?; public var accessExplicitContent: Bool?; public var selectedTagsNotAccessible: Bool?
    public init() {}
    /// Creation forms must send every switch explicitly: omitted fields inherit
    /// server role defaults, which may grant permissions the form displays off.
    public static var restrictedCreationDefaults: Self {
        var value = Self()
        value.download = false; value.update = false; value.delete = false; value.upload = false; value.createEreader = false
        value.accessAllLibraries = false; value.accessAllTags = false; value.accessExplicitContent = false; value.selectedTagsNotAccessible = false
        return value
    }
}
public struct AdminUser: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var username: String; public var type: String; public var email: String?; public var isActive: Bool?
    public var permissions: UserPermissionUpdate?; public var librariesAccessible: [String]?; public var itemTagsSelected: [String]?
    public var lastSeen: Double?; public var createdAt: Double?; public var isLocked: Bool?; public var hasOpenIDLink: Bool?
    public var mediaProgress: [AdminUserProgress]?
    public var isOpenID: Bool { hasOpenIDLink == true }
}
public struct UserDraft: Codable, Hashable, Sendable {
    public var username: String; public var password: String; public var type: AccountType; public var isActive: Bool
    public var email: String?; public var permissions: UserPermissionUpdate?; public var librariesAccessible: [String]?; public var itemTagsSelected: [String]?
    public init(username: String, password: String, type: AccountType = .user, isActive: Bool = true) { self.username = username; self.password = password; self.type = type; self.isActive = isActive }
}
public struct UserUpdate: Codable, Hashable, Sendable {
    public var username: String?; public var password: String?; public var type: AccountType?; public var isActive: Bool?; public var email: String?
    public var permissions: UserPermissionUpdate?; public var librariesAccessible: [String]?; public var itemTagsSelected: [String]?
    public init() {}
}
public struct APIKeyRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var name: String; public var userId: String; public var isActive: Bool; public var expiresAt: String?
    public var createdAt: String?; public var updatedAt: String?; public var user: AdminUserSummary?; public var createdByUser: AdminUserSummary?
    /// Only present once at creation. Never persist this response or log it.
    public var apiKey: String?
}
public struct AdminUserSummary: Codable, Hashable, Sendable { public var id: String; public var username: String; public var type: String? }
public struct APIKeyDraft: Codable, Hashable, Sendable {
    public var name: String; public var userId: String; public var expiresIn: Double?; public var isActive: Bool
    public init(name: String, userId: String, expiresIn: Double? = nil, isActive: Bool = true) { self.name = name; self.userId = userId; self.expiresIn = expiresIn; self.isActive = isActive }
}
public struct APIKeyUpdate: Codable, Hashable, Sendable { public var userId: String?; public var isActive: Bool?; public init(userId: String? = nil, isActive: Bool? = nil) { self.userId = userId; self.isActive = isActive } }
public struct AuthenticationDevice: Codable, Hashable, Sendable { public var browserName: String?; public var browserVersion: String?; public var osName: String?; public var osVersion: String?; public var deviceType: String?; public var model: String?; public var vendor: String? }
public struct AuthenticationSession: Codable, Hashable, Identifiable, Sendable { public var id: String; public var ipAddress: String?; public var userAgent: String?; public var deviceInfo: AuthenticationDevice?; public var createdAt: Double?; public var updatedAt: Double?; public var current: Bool }
public struct AuthenticationSessionPage: Codable, Hashable, Sendable { public var sessions: [AuthenticationSession]; public var total: Int; public var numPages: Int; public var page: Int; public var itemsPerPage: Int }
public struct ServerBackup: Codable, Hashable, Identifiable, Sendable { public var id: String; public var key: String?; public var filename: String; public var datePretty: String?; public var fileSize: Int64?; public var createdAt: Double?; public var serverVersion: String? }
public struct BackupListing: Codable, Hashable, Sendable { public var backups: [ServerBackup]; public var backupLocation: String?; public var backupPathEnvSet: Bool? }
public struct ServerTask: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var action: String?; public var data: [String: ABSDiagnosticValue]?; public var title: String?; public var description: String?
    public var titleKey: String?; public var titleSubs: [ABSDiagnosticValue]?; public var descriptionKey: String?; public var descriptionSubs: [ABSDiagnosticValue]?
    public var errorKey: String?; public var errorSubs: [ABSDiagnosticValue]?
    public var error: String?; public var showSuccess: Bool?; public var isFailed: Bool; public var isFinished: Bool; public var startedAt: Double?; public var finishedAt: Double?
}
public struct ServerTaskListing: Codable, Hashable, Sendable { public var tasks: [ServerTask]; public var queuedTaskData: [String: ABSDiagnosticValue]? }
public struct ServerLogEntry: Codable, Hashable, Sendable { public var timestamp: String?; public var level: Int?; public var levelName: String?; public var source: String?; public var message: String? }
public enum ServerLogLevel: Int, Codable, Sendable, CaseIterable { case trace, debug, info, warning, error, fatal, note }
public struct AdminPlaybackSession: Decodable, Identifiable, Sendable {
    public var id: String; public var libraryItemId: String?; public var episodeId: String?; public var userId: String?
    public var libraryId: String?; public var mediaType: String?; public var mediaPlayer: String?; public var serverVersion: String?
    public var startTime: Double?; public var createdAt: Double?
    public var displayTitle: String?; public var displayAuthor: String?; public var duration: Double?; public var currentTime: Double?; public var timeListening: Double?
    public var playMethod: Int?; public var startedAt: Double?; public var updatedAt: Double?; public var user: AdminUserSummary?
    public var deviceInfo: AdminSessionDeviceInfo?
}
public struct AdminPlaybackSessionPage: Decodable, Sendable { public var total: Int; public var numPages: Int; public var page: Int; public var itemsPerPage: Int; public var sessions: [AdminPlaybackSession]; public var userId: String? }
public struct AdminPlaybackSessionSnapshot: Decodable, Sendable { public var sessions: [AdminPlaybackSession]; public var shareSessions: [AdminPlaybackSession] }
public struct AdminOpenSessions: Decodable, Sendable { public var sessions: [AdminPlaybackSession]; public var shareSessions: [ABSDiagnosticValue] }
public struct AdminOnlineUser: Decodable, Identifiable, Sendable { public var id: String; public var username: String; public var type: String; public var connections: Int; public var lastSeen: Double?; public var createdAt: Double?; public var session: PlaybackSession? }
public struct AdminOnlineUsers: Decodable, Sendable { public var usersOnline: [AdminOnlineUser]; public var openSessions: [AdminPlaybackSession] }
public struct CustomMetadataProvider: Codable, Hashable, Identifiable, Sendable { public var id: String; public var name: String; public var mediaType: String; public var url: String; public var authHeaderValue: String? }
public struct CustomMetadataProviderDraft: Codable, Hashable, Sendable {
    public var name: String; public var mediaType: String; public var url: String; public var authHeaderValue: String?
    public init(name: String, mediaType: String = "book", url: String, authHeaderValue: String? = nil) { self.name = name; self.mediaType = mediaType; self.url = url; self.authHeaderValue = authHeaderValue }
}
public struct ServerStorageStatistics: Codable, Hashable, Sendable {
    public struct Group: Codable, Hashable, Sendable {
        /// Original library-item size in bytes, including non-audio files.
        public var totalSize: Double
        public var numItems: Int
        /// Book audio-file count or podcast-episode count, depending on the group.
        public var numAudioFiles: Int
        public init(totalSize: Double, numItems: Int, numAudioFiles: Int) {
            self.totalSize = totalSize; self.numItems = numItems; self.numAudioFiles = numAudioFiles
        }
    }
    public var books: Group; public var podcasts: Group; public var total: Group
    public init(books: Group, podcasts: Group, total: Group) { self.books = books; self.podcasts = podcasts; self.total = total }
}
/// Server-wide annual statistics for administrators/root on ABS 2.26+.
/// Sizes are bytes and listening/book durations are seconds. Preserve `numBooks`
/// and `totalBooks*` as server-reported aggregates: the fixed releases' quoted
/// year-cutoff SQL parameter is not substituted, so these may include later books.
/// They must not be used to infer the selected year's additions or a year-end snapshot.
public struct AdminYearlyStatistics: Codable, Hashable, Sendable {
    public var numListeningSessions: Int; public var numBooksAdded: Int; public var numAuthorsAdded: Int; public var totalBooksAddedSize: Double; public var totalBooksAddedDuration: Double
    /// Up to 25 library-item IDs with existing covers, selected by the server.
    public var booksAddedWithCovers: [String]
    public var totalBooksSize: Double; public var totalBooksDuration: Double; public var totalListeningTime: Double; public var numBooks: Int
    public var topAuthors: [StatisticsRank]; public var topNarrators: [StatisticsRank]; public var topGenres: [StatisticsRank]
    public init(numListeningSessions: Int, numBooksAdded: Int, numAuthorsAdded: Int, totalBooksAddedSize: Double,
                totalBooksAddedDuration: Double, booksAddedWithCovers: [String], totalBooksSize: Double,
                totalBooksDuration: Double, totalListeningTime: Double, numBooks: Int,
                topAuthors: [StatisticsRank], topNarrators: [StatisticsRank], topGenres: [StatisticsRank]) {
        self.numListeningSessions = numListeningSessions; self.numBooksAdded = numBooksAdded; self.numAuthorsAdded = numAuthorsAdded
        self.totalBooksAddedSize = totalBooksAddedSize; self.totalBooksAddedDuration = totalBooksAddedDuration
        self.booksAddedWithCovers = booksAddedWithCovers; self.totalBooksSize = totalBooksSize; self.totalBooksDuration = totalBooksDuration
        self.totalListeningTime = totalListeningTime; self.numBooks = numBooks
        self.topAuthors = topAuthors; self.topNarrators = topNarrators; self.topGenres = topGenres
    }
}
public struct TaxonomyUpdateResult: Codable, Hashable, Sendable { public var numItemsUpdated: Int; public var tagMerged: Bool?; public var genreMerged: Bool? }

public enum BackupSchedule: Codable, Hashable, Sendable {
    case disabled, cron(String)
    public init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let cron = try? c.decode(String.self) { self = .cron(cron) } else { _ = try c.decode(Bool.self); self = .disabled } }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .disabled: try c.encode(false); case .cron(let cron): try c.encode(cron) } }
}
public struct ServerSettingsUpdate: Codable, Hashable, Sendable {
    public var scannerParseSubtitle: Bool?; public var scannerFindCovers: Bool?; public var scannerCoverProvider: String?; public var scannerPreferMatchedMetadata: Bool?; public var scannerDisableWatcher: Bool?
    public var storeCoverWithItem: Bool?; public var storeMetadataWithItem: Bool?; public var allowIframe: Bool?; public var allowedOrigins: [String]?
    public var backupSchedule: BackupSchedule?; public var backupsToKeep: Int?; public var maxBackupSize: Double?; public var logLevel: Int?
    public var homeBookshelfView: Int?; public var bookshelfView: Int?; public var dateFormat: String?; public var timeFormat: String?; public var language: String?; public var sortingIgnorePrefix: Bool?
    public var sortingPrefixes: [String]?
    public init() {}
}
public struct AuthenticationSettings: Codable, Hashable, Sendable {
    public var authLoginCustomMessage: String?; public var authActiveAuthMethods: [String]?
    public var authOpenIDIssuerURL: String?; public var authOpenIDAuthorizationURL: String?; public var authOpenIDTokenURL: String?; public var authOpenIDUserInfoURL: String?; public var authOpenIDJwksURL: String?; public var authOpenIDLogoutURL: String?
    public var authOpenIDClientID: String?; public var authOpenIDClientSecret: String?; public var authOpenIDTokenSigningAlgorithm: String?; public var authOpenIDButtonText: String?
    public var authOpenIDAutoLaunch: Bool?; public var authOpenIDAutoRegister: Bool?; public var authOpenIDMatchExistingBy: String?; public var authOpenIDMobileRedirectURIs: [String]?
    public var authOpenIDGroupClaim: String?; public var authOpenIDAdvancedPermsClaim: String?; public var authOpenIDSubfolderForRedirectURLs: String?
    public init() {}
}
public struct SMTPSettings: Codable, Hashable, Sendable {
    public var host: String?; public var port: Int?; public var secure: Bool?; public var rejectUnauthorized: Bool?; public var user: String?; public var pass: String?
    public var testAddress: String?; public var fromAddress: String?; public var ereaderDevices: [EReaderDevice]?
    public init() {}
}
public struct ServerNotification: Codable, Hashable, Identifiable, Sendable {
    public var id: String; public var libraryId: String?; public var eventName: String; public var urls: [String]; public var titleTemplate: String?; public var bodyTemplate: String?; public var type: String?; public var enabled: Bool
    public var lastFiredAt: Double?; public var lastAttemptFailed: Bool?; public var numConsecutiveFailedAttempts: Int?; public var numTimesFired: Int?; public var createdAt: Double?
}
public struct NotificationDraft: Codable, Hashable, Sendable {
    public var id: String?; public var libraryId: String?; public var eventName: String; public var urls: [String]; public var titleTemplate: String; public var bodyTemplate: String; public var type: String; public var enabled: Bool
    public init(id: String? = nil, eventName: String, urls: [String], titleTemplate: String = "", bodyTemplate: String = "", enabled: Bool = true, libraryId: String? = nil, type: String = "info") { self.id = id; self.eventName = eventName; self.urls = urls; self.titleTemplate = titleTemplate; self.bodyTemplate = bodyTemplate; self.enabled = enabled; self.libraryId = libraryId; self.type = type }
}
public struct NotificationSettings: Codable, Hashable, Sendable {
    public var appriseType: String?; public var appriseApiUrl: String?; public var notifications: [ServerNotification]; public var maxFailedAttempts: Int?; public var maxNotificationQueue: Int?; public var notificationDelay: Int?
}
/// ABS resets absent queue fields to defaults, so this update is intentionally complete.
public struct NotificationSettingsUpdate: Codable, Hashable, Sendable {
    public var appriseApiUrl: String; public var maxFailedAttempts: Int; public var maxNotificationQueue: Int
    public init(appriseApiUrl: String, maxFailedAttempts: Int = 5, maxNotificationQueue: Int = 20) { self.appriseApiUrl = appriseApiUrl; self.maxFailedAttempts = maxFailedAttempts; self.maxNotificationQueue = maxNotificationQueue }
}
public struct NotificationEventDefinition: Codable, Hashable, Identifiable, Sendable {
    public struct Defaults: Codable, Hashable, Sendable { public var title: String; public var body: String }
    public var name: String; public var requiresLibrary: Bool; public var libraryMediaType: String?; public var description: String; public var descriptionKey: String?; public var variables: [String]; public var defaults: Defaults
    public var id: String { name }
}
public struct NotificationDefinitions: Codable, Hashable, Sendable { public var events: [NotificationEventDefinition] }
public struct ServerNotificationConfiguration: Codable, Hashable, Sendable { public var data: NotificationDefinitions; public var settings: NotificationSettings }
