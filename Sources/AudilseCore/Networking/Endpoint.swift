import Foundation

public enum ABSError: Error, LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case invalidResourcePath
    case untrustedResource
    case notAuthenticated
    case sessionChanged
    case http(status: Int, message: String)
    case invalidResponse
    case unsupportedVersion(String)
    case invalidOIDCCallback
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "服务器地址必须是有效的 HTTP 或 HTTPS 地址。"
        case .invalidResourcePath: "无效的服务器资源路径。"
        case .untrustedResource: "资源地址不属于当前服务器，已阻止发送认证信息。"
        case .notAuthenticated: "登录已过期，请重新登录。"
        case .sessionChanged: "账户已切换，请重新执行操作。"
        case let .http(status, message): "服务器返回 \(status)：\(message)"
        case .invalidResponse: "服务器返回了无效的数据。"
        case let .unsupportedVersion(version): "服务器版本 \(version) 低于支持的 2.26.0。"
        case .invalidOIDCCallback: "单点登录回调验证失败。"
        }
    }
}

public struct ServerEndpoint: Sendable {
    public let baseURL: URL
    public init(baseURL: URL) throws {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(), ["https", "http"].contains(scheme), c.host != nil, c.user == nil, c.password == nil else { throw ABSError.invalidServerURL }
        c.scheme = scheme; c.query = nil; c.fragment = nil
        let components = c.percentEncodedPath.split(separator: "/").map(String.init)
        guard !components.contains(where: Self.isTraversal) else { throw ABSError.invalidServerURL }
        c.percentEncodedPath = components.isEmpty ? "/" : "/" + components.joined(separator: "/") + "/"
        guard let normalized = c.url else { throw ABSError.invalidServerURL }; self.baseURL = normalized
    }
    public func url(path: String) throws -> URL {
        guard !path.hasPrefix("//"), !path.contains("\\"), let input = URLComponents(string: path), input.fragment == nil, input.user == nil, input.password == nil else { throw ABSError.invalidResourcePath }
        let pathComponents = input.percentEncodedPath.split(separator: "/").map(String.init)
        for (index, component) in pathComponents.enumerated() where Self.isTraversal(component) {
            // ABS narrator and taxonomy display names use URI-encoded UTF-8
            // base64, whose final component may contain %2F. Permit only these
            // routes' canonical identifiers, without relaxing other paths.
            guard index == pathComponents.count - 1,
                  (Self.isNarratorIdentifier(pathComponents) || Self.isTaxonomyIdentifier(pathComponents)) else { throw ABSError.invalidResourcePath }
        }
        let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        if input.scheme != nil || input.host != nil {
            guard input.scheme?.lowercased() == base.scheme, input.host?.lowercased() == base.host?.lowercased(), Self.port(input) == Self.port(base), input.path.hasPrefix(base.path) || input.path == String(base.path.dropLast()) else { throw ABSError.untrustedResource }
            guard let url = input.url else { throw ABSError.invalidResourcePath }; return url
        }
        var output = base
        // ABS emits contentUrl beginning /api or /s; preserve the reverse proxy prefix exactly once.
        let prefix = String(base.percentEncodedPath.dropLast())
        let resource = input.percentEncodedPath
        output.percentEncodedPath = !prefix.isEmpty && (resource.hasPrefix(prefix + "/") || resource == prefix) ? resource : base.percentEncodedPath + resource.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        output.percentEncodedQuery = input.percentEncodedQuery
        guard let url = output.url else { throw ABSError.invalidResourcePath }; return url
    }
    private static func port(_ c: URLComponents) -> Int { c.port ?? (c.scheme?.lowercased() == "https" ? 443 : 80) }
    private static func isTraversal(_ text: String) -> Bool {
        var value = text
        for _ in 0..<3 { let decoded = value.removingPercentEncoding ?? value; if decoded == value { break }; value = decoded }
        return value == "." || value == ".." || value.contains("/") || value.contains("\\")
    }
    private static func isNarratorIdentifier(_ components: [String]) -> Bool {
        guard components.count >= 5,
              components[components.count - 5] == "api",
              components[components.count - 4] == "libraries",
              !isTraversal(components[components.count - 3]),
              components[components.count - 2] == "narrators",
              let encoded = components.last,
              let base64 = encoded.removingPercentEncoding,
              component(base64) == encoded,
              let data = Data(base64Encoded: base64), !data.isEmpty,
              data.base64EncodedString() == base64,
              let name = String(data: data, encoding: .utf8), !name.isEmpty else { return false }
        return true
    }
    private static func isTaxonomyIdentifier(_ components: [String]) -> Bool {
        guard components.count >= 3,
              components[components.count - 3] == "api",
              ["tags", "genres"].contains(components[components.count - 2]),
              let encoded = components.last,
              let base64 = encoded.removingPercentEncoding,
              component(base64) == encoded,
              let data = Data(base64Encoded: base64), !data.isEmpty,
              data.base64EncodedString() == base64,
              let name = String(data: data, encoding: .utf8), !name.isEmpty else { return false }
        return true
    }
    public static func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_~"))) ?? "" }
}

public struct ServerVersion: Hashable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public init(_ value: String) {
        let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
        major = parts.first.flatMap { Int($0) } ?? 0
        minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        patch = parts.count > 2 ? Int(parts[2].prefix(while: { $0.isNumber })) ?? 0 : 0
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}

public struct ServerCapabilities: Hashable, Sendable {
    public let version: ServerVersion
    public init(version: String) { self.version = ServerVersion(version) }
    public var isSupported: Bool { version >= ServerVersion("2.26.0") }
    public var separatePersonalEndpoints: Bool { version >= ServerVersion("2.37.1") }
    public var modernMetadataUpdates: Bool { version >= ServerVersion("2.36.1") }
    public var supportsLogoutAllDevices: Bool { version >= ServerVersion("2.36.1") }
}
