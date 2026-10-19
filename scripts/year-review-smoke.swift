import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import ShelfCore
import SwiftUI

// Compiles the actual product renderer, poster and authenticated cover model.
// AppStore supplies identity only; no live server, player, visible window or share UI is used.
@MainActor @Observable final class AppStore {
    var partition: AccountPartition?
    var client: ABSClient?
    var user: UserAccount?
    var profile: ServerProfile?
    var isDemo = false
    var isOffline = false
    var isConnecting = false
}

private struct SmokeFailure: Error { let reason: String }
private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw SmokeFailure(reason: reason) }
}
private struct Reply: Sendable {
    let status: Int
    let data: Data
    var held = false
}
private final class CoverFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var reply = Reply(status: 403, data: Data())
    private var pending: [CoverProtocol] = []
    private var count = 0
    private var invalid = false
    func install(_ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        self.reply = reply; pending = []; count = 0; invalid = false
    }
    func respond(_ request: URLRequest, loader: CoverProtocol) throws -> Reply? {
        lock.lock(); defer { lock.unlock() }
        guard request.url?.host == "year-review.fixture.test", request.httpMethod == "GET",
              let path = request.url?.path, path.hasPrefix("/compat/api/items/"), path.hasSuffix("/cover"),
              request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-year-token" else {
            invalid = true; throw SmokeFailure(reason: "Unexpected request or missing synthetic authorization")
        }
        count += 1
        if reply.held { pending.append(loader); return nil }
        return reply
    }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var hasInvalidRequest: Bool { lock.lock(); defer { lock.unlock() }; return invalid }
    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
    func release() {
        lock.lock(); let loaders = pending; pending = []; let reply = reply; lock.unlock()
        for loader in loaders { loader.deliver(reply) }
    }
}
private final class CoverProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = CoverFixture()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { if let reply = try Self.fixture.respond(request, loader: self) { deliver(reply) } }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func deliver(_ reply: Reply) {
        lock.lock(); let stopped = stopped; lock.unlock()
        guard !stopped, let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@MainActor private func account() async -> AppStore {
    let store = AppStore()
    let profile = ServerProfile(name: "Year review fixture", baseURL: URL(string: "https://year-review.fixture.test/compat")!, serverVersion: "2.37.1")
    let tokens = MemoryTokenStore()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoverProtocol.self]
    let client = ABSClient(profile: profile, session: URLSession(configuration: configuration), tokenStore: tokens)
    await tokens.save(.init(accessToken: "synthetic-year-token", userID: "year-fixture"), account: client.tokenAccount)
    store.client = client; store.profile = profile; store.partition = .init(serverID: profile.id, userID: "year-fixture")
    store.user = .init(id: "year-fixture", username: "fixture")
    return store
}

private func annual(zero: Bool = false, long: Bool = false) throws -> YearlyStatistics {
    let author = long ? "A Very Long Author Name · 极长作者姓名与多语言组合 " + String(repeating: "Stories and Characters 故事与人物 ", count: 8) : "Fixture Author"
    let genre = long ? "Speculative Fiction / 历史与科幻 / " + String(repeating: "Unusually Long Category 极长分类 ", count: 8) : "Fiction"
    let narrator = long ? "A Very Long Narrator Name · " + String(repeating: "声音与故事 Voice and Story ", count: 8) : "Fixture Narrator"
    let data: [String: Any] = [
        "totalListeningSessions": zero ? 0 : 246,
        "totalListeningTime": zero ? 0 : 2_346_789,
        "totalBookListeningTime": zero ? 0 : 2_000_000,
        "totalPodcastListeningTime": zero ? 0 : 346_789,
        "topAuthors": zero ? [] : [["name": author, "time": 900_000], ["name": "Second Author", "time": 800_000], ["name": "Third Author", "time": 300_000]],
        "topGenres": zero ? [] : [["genre": genre, "time": 900_000], ["genre": "History", "time": 800_000], ["genre": "Mystery", "time": 300_000]],
        "mostListenedNarrator": zero ? NSNull() : ["name": narrator, "time": 700_000],
        "mostListenedMonth": zero ? NSNull() : ["month": 0, "time": 500_000],
        "numBooksFinished": zero ? 0 : 36,
        "numBooksListened": zero ? 0 : 58,
        "longestAudiobookFinished": NSNull(),
        "booksWithCovers": zero ? [] : ["cover-a", "cover-b", "cover-c", "cover-d", "cover-e", "cover-f"],
        "finishedBooksWithCovers": zero ? [] : ["cover-a", "cover-b", "cover-a", "cover-c", "cover-d", "cover-e"]
    ]
    return try JSONDecoder().decode(YearlyStatistics.self, from: JSONSerialization.data(withJSONObject: data))
}

private func syntheticCover() throws -> Data {
    let width = 720, height = 960
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SmokeFailure(reason: "Could not create synthetic cover context")
    }
    context.setFillColor(CGColor(red: 0.82, green: 0.29, blue: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.95, green: 0.77, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 90, y: 140, width: 540, height: 670))
    context.setFillColor(CGColor(red: 0.14, green: 0.24, blue: 0.39, alpha: 1)); context.fill(CGRect(x: 180, y: 290, width: 360, height: 370))
    guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw SmokeFailure(reason: "Could not encode synthetic cover PNG")
    }
    return png
}

private func serverAnnual(zero: Bool = false, long: Bool = false) throws -> AdminYearlyStatistics {
    let author = long ? String(repeating: "Extremely Long Author Name 极长作者姓名 ", count: 9) : "Fixture Author"
    let genre = long ? String(repeating: "Unusually Long Genre 极长分类 ", count: 9) : "Fiction"
    let narrator = long ? String(repeating: "Extremely Long Narrator Name 极长旁白姓名 ", count: 9) : "Fixture Narrator"
    let data: [String: Any] = [
        "numListeningSessions": zero ? 0 : 12345, "numBooksAdded": zero ? 0 : 345, "numAuthorsAdded": zero ? 0 : 678,
        "totalBooksAddedSize": zero ? 0 : 8_589_934_593, "totalBooksAddedDuration": zero ? 0 : 12_345_678,
        "booksAddedWithCovers": zero ? [] : ["cover-a", "cover-b", "cover-a", "cover-c", "cover-d", "cover-e", "cover-f"],
        "totalBooksSize": zero ? 0 : 17_179_869_185, "totalBooksDuration": zero ? 0 : 98_765_432,
        "totalListeningTime": zero ? 0 : 2_346_789, "numBooks": zero ? 0 : 12345,
        "topAuthors": zero ? [] : [["name": author, "time": 900_000], ["name": "Second Author", "time": 800_000], ["name": "Third Author", "time": 300_000]],
        "topNarrators": zero ? [] : [["name": narrator, "time": 900_000], ["name": "Second Narrator", "time": 800_000], ["name": "Third Narrator", "time": 300_000]],
        "topGenres": zero ? [] : [["genre": genre, "time": 900_000], ["genre": "History", "time": 800_000], ["genre": "Mystery", "time": 300_000]]
    ]
    return try JSONDecoder().decode(AdminYearlyStatistics.self, from: JSONSerialization.data(withJSONObject: data))
}

private struct Pixels { let digest: String; let brightCount: Int; let colorCount: Int }
private func verifyPNG(_ data: Data, width: Int, height: Int) throws -> Pixels {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) as String? == "public.png",
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SmokeFailure(reason: "Renderer output is not a readable PNG") }
    try require(image.width == width && image.height == height, "Rendered pixel dimensions differ from logical size × renderer scale 2")
    let length = width * height * 4
    var pixels = [UInt8](repeating: 0, count: length)
    let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
    }
    try require(drew, "Could not inspect rendered pixels")
    var bright = 0, colors = Set<UInt32>()
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let red = pixels[index], green = pixels[index + 1], blue = pixels[index + 2]
        if red > 215 && green > 215 && blue > 215 { bright += 1 }
        if index.isMultiple(of: 64) { colors.insert(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)) }
    }
    try require(bright > 500 && colors.count > 50, "PNG is empty or lacks rendered foreground content")
    return .init(digest: SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined(), brightCount: bright, colorCount: colors.count)
}

private func waitHeld() async throws {
    for _ in 0..<300 {
        if CoverProtocol.fixture.isHeld { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw SmokeFailure(reason: "Cover request did not reach fixture gate")
}

@main private struct YearReviewSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch let failure as SmokeFailure { print("FAIL year-review: \(failure.reason)"); exit(1) }
        catch { print("FAIL year-review: unexpected fixture error"); exit(1) }
    }
    @MainActor static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        try require(NSApp.windows.isEmpty, "Fixture must not create windows")
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
        let serverOnly = CommandLine.arguments.contains("--server-only")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let previousLanguage = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previousLanguage }
        AppLanguageStore.shared.selection = .english
        try require(L10n.tr("听完书籍") != "听完书籍", "Real English resources were not loaded")

        let account = await account(), artwork = YearReviewCoverModel(), png = try syntheticCover()
        CoverProtocol.fixture.install(.init(status: 200, data: png))
        await artwork.load(store: account, ids: ["cover-a", "cover-b", "cover-a", "", "cover-c", "cover-d", "cover-e", "cover-f"])
        try require(artwork.images.count == 6 && artwork.unavailableCount == 0 && !artwork.isLoading, "Valid authorized covers were not decoded")
        try require(CoverProtocol.fixture.requestCount == 6 && !CoverProtocol.fixture.hasInvalidRequest, "Cover requests did not preserve authentication/deduplication")
        let validCovers = artwork.images
        print("PASS year-review authorized-cover-load-and-dedup")

        if !serverOnly {
        CoverProtocol.fixture.install(.init(status: 200, data: png))
        await artwork.load(store: account, ids: (0..<31).map { "bounded-\($0)" })
        try require(artwork.images.count == 25 && CoverProtocol.fixture.requestCount == 25, "Cover loading did not respect 25-cover bound")
        print("PASS year-review cover-request-bound")

        CoverProtocol.fixture.install(.init(status: 403, data: Data()))
        await artwork.load(store: account, ids: ["cover-a", "cover-b"])
        try require(artwork.images.isEmpty && artwork.unavailableCount == 2 && !artwork.isLoading && !CoverProtocol.fixture.hasInvalidRequest, "Authorization failure did not finish with explicit fallback")
        print("PASS year-review authorized-cover-failure-fallback")

        CoverProtocol.fixture.install(.init(status: 200, data: Data("not-an-image".utf8)))
        await artwork.load(store: account, ids: ["malformed"])
        try require(artwork.images.isEmpty && artwork.unavailableCount == 1 && !artwork.isLoading, "Malformed cover did not finish with fallback")
        print("PASS year-review malformed-cover-fallback")

        CoverProtocol.fixture.install(.init(status: 200, data: png, held: true))
        let originalPartition = account.partition
        let loading = Task { await artwork.load(store: account, ids: ["late-account"]) }
        try await waitHeld()
        account.partition = .init(serverID: UUID(), userID: "different-account")
        CoverProtocol.fixture.release(); await loading.value
        try require(artwork.images.isEmpty && !artwork.isLoading, "A late cover crossed account identity")
        account.partition = originalPartition
        print("PASS year-review late-account-cover-rejected")

        CoverProtocol.fixture.install(.init(status: 200, data: png))
        await artwork.load(store: account, ids: ["stable"])
        let stableRevision = artwork.revision
        let cancelled = Task { await artwork.load(store: account, ids: ["cancelled-before-entry"]) }
        cancelled.cancel(); await cancelled.value
        try require(artwork.images["stable"] != nil && artwork.images.count == 1 && artwork.revision == stableRevision &&
            CoverProtocol.fixture.requestCount == 1, "An already-cancelled cover task cleared the winning snapshot")
        print("PASS year-review cancelled-entry-preserves-winning-covers")
        }

        let normal = try annual(), long = try annual(long: true), zero = try annual(zero: true)
        let datasets: [(String, YearlyStatistics, [String: NSImage])] = [
            ("normal", normal, validCovers), ("long", long, validCovers),
            ("zero", zero, [:]), ("fallback", normal, [:])
        ]
        var digests: [String: String] = [:]
        var manifest: [[String: Any]] = []
        if serverOnly, let previous = try? Data(contentsOf: output.appendingPathComponent("manifest.json")),
           let existing = try? JSONSerialization.jsonObject(with: previous) as? [[String: Any]] {
            manifest = existing.filter { ($0["file"] as? String)?.hasPrefix("personal-") == true }
        }
        if !serverOnly {
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.selection = language
            for (name, statistics, covers) in datasets {
                let original = statistics.finishedBooksWithCovers
                for style in 0..<4 {
                    let size = style == 3 ? CGSize(width: 600, height: 200) : CGSize(width: 800, height: 800)
                    guard let rendered = YearReviewRenderer.png(PersonalYearReviewPoster(year: 2025, statistics: statistics, style: style, covers: covers)
                        .environment(\.locale, language.locale), size: size) else { throw SmokeFailure(reason: "Actual ImageRenderer returned nil") }
                    let pixels = try verifyPNG(rendered.data, width: Int(size.width * 2), height: Int(size.height * 2))
                    let name = "personal-\(language.rawValue)-\(name)-\(style + 1)"
                    try rendered.data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                    digests[name] = pixels.digest
                    manifest.append(["file": name + ".png", "width": Int(size.width * 2), "height": Int(size.height * 2),
                        "bytes": rendered.data.count, "pixelSHA256": pixels.digest, "brightPixels": pixels.brightCount, "sampledColors": pixels.colorCount])
                    try require(statistics.finishedBooksWithCovers == original, "Poster mutated finished cover IDs")
                    print("PASS year-review render \(name) \(Int(size.width * 2))x\(Int(size.height * 2))")
                }
            }
        }
        for style in 1...4 {
            try require(digests["personal-en-normal-\(style)"] != digests["personal-zh-Hans-normal-\(style)"], "English and Chinese posters rendered identical pixels")
            for language in AppLanguage.allCases {
                try require(digests["personal-\(language.rawValue)-normal-\(style)"] != digests["personal-\(language.rawValue)-fallback-\(style)"], "Valid covers did not change the rendered poster")
                try require(digests["personal-\(language.rawValue)-normal-\(style)"] != digests["personal-\(language.rawValue)-zero-\(style)"], "Zero statistics rendered the same as populated statistics")
            }
        }
        }
        let serverDatasets: [(String, AdminYearlyStatistics, [String: NSImage])] = [
            ("normal", try serverAnnual(), validCovers), ("long", try serverAnnual(long: true), validCovers),
            ("zero", try serverAnnual(zero: true), [:]), ("fallback", try serverAnnual(), [:])
        ]
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.selection = language
            for (name, statistics, covers) in serverDatasets {
                for style in 0..<3 {
                    guard let rendered = YearReviewRenderer.png(ServerStatisticsReviewPoster(year: 2025, statistics: statistics, style: style, covers: covers)
                        .environment(\.locale, language.locale), size: .init(width: 800, height: 800)) else { throw SmokeFailure(reason: "Actual server ImageRenderer returned nil") }
                    let pixels = try verifyPNG(rendered.data, width: 1600, height: 1600)
                    let name = "server-\(language.rawValue)-\(name)-\(style + 1)"
                    try rendered.data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
                    digests[name] = pixels.digest
                    manifest.append(["file": name + ".png", "width": 1600, "height": 1600, "bytes": rendered.data.count,
                        "pixelSHA256": pixels.digest, "brightPixels": pixels.brightCount, "sampledColors": pixels.colorCount])
                    print("PASS year-review render \(name) 1600x1600")
                }
            }
        }
        for style in 1...3 {
            try require(digests["server-en-normal-\(style)"] != digests["server-zh-Hans-normal-\(style)"], "English and Chinese server posters rendered identical pixels")
            for language in AppLanguage.allCases {
                try require(digests["server-\(language.rawValue)-normal-\(style)"] != digests["server-\(language.rawValue)-fallback-\(style)"], "Valid covers did not change the server poster")
                try require(digests["server-\(language.rawValue)-normal-\(style)"] != digests["server-\(language.rawValue)-zero-\(style)"], "Zero server statistics rendered the same as populated statistics")
            }
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        try require(NSApp.windows.isEmpty, "Rendering created a visible-window candidate")
        print("PASS year-review semantic-pixel-differences-and-no-windows")
        if serverOnly { print("Year review smoke: authorized covers and 24 actual server PNG renders passed; personal renders were not repeated") }
        else { print("Year review smoke: 6 authenticated-cover checks, 32 actual personal PNG renders and 24 actual server PNG renders passed") }
        print("Images: \(output.path)")
    }
}
