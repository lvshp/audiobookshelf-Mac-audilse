import Foundation

public struct ServerProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: URL
    public var username: String
    public var userID: String?
    public var serverVersion: String?
    public init(id: UUID = UUID(), name: String, baseURL: URL, username: String = "", userID: String? = nil, serverVersion: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.username = username; self.userID = userID; self.serverVersion = serverVersion
    }
}

public struct UserPermissions: Codable, Hashable, Sendable {
    public var download: Bool = false
    public var update: Bool = false
    public var delete: Bool = false
    public var upload: Bool = false
    public var createEreader: Bool = false
    public var selectedTagsNotAccessible: Bool = false
    public var accessAllLibraries: Bool = false
    public var accessAllTags: Bool = false
    public var accessExplicitContent: Bool = false
    public init(download: Bool = false, update: Bool = false, delete: Bool = false, upload: Bool = false) {
        self.download = download; self.update = update; self.delete = delete; self.upload = upload
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        download = c.value(.download, default: false); update = c.value(.update, default: false)
        delete = c.value(.delete, default: false); upload = c.value(.upload, default: false)
        createEreader = c.value(.createEreader, default: false); selectedTagsNotAccessible = c.value(.selectedTagsNotAccessible, default: false)
        accessAllLibraries = c.value(.accessAllLibraries, default: false); accessAllTags = c.value(.accessAllTags, default: false)
        accessExplicitContent = c.value(.accessExplicitContent, default: false)
    }
}

public struct UserAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var username: String
    public var type: String
    public var isActive: Bool
    public var createdAt: Double?
    public var permissions: UserPermissions
    public var librariesAccessible: [String]
    public var itemTagsSelected: [String]
    public var mediaProgress: [MediaProgress]
    public var seriesHideFromContinueListening: [String]
    public var isAdmin: Bool { type == "root" || type == "admin" }
    public init(id: String, username: String, type: String = "user", permissions: UserPermissions = .init(), librariesAccessible: [String] = [], itemTagsSelected: [String] = [], mediaProgress: [MediaProgress] = [], isActive: Bool = true, createdAt: Double? = nil, seriesHideFromContinueListening: [String] = []) {
        self.id = id; self.username = username; self.type = type; self.permissions = permissions; self.librariesAccessible = librariesAccessible; self.itemTagsSelected = itemTagsSelected; self.mediaProgress = mediaProgress; self.isActive = isActive
        self.createdAt = createdAt; self.seriesHideFromContinueListening = seriesHideFromContinueListening
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); username = c.value(.username, default: "")
        type = c.value(.type, default: "user"); permissions = c.value(.permissions, default: .init())
        isActive = c.value(.isActive, default: true)
        createdAt = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
        librariesAccessible = c.value(.librariesAccessible, default: []); itemTagsSelected = c.value(.itemTagsSelected, default: [])
        mediaProgress = c.value(.mediaProgress, default: [])
        seriesHideFromContinueListening = c.value(.seriesHideFromContinueListening, default: [])
    }
}

public struct Library: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var mediaType: String
    public init(id: String, name: String, mediaType: String = "book") { self.id = id; self.name = name; self.mediaType = mediaType }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = c.value(.name, default: ""); mediaType = c.value(.mediaType, default: "book")
    }
}

public struct NamedEntity: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sequence: String?
    public init(id: String = "", name: String, sequence: String? = nil) { self.id = id; self.name = name; self.sequence = sequence }
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) { self.init(name: name); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: c.value(.id, default: ""), name: c.value(.name, default: ""), sequence: try? c.decodeIfPresent(String.self, forKey: .sequence))
    }
}

public struct ItemMetadata: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String?
    public var authorName: String?
    public var author: String?
    public var authors: [NamedEntity]
    public var narratorName: String?
    public var narrators: [String]
    public var description: String?
    public var genres: [String]
    public var publishedYear: String?
    public var publisher: String?
    public var series: [NamedEntity]
    public var language: String?
    public var explicit: Bool
    public var feedUrl: String?
    public var isbn: String?
    public var asin: String?
    public var publishedDate: String?
    public var abridged: Bool?
    public var type: String?
    public init(title: String = "", subtitle: String? = nil, authorName: String? = nil, author: String? = nil, authors: [NamedEntity] = [], narratorName: String? = nil, narrators: [String] = [], description: String? = nil, genres: [String] = [], publishedYear: String? = nil, publisher: String? = nil, series: [NamedEntity] = [], language: String? = nil, explicit: Bool = false, feedUrl: String? = nil, isbn: String? = nil, asin: String? = nil, publishedDate: String? = nil, abridged: Bool? = nil, type: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.authorName = authorName; self.author = author; self.authors = authors; self.narratorName = narratorName; self.narrators = narrators; self.description = description; self.genres = genres; self.publishedYear = publishedYear; self.publisher = publisher; self.series = series; self.language = language; self.explicit = explicit; self.feedUrl = feedUrl
        self.isbn = isbn; self.asin = asin; self.publishedDate = publishedDate; self.abridged = abridged; self.type = type
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, default: ""); subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName); author = try? c.decodeIfPresent(String.self, forKey: .author); authors = c.value(.authors, default: [])
        narratorName = try? c.decodeIfPresent(String.self, forKey: .narratorName); narrators = c.value(.narrators, default: [])
        description = try? c.decodeIfPresent(String.self, forKey: .description); genres = c.value(.genres, default: [])
        publishedYear = try? c.decodeIfPresent(String.self, forKey: .publishedYear); publisher = try? c.decodeIfPresent(String.self, forKey: .publisher)
        series = (try? c.decode([NamedEntity].self, forKey: .series)) ?? (try? c.decode(NamedEntity.self, forKey: .series)).map { [$0] } ?? []; language = try? c.decodeIfPresent(String.self, forKey: .language); explicit = c.value(.explicit, default: false)
        feedUrl = try? c.decodeIfPresent(String.self, forKey: .feedUrl)
        isbn = try? c.decodeIfPresent(String.self, forKey: .isbn); asin = try? c.decodeIfPresent(String.self, forKey: .asin); publishedDate = try? c.decodeIfPresent(String.self, forKey: .publishedDate); abridged = try? c.decodeIfPresent(Bool.self, forKey: .abridged)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
    }
}

public struct FileMetadata: Codable, Hashable, Sendable {
    public var filename: String
    public var ext: String?
    public var path: String?
    public var relPath: String?
    public var size: Int64?
    public init(filename: String = "", ext: String? = nil, path: String? = nil, relPath: String? = nil, size: Int64? = nil) { self.filename = filename; self.ext = ext; self.path = path; self.relPath = relPath; self.size = size }
}

public struct MediaFile: Codable, Hashable, Sendable, Identifiable {
    public var ino: String
    public var metadata: FileMetadata
    public var duration: Double?
    public var index: Int?
    public var mimeType: String?
    public var exclude: Bool = false
    public var isInvalid: Bool = false
    public var error: String?
    public var id: String { ino }
    public init(ino: String, metadata: FileMetadata = .init(), duration: Double? = nil, index: Int? = nil, mimeType: String? = nil) { self.ino = ino; self.metadata = metadata; self.duration = duration; self.index = index; self.mimeType = mimeType }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ino = c.value(.ino, default: ""); metadata = c.value(.metadata, default: .init())
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration); index = try? c.decodeIfPresent(Int.self, forKey: .index); mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType)
        exclude = c.value(.exclude, default: false); isInvalid = c.value(.isInvalid, default: false); error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct AudioTrack: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var startOffset: Double
    public var duration: Double
    public var contentUrl: String
    public var mimeType: String?
    public var title: String?
    public var metadata: FileMetadata?
    public var id: Int { index }
    public init(index: Int, startOffset: Double = 0, duration: Double, contentUrl: String, mimeType: String? = nil, title: String? = nil, metadata: FileMetadata? = nil) { self.index = index; self.startOffset = startOffset; self.duration = duration; self.contentUrl = contentUrl; self.mimeType = mimeType; self.title = title; self.metadata = metadata }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = c.value(.index, default: 0); startOffset = c.value(.startOffset, default: 0); duration = c.value(.duration, default: 0)
        contentUrl = c.value(.contentUrl, default: ""); mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType); title = try? c.decodeIfPresent(String.self, forKey: .title); metadata = try? c.decodeIfPresent(FileMetadata.self, forKey: .metadata)
    }
}

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var start: Double
    public var end: Double
    public init(id: Int, title: String, start: Double, end: Double) { self.id = id; self.title = title; self.start = start; self.end = end }
}

public struct PodcastEpisode: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var description: String?
    public var publishedAt: Double?
    public var audioFile: MediaFile?
    public var duration: Double?
    public var episode: String?
    public var season: String?
    public init(id: String, title: String, subtitle: String? = nil, description: String? = nil, publishedAt: Double? = nil, audioFile: MediaFile? = nil, duration: Double? = nil, episode: String? = nil, season: String? = nil) { self.id = id; self.title = title; self.subtitle = subtitle; self.description = description; self.publishedAt = publishedAt; self.audioFile = audioFile; self.duration = duration; self.episode = episode; self.season = season }
}

public struct ItemMedia: Codable, Hashable, Sendable {
    public var id: String?
    public var autoDownloadEpisodes: Bool?
    public var autoDownloadSchedule: String?
    public var lastEpisodeCheck: Double?
    public var maxEpisodesToKeep: Int?
    public var maxNewEpisodesToDownload: Int?
    public var metadata: ItemMetadata
    public var audioFiles: [MediaFile]
    public var tracks: [AudioTrack]
    public var numTracks: Int?
    public var chapters: [Chapter]
    public var episodes: [PodcastEpisode]
    public var duration: Double
    public var ebookFile: MediaFile?
    public var coverPath: String?
    public var tags: [String]
    public init(metadata: ItemMetadata = .init(), audioFiles: [MediaFile] = [], tracks: [AudioTrack] = [], chapters: [Chapter] = [], episodes: [PodcastEpisode] = [], duration: Double = 0, ebookFile: MediaFile? = nil, coverPath: String? = nil, tags: [String] = [], id: String? = nil, autoDownloadEpisodes: Bool? = nil, autoDownloadSchedule: String? = nil, lastEpisodeCheck: Double? = nil, maxEpisodesToKeep: Int? = nil, maxNewEpisodesToDownload: Int? = nil, numTracks: Int? = nil) { self.id = id; self.autoDownloadEpisodes = autoDownloadEpisodes; self.autoDownloadSchedule = autoDownloadSchedule; self.lastEpisodeCheck = lastEpisodeCheck; self.maxEpisodesToKeep = maxEpisodesToKeep; self.maxNewEpisodesToDownload = maxNewEpisodesToDownload; self.metadata = metadata; self.audioFiles = audioFiles; self.tracks = tracks; self.numTracks = numTracks; self.chapters = chapters; self.episodes = episodes; self.duration = duration; self.ebookFile = ebookFile; self.coverPath = coverPath; self.tags = tags }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id); autoDownloadEpisodes = try? c.decodeIfPresent(Bool.self, forKey: .autoDownloadEpisodes); autoDownloadSchedule = try? c.decodeIfPresent(String.self, forKey: .autoDownloadSchedule); lastEpisodeCheck = try? c.decodeIfPresent(Double.self, forKey: .lastEpisodeCheck); maxEpisodesToKeep = try? c.decodeIfPresent(Int.self, forKey: .maxEpisodesToKeep); maxNewEpisodesToDownload = try? c.decodeIfPresent(Int.self, forKey: .maxNewEpisodesToDownload)
        metadata = c.value(.metadata, default: .init()); audioFiles = c.value(.audioFiles, default: []); tracks = c.value(.tracks, default: []); numTracks = try? c.decodeIfPresent(Int.self, forKey: .numTracks); chapters = c.value(.chapters, default: []); episodes = c.value(.episodes, default: []); duration = c.value(.duration, default: 0); ebookFile = try? c.decodeIfPresent(MediaFile.self, forKey: .ebookFile); coverPath = try? c.decodeIfPresent(String.self, forKey: .coverPath); tags = c.value(.tags, default: [])
    }
}

public struct LibraryItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var libraryId: String
    public var mediaType: String
    public var media: ItemMedia
    public var isMissing: Bool = false
    public var isInvalid: Bool = false
    public var libraryFiles: [MediaFile] = []
    public var updatedAt: Double?
    public var title: String { media.metadata.title }
    public var authorName: String { media.metadata.authorName ?? media.metadata.author ?? media.metadata.authors.map(\.name).joined(separator: ", ") }
    public var narratorName: String { media.metadata.narratorName ?? media.metadata.narrators.joined(separator: ", ") }
    public init(id: String, libraryId: String, mediaType: String = "book", media: ItemMedia = .init(), updatedAt: Double? = nil) { self.id = id; self.libraryId = libraryId; self.mediaType = mediaType; self.media = media; self.updatedAt = updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); libraryId = c.value(.libraryId, default: ""); mediaType = c.value(.mediaType, default: "book"); media = c.value(.media, default: .init())
        isMissing = c.value(.isMissing, default: false); isInvalid = c.value(.isInvalid, default: false); libraryFiles = c.value(.libraryFiles, default: [])
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
}

public struct ItemPage: Codable, Hashable, Sendable {
    public var results: [LibraryItem]
    public var total: Int
    public var limit: Int
    public var page: Int
    public var hasMore: Bool { (page + 1) * max(1, limit) < total }
    public init(results: [LibraryItem], total: Int, limit: Int, page: Int) { self.results = results; self.total = total; self.limit = limit; self.page = page }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([LibraryItem].self, forKey: .results)
        total = c.value(.total, default: results.count)
        limit = (try? c.decode(Int.self, forKey: .limit)) ?? Int(c.value(.limit, default: "")) ?? results.count
        page = (try? c.decode(Int.self, forKey: .page)) ?? Int(c.value(.page, default: "")) ?? 0
    }
}

public struct MediaProgress: Codable, Hashable, Sendable, Identifiable {
    /// Server progress UUID. The computed `id` remains the local item/episode identity.
    public var serverID: String?
    public var hideFromContinueListening: Bool
    public var id: String { episodeId.map { "\(libraryItemId):\($0)" } ?? libraryItemId }
    public var libraryItemId: String
    public var episodeId: String?
    public var currentTime: Double
    public var duration: Double
    public var progress: Double
    public var isFinished: Bool
    public var lastUpdate: Double?
    public var ebookLocation: String?
    public var ebookProgress: Double?
    public init(libraryItemId: String, episodeId: String? = nil, currentTime: Double = 0, duration: Double = 0, progress: Double = 0, isFinished: Bool = false, lastUpdate: Double? = nil, ebookLocation: String? = nil, ebookProgress: Double? = nil, serverID: String? = nil, hideFromContinueListening: Bool = false) { self.serverID = serverID; self.hideFromContinueListening = hideFromContinueListening; self.libraryItemId = libraryItemId; self.episodeId = episodeId; self.currentTime = currentTime; self.duration = duration; self.progress = progress; self.isFinished = isFinished; self.lastUpdate = lastUpdate; self.ebookLocation = ebookLocation; self.ebookProgress = ebookProgress }
    enum CodingKeys: String, CodingKey { case serverID = "id"; case hideFromContinueListening, libraryItemId, episodeId, currentTime, duration, progress, isFinished, lastUpdate, ebookLocation, ebookProgress }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try c.decodeIfPresent(String.self, forKey: .serverID); hideFromContinueListening = c.value(.hideFromContinueListening, default: false)
        libraryItemId = try c.decode(String.self, forKey: .libraryItemId); episodeId = try? c.decodeIfPresent(String.self, forKey: .episodeId); currentTime = c.value(.currentTime, default: 0); duration = c.value(.duration, default: 0); progress = c.value(.progress, default: 0); isFinished = c.value(.isFinished, default: false); lastUpdate = try? c.decodeIfPresent(Double.self, forKey: .lastUpdate); ebookLocation = try? c.decodeIfPresent(String.self, forKey: .ebookLocation); ebookProgress = try? c.decodeIfPresent(Double.self, forKey: .ebookProgress)
    }
}

public struct PlaybackSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var libraryItemId: String
    public var episodeId: String?
    public var audioTracks: [AudioTrack]
    public var currentTime: Double
    public var duration: Double
    public var libraryItem: LibraryItem?
    public var chapters: [Chapter]
    public var startedAt: Double?
    public var updatedAt: Double?
    public init(id: String, libraryItemId: String, episodeId: String? = nil, audioTracks: [AudioTrack] = [], currentTime: Double = 0, duration: Double = 0, libraryItem: LibraryItem? = nil, chapters: [Chapter] = [], startedAt: Double? = nil, updatedAt: Double? = nil) { self.id = id; self.libraryItemId = libraryItemId; self.episodeId = episodeId; self.audioTracks = audioTracks; self.currentTime = currentTime; self.duration = duration; self.libraryItem = libraryItem; self.chapters = chapters; self.startedAt = startedAt; self.updatedAt = updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); libraryItemId = c.value(.libraryItemId, default: ""); episodeId = try? c.decodeIfPresent(String.self, forKey: .episodeId); audioTracks = c.value(.audioTracks, default: []); currentTime = c.value(.currentTime, default: 0); duration = c.value(.duration, default: 0); libraryItem = try? c.decodeIfPresent(LibraryItem.self, forKey: .libraryItem); chapters = c.value(.chapters, default: []); startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt); updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
    }
}

public struct DeviceInfo: Codable, Hashable, Sendable {
    public var clientVersion: String
    public var manufacturer: String
    public var model: String
    public var deviceId: String
    public var clientName: String
    public init(deviceId: String, clientVersion: String = "1.0.0", manufacturer: String = "Apple", model: String = "Mac", clientName: String = "Audilse") { self.deviceId = deviceId; self.clientVersion = clientVersion; self.manufacturer = manufacturer; self.model = model; self.clientName = clientName }
}

public struct LocalPlaybackSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var libraryItemId: String
    public var episodeId: String?
    public var mediaType: String
    public var mediaMetadata: ItemMetadata
    public var chapters: [Chapter]
    public var displayTitle: String
    public var displayAuthor: String
    public var duration: Double
    public var currentTime: Double
    public var startedAt: Double
    public var updatedAt: Double
    public var timeListening: Double
    public var deviceInfo: DeviceInfo
    public var date: String
    public var dayOfWeek: String
    public init(id: String = UUID().uuidString, libraryItemId: String, episodeId: String? = nil, mediaType: String = "book", mediaMetadata: ItemMetadata = .init(), chapters: [Chapter] = [], displayTitle: String = "", displayAuthor: String = "", duration: Double, currentTime: Double, startedAt: Double = Date().timeIntervalSince1970 * 1000, updatedAt: Double = Date().timeIntervalSince1970 * 1000, timeListening: Double = 0, deviceInfo: DeviceInfo = .init(deviceId: "Audilse"), date: String = "", dayOfWeek: String = "") {
        self.id = id; self.libraryItemId = libraryItemId; self.episodeId = episodeId; self.mediaType = mediaType; self.mediaMetadata = mediaMetadata; self.chapters = chapters; self.displayTitle = displayTitle; self.displayAuthor = displayAuthor; self.duration = duration; self.currentTime = currentTime; self.startedAt = startedAt; self.updatedAt = updatedAt; self.timeListening = timeListening; self.deviceInfo = deviceInfo; self.date = date; self.dayOfWeek = dayOfWeek
    }
}

public struct Bookmark: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(libraryItemId):\(time)" }
    public var libraryItemId: String
    public var title: String
    public var time: Double
    public var createdAt: Double?
    public init(libraryItemId: String, title: String, time: Double, createdAt: Double? = nil) { self.libraryItemId = libraryItemId; self.title = title; self.time = time; self.createdAt = createdAt }
    enum CodingKeys: String, CodingKey { case libraryItemId, title, time, createdAt }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T { (try? decodeIfPresent(T.self, forKey: key)) ?? fallback }
}
