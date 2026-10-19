import Foundation

/// The item endpoint adds publication state beside the expanded LibraryItem.
public struct ItemPersonalDetails: Decodable, Sendable {
    public var item: LibraryItem
    public var rssFeed: RSSFeed?
    public var mediaItemShare: MediaShare?
    private enum CodingKeys: String, CodingKey { case rssFeed, mediaItemShare }
    public init(from decoder: Decoder) throws {
        item = try LibraryItem(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rssFeed = try values.decodeIfPresent(RSSFeed.self, forKey: .rssFeed)
        mediaItemShare = try values.decodeIfPresent(MediaShare.self, forKey: .mediaItemShare)
    }
}

public struct PersonalCapabilities: Sendable {
    public let isSupported: Bool
    public let canPublish: Bool
    public let canManageReaderDevices: Bool
    public let canChangePassword: Bool
    public init(user: UserAccount, version: String?) {
        isSupported = ServerVersion(version ?? "2.26.0") >= ServerVersion("2.26.0")
        canPublish = isSupported && user.isActive && user.isAdmin
        canManageReaderDevices = isSupported && user.isActive && user.permissions.createEreader
        canChangePassword = isSupported && user.isActive && user.type != "guest"
    }
}

public enum PersonalFeatureError: Error, LocalizedError {
    case invalidSlug, invalidAddress, invalidDevice, duplicateDevice, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidSlug: "链接名称须为 1–120 位英文字母、数字、连字符或下划线。"
        case .invalidAddress: "服务器地址无效。"
        case .invalidDevice: "阅读器需要名称、有效电子邮件地址，且只能关联当前用户。"
        case .duplicateDevice: "阅读器名称不能重复。"
        case .unavailable: "当前内容不支持此操作。"
        }
    }
}

public enum PersonalPublicationLinks {
    public static func isValidSlug(_ value: String) -> Bool {
        (1...120).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    public static func share(slug: String, profile: ServerProfile) throws -> URL {
        guard isValidSlug(slug) else { throw PersonalFeatureError.invalidSlug }
        return try ServerEndpoint(baseURL: profile.baseURL).url(path: "share/" + ServerEndpoint.component(slug))
    }
    public static func rss(feed: RSSFeed, profile: ServerProfile) throws -> URL {
        try ServerEndpoint(baseURL: profile.baseURL).url(path: feed.feedUrl)
    }
    /// ABS adds its configured router base path; passing it here would duplicate it.
    public static func origin(profile: ServerProfile) throws -> String {
        let endpoint = try ServerEndpoint(baseURL: profile.baseURL)
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else { throw PersonalFeatureError.invalidAddress }
        components.path = ""; components.query = nil; components.fragment = nil
        guard let value = components.string else { throw PersonalFeatureError.invalidAddress }
        return value
    }
    public static func validatePersonalDevices(_ devices: [EReaderDevice], userID: String) throws {
        var names = Set<String>()
        for device in devices {
            guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  device.email.contains("@"), !device.email.contains(where: \.isWhitespace),
                  device.availabilityOption == "specificUsers", device.users == [userID] else { throw PersonalFeatureError.invalidDevice }
            guard names.insert(device.name).inserted else { throw PersonalFeatureError.duplicateDevice }
        }
    }
}
