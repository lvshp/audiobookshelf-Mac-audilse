import Foundation
import CryptoKit

public struct PublicShareLocation: Hashable, Sendable {
    public let baseURL: URL
    public let slug: String
    public let initialTime: Double?
    public let storageKey: String
    public init(link: URL) throws {
        guard var c = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.fragment == nil, !c.percentEncodedPath.contains("//") else { throw PublicShareError.invalidLink }
        let components = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2, components[components.count - 2] == "share",
              !components.contains(where: Self.unsafe),
              let slug = components.last?.removingPercentEncoding, !slug.isEmpty else { throw PublicShareError.invalidLink }
        let times = (c.queryItems ?? []).filter { $0.name == "t" }
        guard times.count <= 1 else { throw PublicShareError.invalidLink }
        if let item = times.first {
            guard let raw = item.value, let value = Double(raw), value.isFinite, value >= 0,
                  value < Double(Int64.max) else { throw PublicShareError.invalidLink }
            initialTime = floor(value)
        } else { initialTime = nil }
        c.scheme = scheme; c.host = host.lowercased(); c.query = nil; c.fragment = nil
        let prefix = components.dropLast(2)
        c.percentEncodedPath = prefix.isEmpty ? "/" : "/" + prefix.joined(separator: "/") + "/"
        if c.port == (scheme == "https" ? 443 : 80) { c.port = nil }
        guard let base = c.url else { throw PublicShareError.invalidLink }
        baseURL = base; self.slug = slug
        storageKey = SHA256.hash(data: Data((base.absoluteString + "share/" + Self.component(slug)).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func url(suffix: String = "", includeStart: Bool = false) throws -> URL {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw PublicShareError.invalidLink }
        c.percentEncodedPath += "public/share/" + Self.component(slug) + suffix
        if includeStart, let initialTime { c.queryItems = [.init(name: "t", value: String(Int64(initialTime)))] }
        guard let url = c.url else { throw PublicShareError.invalidLink }
        return url
    }
    func validateTrackURL(_ text: String, index: Int) throws {
        guard index >= 0, let input = URLComponents(string: text), input.user == nil, input.password == nil,
              input.fragment == nil, input.query == nil, !text.hasPrefix("//"), !text.contains("\\"),
              !input.percentEncodedPath.split(separator: "/").map(String.init).contains(where: Self.unsafe) else { throw PublicShareError.untrustedResource }
        let expected = try url(suffix: "/track/\(index)")
        let candidate: URL?
        if input.scheme != nil || input.host != nil { candidate = input.url }
        else if input.percentEncodedPath.hasPrefix("/") {
            var origin = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            origin.percentEncodedPath = input.percentEncodedPath; candidate = origin.url
        } else { candidate = URL(string: text, relativeTo: baseURL)?.absoluteURL }
        guard let candidate, var actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              var target = URLComponents(url: expected, resolvingAgainstBaseURL: false) else { throw PublicShareError.untrustedResource }
        actual.scheme = actual.scheme?.lowercased(); actual.host = actual.host?.lowercased()
        if actual.port == (actual.scheme == "https" ? 443 : 80) { actual.port = nil }
        if target.port == (target.scheme == "https" ? 443 : 80) { target.port = nil }
        guard actual.scheme == target.scheme, actual.host == target.host, actual.port == target.port,
              actual.percentEncodedPath.removingPercentEncoding == target.percentEncodedPath.removingPercentEncoding else { throw PublicShareError.untrustedResource }
    }
    static func component(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))! }
    private static func unsafe(_ value: String) -> Bool {
        var current = value
        for _ in 0..<4 {
            if current == "." || current == ".." || current.contains("\\") || current.contains("/") || current.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return true }
            guard let decoded = current.removingPercentEncoding else { return true }
            if decoded == current { return false }; current = decoded
        }
        return current.contains("%") || current == "." || current == ".." || current.contains("/") || current.contains("\\")
    }
}
