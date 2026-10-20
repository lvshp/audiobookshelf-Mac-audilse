import Foundation
import Testing
@testable import AudilseCore

private let updateRepository = "https://github.com/lvshp/audiobookshelf-Mac-audilse"
private func updateAsset(_ build: Int, checksum: Bool = false, url: String? = nil, size: Int = 100) -> [String: Any] {
    let name = "Audilse-1.0.0-build\(build)-arm64.dmg" + (checksum ? ".sha256" : "")
    return ["name": name, "size": size, "browser_download_url": url ?? "\(updateRepository)/releases/download/v1.0.0/\(name)"]
}
private func updateWire(_ assets: [[String: Any]], tag: String = "v1.0.0", draft: Bool = false, prerelease: Bool = false, notes: String? = "## Changes\nPlayback fixed.") throws -> Data {
    var body: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                               "html_url": "\(updateRepository)/releases/tag/\(tag)", "assets": assets]
    if let notes { body["body"] = notes }
    return try JSONSerialization.data(withJSONObject: body)
}

@Test func updateVersionOrderingIncludesReplacementBuildAndNumericComponents() throws {
    #expect(try AppUpdateVersion(version: "1.0.0", build: 5) > AppUpdateVersion(version: "1.0.0", build: 4))
    #expect(try AppUpdateVersion(version: "1.10.0", build: 1) > AppUpdateVersion(version: "1.9.99", build: 999))
    #expect(try AppUpdateVersion(version: "1.0.0", build: 99) < AppUpdateVersion(version: "1.0.1", build: 1))
    for invalid in ["1.0", "1.0.0-beta", "01.0.0", "-1.0.0", "1..0", "1.0.999999999999999999999999"] {
        #expect(throws: AppUpdateError.invalidVersion) { try AppUpdateVersion(version: invalid, build: 1) }
    }
    #expect(throws: AppUpdateError.invalidVersion) { try AppUpdateVersion(version: "1.0.0", build: -1) }
}

@Test func updateReleaseSelectsHighestBuildAndPreservesFullNotes() throws {
    let data = try updateWire([updateAsset(4), updateAsset(5, checksum: true), updateAsset(5), updateAsset(4, checksum: true)])
    let release = try GitHubUpdateClient.parseRelease(data)
    #expect(release.version.build == 5)
    #expect(release.notes == "## Changes\nPlayback fixed.")
    let empty = try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5), updateAsset(5, checksum: true)], notes: nil))
    #expect(empty.notes.isEmpty)
}

@Test func updateReleaseRejectsMissingChecksumRatherThanDowngrading() throws {
    #expect(throws: AppUpdateError.missingAsset) {
        try GitHubUpdateClient.parseRelease(updateWire([updateAsset(4), updateAsset(4, checksum: true), updateAsset(5)]))
    }
    #expect(throws: AppUpdateError.missingAsset) {
        try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5), updateAsset(5), updateAsset(5, checksum: true)]))
    }
    #expect(throws: AppUpdateError.missingAsset) {
        try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5), updateAsset(5, checksum: true)], tag: "v1.0.1"))
    }
    for (draft, prerelease) in [(true, false), (false, true)] {
        #expect(throws: AppUpdateError.invalidRelease) {
            try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5), updateAsset(5, checksum: true)], draft: draft, prerelease: prerelease))
        }
    }
}

@Test func updateReleaseRejectsUnsafeOrCrossRepositoryAssetURLs() throws {
    for url in ["http://github.com/lvshp/audiobookshelf-Mac-audilse/releases/download/v1.0.0/Audilse-1.0.0-build5-arm64.dmg",
                "https://github.com/other/repo/releases/download/v1.0.0/Audilse-1.0.0-build5-arm64.dmg",
                "https://github.com/lvshp/audiobookshelf-Mac-audilse/releases/download/v1.0.1/Audilse-1.0.0-build5-arm64.dmg",
                "https://github.com.evil.test/installer.dmg", "file:///tmp/installer.dmg"] {
        #expect(throws: AppUpdateError.unsafeURL) {
            try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5, url: url), updateAsset(5, checksum: true)]))
        }
    }
    #expect(throws: AppUpdateError.tooLarge) {
        try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5, size: 3_000_000_000), updateAsset(5, checksum: true)]))
    }
}

@Test func updateChecksumAcceptsBuildPathAndStreamsFileBytes() throws {
    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #expect(try GitHubUpdateClient.parseChecksum(Data((expected + "  build/ci-output/Audilse-1.0.0-build5-arm64.dmg\n").utf8)) == expected)
    #expect(throws: AppUpdateError.invalidChecksum) { try GitHubUpdateClient.parseChecksum(Data("not-a-hash file.dmg".utf8)) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("abc".utf8).write(to: file)
    #expect(try GitHubUpdateClient.checksum(file) == expected)
}

private final class AppUpdateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let expected = request.url!.path.contains("build6")
            ? "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" : String(repeating: "0", count: 64)
        let data = request.url!.path.hasSuffix(".sha256") ? Data((expected + "  build/ci-output/fixture.dmg\n").utf8) : Data("abc".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func updateDownloadRejectsHashMismatchThroughInjectedSession() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AppUpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = GitHubUpdateClient(session: session)
    let temporaryRoot = FileManager.default.temporaryDirectory
    func updateDirectories() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Audilse-update-") })
    }
    let originalDirectories = try updateDirectories()
    let release = try GitHubUpdateClient.parseRelease(updateWire([updateAsset(5), updateAsset(5, checksum: true)]))
    await #expect(throws: AppUpdateError.checksumMismatch) { try await client.download(release) }
    #expect(try updateDirectories() == originalDirectories)
    let valid = try GitHubUpdateClient.parseRelease(updateWire([updateAsset(6), updateAsset(6, checksum: true)]))
    let events = UpdateProgressRecorder()
    let file = try await client.download(valid) { events.append($0) }
    #expect(events.values.first == .fetchingChecksum)
    #expect(events.values.contains(.downloading(received: 3, total: 3)))
    #expect(events.values.last == .verifyingDownload)
    #expect(try Data(contentsOf: file) == Data("abc".utf8))
    #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix("Audilse-update-"))
    try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.download(valid)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try updateDirectories() == originalDirectories)
}

@Test func updatePatchReleaseWithResetBuildIsNewerThanInstalledVersion() throws {
    let name = "Audilse-1.0.1-build1-arm64.dmg"
    let assets: [[String: Any]] = [name, name + ".sha256"].map {
        ["name": $0, "size": 100, "browser_download_url": "\(updateRepository)/releases/download/v1.0.1/\($0)"]
    }
    let release = try GitHubUpdateClient.parseRelease(updateWire(assets, tag: "v1.0.1", notes: "Expanded player and search focus fixes."))
    for installedBuild in [5, 6, 7, 8] {
        #expect(try release.version > AppUpdateVersion(version: "1.0.0", build: installedBuild))
    }
    #expect(release.version.version == "1.0.1")
    #expect(release.version.build == 1)
    #expect(release.notes == "Expanded player and search focus fixes.")
}

private final class UpdateProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AppUpdateProgress] = []
    func append(_ value: AppUpdateProgress) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    var values: [AppUpdateProgress] { lock.lock(); defer { lock.unlock() }; return recorded }
}
