import CryptoKit
import Foundation

public enum AppUpdateError: Error, LocalizedError, Sendable {
    case invalidVersion, invalidRelease, unsafeURL, missingAsset, invalidResponse, tooLarge, invalidChecksum, checksumMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidVersion: "The update version is invalid."
        case .invalidRelease: "The release is not a supported stable Audilse release."
        case .unsafeURL: "The update download URL is not trusted."
        case .missingAsset: "The release is missing its Apple Silicon installer or checksum."
        case .invalidResponse: "The update server returned an invalid response."
        case .tooLarge: "The update exceeds the allowed download size."
        case .invalidChecksum: "The update checksum file is invalid."
        case .checksumMismatch: "The downloaded installer failed its SHA-256 check."
        }
    }
}

public struct AppUpdateVersion: Comparable, Sendable {
    public let version: String
    public let build: Int
    private let components: [Int]

    public init(version: String, build: Int) throws {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard build >= 0, parts.count == 3 else { throw AppUpdateError.invalidVersion }
        let numbers = try parts.map { part -> Int in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { throw AppUpdateError.invalidVersion }
            return number
        }
        self.version = version; self.build = build; self.components = numbers
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components == rhs.components ? lhs.build < rhs.build : lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct AppUpdateRelease: Sendable {
    public let version: AppUpdateVersion
    public let dmgURL: URL
    public let checksumURL: URL
    public let pageURL: URL
    public let notes: String
    public init(version: AppUpdateVersion, dmgURL: URL, checksumURL: URL, pageURL: URL, notes: String = "") {
        self.version = version; self.dmgURL = dmgURL; self.checksumURL = checksumURL; self.pageURL = pageURL; self.notes = notes
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", let host = url.host, allowed.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public actor GitHubUpdateClient {
    private static let repository = "lvshp/audiobookshelf-Mac-audilse"
    private static let maximumDMG: Int64 = 2 * 1024 * 1024 * 1024
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private struct WireRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: URL
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let browser_download_url: URL
        }
    }

    public func latestRelease() async throws -> AppUpdateRelease {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let file = try await fetch(url, limit: 8 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        return try Self.parseRelease(Data(contentsOf: file))
    }

    // Internal entry point also makes wire-format validation independently testable.
    static func parseRelease(_ data: Data) throws -> AppUpdateRelease {
        let release = try JSONDecoder().decode(WireRelease.self, from: data)
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v") else { throw AppUpdateError.invalidRelease }
        let version = String(release.tag_name.dropFirst())
        _ = try AppUpdateVersion(version: version, build: 0)
        try validateURL(release.html_url, path: "/\(repository)/releases/tag/\(release.tag_name)")
        let prefix = "Audilse-\(version)-build", suffix = "-arm64.dmg"
        var candidates: [(AppUpdateVersion, WireRelease.Asset)] = []
        for asset in release.assets where asset.name.hasPrefix(prefix) && asset.name.hasSuffix(suffix) {
            let digits = String(asset.name.dropFirst(prefix.count).dropLast(suffix.count))
            guard let build = Int(digits), build > 0, String(build) == digits else { throw AppUpdateError.invalidVersion }
            candidates.append((try AppUpdateVersion(version: version, build: build), asset))
        }
        guard let selected = candidates.max(by: { $0.0 < $1.0 }) else { throw AppUpdateError.missingAsset }
        let matchingDMGs = release.assets.filter { $0.name == selected.1.name }
        let checksums = release.assets.filter { $0.name == selected.1.name + ".sha256" }
        guard matchingDMGs.count == 1, checksums.count == 1 else { throw AppUpdateError.missingAsset }
        guard selected.1.size > 0, selected.1.size <= maximumDMG, checksums[0].size > 0, checksums[0].size <= 4096 else { throw AppUpdateError.tooLarge }
        let result = AppUpdateRelease(version: selected.0, dmgURL: selected.1.browser_download_url,
                                      checksumURL: checksums[0].browser_download_url, pageURL: release.html_url, notes: release.body ?? "")
        try validateRelease(result)
        return result
    }

    private static func validateURL(_ url: URL, path: String) throws {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.scheme == "https",
              value.host == "github.com", value.user == nil, value.password == nil, value.port == nil,
              value.query == nil, value.fragment == nil, value.percentEncodedPath == path else { throw AppUpdateError.unsafeURL }
    }
    private static func validateRelease(_ release: AppUpdateRelease) throws {
        let tag = "v\(release.version.version)"
        let name = "Audilse-\(release.version.version)-build\(release.version.build)-arm64.dmg"
        try validateURL(release.dmgURL, path: "/\(repository)/releases/download/\(tag)/\(name)")
        try validateURL(release.checksumURL, path: "/\(repository)/releases/download/\(tag)/\(name).sha256")
        try validateURL(release.pageURL, path: "/\(repository)/releases/tag/\(tag)")
    }

    public func download(_ release: AppUpdateRelease) async throws -> URL {
        try Self.validateRelease(release)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Audilse-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let checksumFile = try await fetch(release.checksumURL, limit: 4096)
        defer { try? FileManager.default.removeItem(at: checksumFile) }
        let expected = try Self.parseChecksum(Data(contentsOf: checksumFile))
        let downloaded = try await fetch(release.dmgURL, limit: Self.maximumDMG)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let actual = try Self.checksum(downloaded)
        guard actual == expected else { throw AppUpdateError.checksumMismatch }
        try Task.checkCancellation()
        let destination = directory.appendingPathComponent(release.dmgURL.lastPathComponent)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        try Task.checkCancellation()
        succeeded = true
        return destination
    }

    static func parseChecksum(_ data: Data) throws -> String {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8),
              let first = text.split(whereSeparator: { $0.isWhitespace }).first, first.count == 64,
              first.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw AppUpdateError.invalidChecksum }
        return first.lowercased()
    }
    static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func fetch(_ url: URL, limit: Int64) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Audilse-Updater/1.0", forHTTPHeaderField: "User-Agent")
        let (location, response) = try await session.download(for: request, delegate: UpdateDownloadDelegate(limit: limit))
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppUpdateError.invalidResponse }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limit, response.expectedContentLength <= limit else { throw AppUpdateError.tooLarge }
            return location
        } catch {
            try? FileManager.default.removeItem(at: location)
            throw error
        }
    }
}
