import Foundation

public struct AuthTokens: Codable, Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let userID: String?
    public init(accessToken: String, refreshToken: String? = nil, userID: String? = nil) { self.accessToken = accessToken; self.refreshToken = refreshToken; self.userID = userID }
    public var expiresAt: Date? {
        let pieces = accessToken.split(separator: ".")
        guard pieces.count == 3 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

public protocol TokenStore: Sendable {
    func load(account: String) async throws -> AuthTokens?
    func save(_ tokens: AuthTokens, account: String) async throws
    func remove(account: String) async throws
    func remove(account: String, matching tokens: AuthTokens) async throws
}

public extension TokenStore {
    func remove(account: String, matching tokens: AuthTokens) async throws {
        if try await load(account: account) == tokens { try await remove(account: account) }
    }
}

public actor MemoryTokenStore: TokenStore {
    private var values: [String: AuthTokens] = [:]
    public init() {}
    public func load(account: String) -> AuthTokens? { values[account] }
    public func save(_ tokens: AuthTokens, account: String) { values[account] = tokens }
    public func remove(account: String) { values.removeValue(forKey: account) }
    public func remove(account: String, matching tokens: AuthTokens) { if values[account] == tokens { values.removeValue(forKey: account) } }
}
