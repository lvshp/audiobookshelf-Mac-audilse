import Foundation

public struct LoginResponse: Decodable, Sendable {
    public let user: UserAccount
    public let accessToken: String
    public let refreshToken: String?
    public let userDefaultLibraryId: String?
    public let serverVersion: String?
    private enum CodingKeys: String, CodingKey { case user, userDefaultLibraryId, serverVersion, serverSettings }
    private enum UserKeys: String, CodingKey { case accessToken, refreshToken, token }
    private enum SettingsKeys: String, CodingKey { case version, serverVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(UserAccount.self, forKey: .user)
        let u = try c.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        guard let access = try u.decodeIfPresent(String.self, forKey: .accessToken) ?? u.decodeIfPresent(String.self, forKey: .token), !access.isEmpty else { throw ABSError.notAuthenticated }
        accessToken = access; refreshToken = try u.decodeIfPresent(String.self, forKey: .refreshToken)
        userDefaultLibraryId = try c.decodeIfPresent(String.self, forKey: .userDefaultLibraryId)
        let settings = try? c.nestedContainer(keyedBy: SettingsKeys.self, forKey: .serverSettings)
        serverVersion = (try? c.decodeIfPresent(String.self, forKey: .serverVersion)) ?? (try? settings?.decodeIfPresent(String.self, forKey: .version)) ?? (try? settings?.decodeIfPresent(String.self, forKey: .serverVersion))
    }
}

public struct ServerStatus: Decodable, Sendable {
    public let app: String
    public let serverVersion: String
    public let isInit: Bool
    public let language: String?
    public let authMethods: [String]
}
