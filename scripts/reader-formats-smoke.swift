import AppKit
import Darwin
import Foundation
import PDFKit
import ShelfCore

// Isolated parser/cache/journal smoke. Only --live wrapper phases contact the
// disposable loopback release instance; no Keychain or production profile is used.
private struct Failure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }
}
private struct Manifest: Codable {
    let version: String
    let baseURL: URL
    let libraryID: String
    let userID: String
    let serverID: UUID
    let items: [String: ShelfCore.LibraryItem]
    var partition: AccountPartition { .init(serverID: serverID, userID: userID) }
}
private struct Auth: Decodable {
    let version: String
    let baseURL: URL
    let username: String
    let password: String
    let userID: String
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private let formats: [EbookFormat] = [.pdf, .cbz, .cbr, .azw3, .mobi, .epub]

// Inject the dependencies used by the real ReaderModel, without constructing the
// user's AppStore, application, player, defaults, credentials or main window.
@MainActor final class AppStore {
    var partition: AccountPartition?
    var isOffline = true
    var client: ABSClient?
    var progressByItem: [String: MediaProgress] = [:]
    var readingRepository: ReadingRepository?
}
private func expectedPosition(_ format: EbookFormat) -> (String, Double) {
    if format == .mobi || format == .azw3 { return ("mobi:0:500", 0.5) }
    if format == .epub { return ("epubcfi(/6/2!/4/24[p10]/1:0)", 1.0 / 12.0) }
    return ("2", ReadingCheckpoint.pageProgress(page: 2, count: 3))
}

@MainActor private func parse(_ url: URL, format: EbookFormat, output: URL) async throws {
    switch format {
    case .pdf:
        guard let document = PDFDocument(url: url) else { throw Failure(message: "PDF decode") }
        try require(document.pageCount == 3, "PDF page count")
        for index in 0..<3 {
            guard let page = document.page(at: index) else { throw Failure(message: "PDF page missing") }
            try require(page.string?.contains("ShelfMac PDF page \(index + 1)") == true, "PDF page order/text")
            let thumbnail = page.thumbnail(of: NSSize(width: 150, height: 200), for: .mediaBox)
            try require(thumbnail.size.width > 0 && thumbnail.tiffRepresentation != nil, "PDF native render")
        }
        let matches = document.findString("needle", withOptions: [])
        try require(matches.count == 3 && matches.allSatisfy { !$0.pages.isEmpty }, "PDF native search")
        try require(document.index(for: document.page(at: 1)!) == 1 && ReadingCheckpoint.pageProgress(page: 2, count: 3) == 1.0 / 3.0, "PDF 1-based location")
    case .cbz, .cbr:
        let pages = try await ComicArchive().extract(source: url, destination: output)
        try require(pages.map(\.lastPathComponent) == ["2.png", "10.png", "11.png"], "Comic natural page order")
        for (index, page) in pages.enumerated() {
            guard let image = NSBitmapImageRep(data: try Data(contentsOf: page)), let color = image.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB) else { throw Failure(message: "Comic image decode") }
            try require(image.pixelsWide == 320 && image.pixelsHigh == 420, "Comic image dimensions")
            let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            try require(channels[index] > 0.7 && channels[(index + 1) % 3] < 0.6, "Comic visual page sequence")
        }
    case .epub:
        try await EbookArchiveInspector().validateEPUB(source: url)
    case .mobi, .azw3:
        let bytes = try Data(contentsOf: url)
        try require(bytes.count > 86 && String(decoding: bytes[60..<68], as: UTF8.self) == "BOOKMOBI", "Kindle database")
        let offset = bytes[78..<82].reduce(0) { ($0 << 8) | Int($1) }
        try require(offset <= bytes.count - 40, "Kindle header bounds")
        let version = bytes[(offset + 36)..<(offset + 40)].reduce(0) { ($0 << 8) | Int($1) }
        try require(version == (format == .azw3 ? 8 : 6), "Kindle genuine parser version")
    }
}

@MainActor private func client(for manifest: Manifest) async throws -> ABSClient {
    try require(manifest.version == "2.37.1" && manifest.baseURL.absoluteString == "http://127.0.0.1:13371/compat", "Loopback release allowlist")
    let authURL = URL(fileURLWithPath: "/private/tmp/shelf-compat-servers/v2.37.1/auth.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber
    try require(permissions?.intValue == 0o600, "Private fixture auth file")
    let auth = try JSONDecoder().decode(Auth.self, from: Data(contentsOf: authURL))
    try require(auth.baseURL == manifest.baseURL && auth.version == manifest.version && auth.userID == manifest.userID && auth.username == "shelf-compat-root", "Fixture auth identity")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 20
    let client = ABSClient(profile: .init(id: manifest.serverID, name: "Isolated Reading Fixture", baseURL: manifest.baseURL, serverVersion: manifest.version), session: URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil), tokenStore: MemoryTokenStore())
    try require(try await client.status().serverVersion == manifest.version, "Actual server version")
    let user = try await client.login(username: auth.username, password: auth.password).user
    try require(user.id == manifest.userID && user.isAdmin, "Actual fixture identity")
    let library = try await client.managedLibrary(id: manifest.libraryID)
    try require(library.name == "ShelfMac Compatibility Fixtures", "Disposable library name")
    try require(library.folders.count == 1, "Disposable library folder count")
    let mediaRoot = URL(fileURLWithPath: "/private/tmp/shelf-compat-servers/v2.37.1/media").resolvingSymlinksInPath()
    try require(URL(fileURLWithPath: library.folders[0].fullPath).resolvingSymlinksInPath() == mediaRoot, "Disposable library folder path")
    for format in formats {
        guard let item = manifest.items[format.rawValue] else { throw Failure(message: "Missing fixture format") }
        let actual = try await client.item(id: item.id)
        try require(actual.libraryId == library.id && actual.title == "ShelfMac Reading \(format.rawValue.uppercased())" && actual.media.ebookFile?.metadata.filename == item.media.ebookFile?.metadata.filename && actual.media.duration > 35, "Synthetic write target")
    }
    return client
}

private func verifyNetworkDenied() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    if descriptor < 0 {
        try require(errno == EPERM || errno == EACCES, "Sandbox socket denial")
        return
    }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(13371).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try require(result == -1 && (errno == EPERM || errno == EACCES), "Network must be denied in restart phase")
}

@MainActor private func run(phase: String, work: URL) async throws {
    if phase == "parse" {
        for format in formats {
            try await parse(work.appendingPathComponent("generated/fixture.\(format.rawValue)"), format: format, output: work.appendingPathComponent("parse-\(format.rawValue)"))
            let evidence: String
            switch format {
            case .pdf: evidence = "PDFKit decode/render/text/search/page order"
            case .cbz, .cbr: evidence = "libarchive extraction, PNG decode, natural page order"
            case .epub: evidence = "expanded archive safety (body/CFI tested by reader-smoke.sh)"
            case .azw3, .mobi: evidence = "database/version header (body tested by reader-smoke.sh)"
            }
            print("PASS \(format.rawValue.uppercased()) \(evidence)")
        }
        return
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: work.appendingPathComponent("manifest.json")))
    try require(manifest.version == "2.37.1" && manifest.baseURL.absoluteString == "http://127.0.0.1:13371/compat" && Set(manifest.items.keys) == Set(formats.map(\.rawValue)), "Reader manifest")
    let repository = try ReadingRepository(rootDirectory: work.appendingPathComponent("cache"))
    if phase == "download" {
        let client = try await client(for: manifest)
        for format in formats {
            let item = manifest.items[format.rawValue]!
            let (descriptor, url) = try await repository.original(item: item, partition: manifest.partition, client: client)
            try require(descriptor.bytes > 0 && descriptor.format == format, "Authorized original cache")
            try await parse(url, format: format, output: work.appendingPathComponent("download-\(format.rawValue)"))
            try await client.updateProgress(itemID: item.id, currentTime: 13, duration: item.media.duration, isFinished: false)
            if format.supportsServerProgress { try await client.updateReadingProgress(itemID: item.id, location: "1", progress: 0) }
            let baseline = try await client.progress(itemID: item.id)
            let position = expectedPosition(format)
            try await repository.checkpoint(.init(itemID: item.id, format: format, location: position.0, progress: position.1, baselineLocation: baseline?.ebookLocation, baselineProgress: baseline?.ebookProgress, baselineUpdatedAt: baseline?.lastUpdate), partition: manifest.partition)
            print("PASS \(format.rawValue.uppercased()) authenticated original + durable checkpoint")
        }
        try require(try await repository.pending(partition: manifest.partition).count == 4, "Only server-supported reading formats are queued")
    } else if phase == "offline" {
        try verifyNetworkDenied()
        let otherUser = AccountPartition(serverID: manifest.serverID, userID: "other-isolated-user")
        let store = AppStore()
        store.partition = manifest.partition
        store.readingRepository = repository
        for format in formats {
            let item = manifest.items[format.rawValue]!
            let (_, url) = try await repository.original(item: item, partition: manifest.partition, client: nil)
            try await parse(url, format: format, output: work.appendingPathComponent("offline-\(format.rawValue)"))
            let saved = try await repository.position(itemID: item.id, partition: manifest.partition)
            let expected = expectedPosition(format)
            try require(saved?.location == expected.0 && abs((saved?.progress ?? -1) - expected.1) < 0.000001, "Restored SQLite reading position")
            let otherFile = try await repository.cachedFile(itemID: item.id, partition: otherUser)
            let otherPosition = try await repository.position(itemID: item.id, partition: otherUser)
            try require(otherFile == nil && otherPosition == nil, "Account isolation")
            // The shared server lastUpdate can advance due only to audio playback.
            // Kindle locations are local-only and must keep their paired progress.
            store.progressByItem[item.id] = MediaProgress(libraryItemId: item.id, currentTime: 17, duration: item.media.duration, lastUpdate: Date().timeIntervalSince1970 * 1000 + 1000, ebookLocation: format.supportsServerProgress ? nil : "epubcfi(/6/2!/4/2/1:0)", ebookProgress: 0)
            let model = ReaderModel()
            await model.open(store: store, item: item)
            try require(model.error == nil && model.location == expected.0 && abs(model.progress - expected.1) < 0.000001, "Actual ReaderModel restores paired location/progress after audio update")
            if format == .pdf || format.isComic { try require(model.page == 2 && model.pageCount == 3, "Actual ReaderModel page restore") }
            await model.close(synchronize: false)
            print("PASS \(format.rawValue.uppercased()) new process, denied network, original + position restored")
        }
        try require(try await repository.pending(partition: manifest.partition).count == 4, "Pending journal survived process restart")
    } else if phase == "sync" {
        let client = try await client(for: manifest)
        var kindleBefore: [String: MediaProgress] = [:]
        for format in formats {
            let item = manifest.items[format.rawValue]!
            try await client.updateProgress(itemID: item.id, currentTime: 17, duration: item.media.duration, isFinished: false)
            if !format.supportsServerProgress { kindleBefore[item.id] = try await client.progress(itemID: item.id) }
        }
        try require(try await repository.synchronize(partition: manifest.partition, client: client).isEmpty, "Audio-only change must not conflict with ebook")
        try require(try await repository.pending(partition: manifest.partition).isEmpty, "Verified reading journal acknowledged")
        for format in formats {
            let item = manifest.items[format.rawValue]!
            let remote = try await client.progress(itemID: item.id)
            try require(remote?.currentTime == 17 && remote?.isFinished == false, "Sparse reading PATCH preserves latest audio")
            if format.supportsServerProgress {
                let expected = expectedPosition(format)
                try require(remote?.ebookLocation == expected.0 && abs((remote?.ebookProgress ?? -1) - expected.1) < 0.002, "Remote reading location verified")
            } else {
                try require(remote?.ebookLocation == kindleBefore[item.id]?.ebookLocation && remote?.ebookProgress == kindleBefore[item.id]?.ebookProgress, "Kindle progress remains local-only")
            }
            print("PASS \(format.rawValue.uppercased()) reconnect, audio preserved, reading contract verified")
        }
        let pdf = manifest.items["pdf"]!
        let baseline = try await client.progress(itemID: pdf.id)
        try await repository.checkpoint(.init(itemID: pdf.id, format: .pdf, location: "3", progress: 2.0 / 3.0, baselineLocation: baseline?.ebookLocation, baselineProgress: baseline?.ebookProgress, baselineUpdatedAt: baseline?.lastUpdate), partition: manifest.partition)
        try await Task.sleep(for: .milliseconds(5))
        try await client.updateReadingProgress(itemID: pdf.id, location: "1", progress: 0)
        let conflicts = try await repository.synchronize(partition: manifest.partition, client: client)
        try require(conflicts.count == 1 && conflicts[0].local.itemID == pdf.id, "Other reader edit pauses automatic synchronization")
        try require(try await client.progress(itemID: pdf.id)?.ebookLocation == "1", "Conflict does not overwrite remote")
        try await repository.resolve(conflicts[0], useLocal: false, partition: manifest.partition, client: client)
        try require(try await repository.pending(partition: manifest.partition).isEmpty, "Explicit remote conflict choice acknowledged")
        try require(try await client.progress(itemID: pdf.id)?.currentTime == 17, "Conflict choice preserves audio")
        print("PASS PDF other-device conflict stops automatic write; explicit remote choice preserves audio")
    } else { throw Failure(message: "Unknown phase") }
}

@main private struct Main {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 3 else { print("Usage: ReaderFormatsSmoke parse|download|offline|sync WORKDIR"); exit(2) }
        do {
            try await run(phase: CommandLine.arguments[1], work: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        } catch let error as Failure { print("FAIL \(CommandLine.arguments[1]): \(error.message)"); exit(1) }
        catch let error as ReadingError { print("FAIL \(CommandLine.arguments[1]): \(error.localizedDescription)"); exit(1) }
        catch let ABSError.http(status, _) { print("FAIL \(CommandLine.arguments[1]): HTTP \(status)"); exit(1) }
        catch { print("FAIL \(CommandLine.arguments[1]): \(String(describing: type(of: error)))"); exit(1) }
    }
}
