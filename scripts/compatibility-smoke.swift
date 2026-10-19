import Foundation
import AudilseCore

// Opt-in integration smoke for three disposable loopback ABS release instances.
// Credentials are read from private temporary fixture manifests, never arguments or output.
private struct Fixture: Decodable {
    let version: String
    let baseURL: URL
    let username: String
    let password: String
    let userID: String
    let libraryID: String
    let itemIDs: [String]
}
private struct CheckFailure: Error { let reason: String }
private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw CheckFailure(reason: reason) }
}
private final class LoopbackRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class UploadEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LibraryUploadProgress] = []
    func record(_ value: LibraryUploadProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func completedUpload() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.contains { $0.phase == .preparing && $0.completedBytes == $0.totalBytes && $0.totalBytes > 0 }
            && values.contains { $0.phase == .uploading && $0.completedBytes == $0.totalBytes && $0.totalBytes > 0 }
    }
}
@MainActor private final class CompatibilityRun {
    let fixture: Fixture
    let client: ABSClient
    let directory: URL
    let runID = UUID().uuidString.lowercased()
    var currentStep = "fixture-guard"
    var checks = 0
    init(fixture: Fixture, directory: URL) throws {
        let ports = ["2.26.0": 13326, "2.36.1": 13361, "2.37.1": 13371]
        guard let port = ports[fixture.version], fixture.baseURL.absoluteString == "http://127.0.0.1:\(port)/compat",
              fixture.username == "shelf-compat-root", fixture.itemIDs.count == 2 else { throw CheckFailure(reason: "fixture allowlist") }
        self.fixture = fixture; self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: LoopbackRedirects(), delegateQueue: nil)
        client = ABSClient(profile: .init(name: "Isolated Compatibility", baseURL: fixture.baseURL, serverVersion: fixture.version), session: session, tokenStore: MemoryTokenStore())
    }
    func step(_ name: String, _ work: () async throws -> Void) async throws {
        currentStep = name
        try await work()
        checks += 1
        print("PASS \(fixture.version) \(name)")
    }
    func run() async throws {
        try await step("login-refresh-identity") {
            let status = try await client.status()
            try require(status.serverVersion == fixture.version, "release version")
            let response = try await client.login(username: fixture.username, password: fixture.password)
            try require(response.user.id == fixture.userID && response.user.isAdmin, "fixture root identity")
            _ = try await client.refresh()
            let user = try await client.currentUser()
            try require(user.id == fixture.userID && user.username == fixture.username, "refreshed identity")
        }
        try await step("library-pagination-details") {
            let libraries = try await client.libraries()
            try require(libraries.contains { $0.id == fixture.libraryID && $0.name == "Audilse Compatibility Fixtures" }, "fixture library")
            let managed = try await client.managedLibrary(id: fixture.libraryID)
            let mediaRoot = directory.appendingPathComponent("media").resolvingSymlinksInPath().path
            try require(managed.folders.count == 1 && URL(fileURLWithPath: managed.folders[0].fullPath).resolvingSymlinksInPath().path == mediaRoot, "isolated media directory")
            let first = try await client.libraryItems(libraryID: fixture.libraryID, page: 0, limit: 1)
            let second = try await client.libraryItems(libraryID: fixture.libraryID, page: 1, limit: 1)
            try require(first.results.count == 1 && second.results.count == 1 && first.results[0].id != second.results[0].id && first.total >= 2, "distinct paged items")
            for id in fixture.itemIDs {
                let item = try await client.item(id: id)
                try require(item.libraryId == fixture.libraryID && item.media.duration > 35 && !item.media.tracks.isEmpty && item.media.chapters.count == 2, "expanded synthetic book")
            }
            let results = try await client.libraryItems(libraryID: fixture.libraryID, search: "Compat")
            try require(Set(fixture.itemIDs).isSubset(of: Set(results.results.map(\.id))), "library search")
        }
        let initial = try await client.batchItems(ids: fixture.itemIDs)
        try require(initial.count == 2 && initial.allSatisfy { $0.libraryId == fixture.libraryID }, "batch fixture scope")
        let book = try await ebookBook()
        let otherID = try unwrap(fixture.itemIDs.first { $0 != book.id }, "second fixture")
        try await step("sparse-metadata-series-batch") {
            let old = try await client.item(id: book.id)
            var metadata = MetadataUpdate()
            metadata.subtitle = "Compatibility \(runID)"
            metadata.series = [.init(name: "Compat Series", sequence: "2.5"), .init(name: "Compat Additional", sequence: nil)]
            let result = try await client.updateItemMedia(id: book.id, update: .init(metadata: metadata))
            try require(result.updated, "media update acknowledgement")
            let updated = try await client.item(id: book.id)
            try require(updated.media.metadata.title == old.media.metadata.title && updated.media.metadata.authors == old.media.metadata.authors, "sparse metadata preserved")
            try require(updated.media.metadata.series.contains { $0.name == "Compat Series" && $0.sequence == "2.5" } && updated.media.metadata.series.contains { $0.name == "Compat Additional" }, "series relationships persisted")
            var edits = BatchMetadataEdits()
            edits.publishedYear = "2026"; edits.isbn = "9780000000000"; edits.abridged = false; edits.tags = ["compat-smoke"]; edits.subtitle = "Batch " + runID
            let items = try await client.batchItems(ids: fixture.itemIDs)
            let batch = try await client.batchUpdateItemMedia(items.map { edits.applying(to: $0, appendLists: true) })
            try require(batch.success && batch.updates == 2, "batch updates acknowledged")
            for id in fixture.itemIDs {
                let fresh = try await client.item(id: id)
                try require(fresh.media.metadata.publishedYear == "2026" && fresh.media.metadata.isbn == "9780000000000" && fresh.media.tags.contains("compat-smoke"), "batch fields persisted")
            }
            let series = try await client.series(libraryID: fixture.libraryID)
            let relationship = try unwrap(series.results.first { $0.name == "Compat Additional" }, "series listed")
            let seriesItem = try await client.series(id: relationship.id, libraryID: fixture.libraryID)
            let seriesBooks = try await client.items(libraryID: fixture.libraryID, seriesID: relationship.id)
            try require(seriesItem.progress?.libraryItemIds.contains(book.id) == true && seriesBooks.results.contains { $0.id == book.id }, "series includes book")
            let changed = try await client.updateSeries(id: relationship.id, update: .init(description: "Synthetic compatibility series"))
            try require(changed.description == "Synthetic compatibility series", "series update")
            let authors = try await client.authors(libraryID: fixture.libraryID)
            try require(!authors.results.isEmpty, "authors decoded")
            let author = try await client.author(id: authors.results[0].id)
            try require(author.libraryItems.contains { fixture.itemIDs.contains($0.id) }, "author items decoded")
        }
        try await step("chapters-tracks-ebook-primary") {
            let chapters = [Chapter(id: 0, title: "Compatibility first", start: 0, end: 20), Chapter(id: 1, title: "Compatibility second", start: 20, end: book.media.duration)]
            let response = try await client.updateChapters(itemID: book.id, chapters: chapters)
            try require(response.success, "chapter acknowledgement")
            let fresh = try await client.item(id: book.id)
            try require(fresh.media.chapters.map(\.title) == chapters.map(\.title), "chapter titles persisted")
            let tracks = fresh.media.audioFiles.map { OrderedAudioFile(ino: $0.ino, exclude: false) }
            let ordered = try await client.updateAudioTrackOrder(itemID: book.id, files: tracks)
            let expandedOrder = try await client.item(id: book.id)
            try require(ordered.media.audioFiles.map(\.ino) == fresh.media.audioFiles.map(\.ino) && expandedOrder.media.tracks.count == fresh.media.tracks.count, "track order persisted")
            let files = try await client.managedItemFiles(id: book.id)
            let pdf = try unwrap(files.first { $0.isEBook && $0.metadata.filename.hasSuffix(".pdf") }, "PDF fixture")
            let epub = try unwrap(files.first { $0.isEBook && $0.metadata.filename.hasSuffix(".epub") }, "EPUB fixture")
            if pdf.isSupplementary != false { try await client.toggleEBookSupplementary(itemID: book.id, fileID: pdf.ino) }
            var after = try await client.managedItemFiles(id: book.id)
            try require(after.first { $0.ino == pdf.ino }?.isSupplementary == false && after.first { $0.ino == epub.ino }?.isSupplementary == true, "PDF promoted, EPUB supplementary")
            try await client.toggleEBookSupplementary(itemID: book.id, fileID: epub.ino)
            after = try await client.managedItemFiles(id: book.id)
            try require(after.first { $0.ino == epub.ino }?.isSupplementary == false && after.first { $0.ino == pdf.ino }?.isSupplementary == true, "EPUB restored primary")
            _ = try await client.embeddedMetadata(itemID: book.id)
            _ = try await client.probeMediaFile(itemID: book.id, fileID: tracks[0].ino)
        }
        try await step("collections-playlists-roundtrip") {
            let collection = try await client.createCollection(.init(libraryId: fixture.libraryID, name: "Compatibility \(runID)", books: [book.id]))
            var changed = try await client.addCollectionBooks(id: collection.id, itemIDs: [otherID])
            try require(Set(changed.books.map(\.id)) == Set(fixture.itemIDs), "collection additions")
            changed = try await client.removeCollectionBooks(id: collection.id, itemIDs: [otherID])
            try require(changed.books.map(\.id) == [book.id], "collection removal")
            let collections = try await client.collections(libraryID: fixture.libraryID, limit: 500)
            try require(collections.results.contains { $0.id == collection.id }, "collection list")
            let playlist = try await client.createPlaylist(.init(libraryId: fixture.libraryID, name: "Compatibility \(runID)", items: [.init(libraryItemId: book.id)]))
            var list = try await client.addPlaylistItems(id: playlist.id, items: [.init(libraryItemId: otherID)])
            try require(Set(list.items.map(\.libraryItemId)) == Set(fixture.itemIDs), "playlist additions")
            list = try await client.removePlaylistItems(id: playlist.id, items: [.init(libraryItemId: otherID)])
            try require(list.items.map(\.libraryItemId) == [book.id], "playlist removal")
            let playlists = try await client.playlists(libraryID: fixture.libraryID, limit: 500)
            try require(playlists.results.contains { $0.id == playlist.id }, "playlist list")
            try await client.deletePlaylist(id: playlist.id)
            try await client.deleteCollection(id: collection.id)
            let remaining = try await client.collections(libraryID: fixture.libraryID, limit: 500)
            try require(!remaining.results.contains { $0.id == collection.id }, "collection deletion")
        }
        try await step("bookmarks-audio-ebook-progress-history") {
            _ = try await client.createBookmark(itemID: book.id, time: 7, title: "Compatibility")
            _ = try await client.updateBookmark(itemID: book.id, time: 7, title: "Compatibility updated")
            let marks = try await client.bookmarks(itemID: book.id)
            try require(marks.contains { $0.time == 7 && $0.title == "Compatibility updated" }, "bookmark persisted")
            try await client.deleteBookmark(itemID: book.id, time: 7)
            let remaining = try await client.bookmarks(itemID: book.id)
            try require(!remaining.contains { $0.time == 7 }, "bookmark deletion")
            try await client.updateProgress(itemID: book.id, currentTime: 11, duration: book.media.duration, isFinished: false)
            let location = "epubcfi(/6/4!/4/2/1:0)"
            try await client.updateReadingProgress(itemID: book.id, location: location, progress: 0.25)
            let progress = try unwrap(try await client.progress(itemID: book.id), "shared progress")
            try require(abs(progress.currentTime - 11) < 0.01 && progress.ebookLocation == location && progress.ebookProgress == 0.25, "ebook patch preserves audio")
            let session = try await client.startPlayback(itemID: book.id)
            try await client.syncPlayback(sessionID: session.id, currentTime: 12, timeListening: 1)
            try await client.closePlayback(sessionID: session.id, currentTime: 13, timeListening: 1)
            let history = try await client.listeningHistory(itemID: book.id)
            let entry = try unwrap(history.sessions.first { $0.id == session.id }, "playback history")
            try require(abs(entry.timeListening - 2) < 0.01 && abs(entry.currentTime - 13) < 0.01, "incremental timeListened wire contract")
            let now = Date().timeIntervalSince1970 * 1000
            let local = LocalPlaybackSession(libraryItemId: book.id, mediaMetadata: book.media.metadata, chapters: book.media.chapters, displayTitle: book.title, duration: book.media.duration, currentTime: 14, startedAt: now - 3000, updatedAt: now, timeListening: 3, deviceInfo: .init(deviceId: "compat-" + runID))
            try await client.syncLocalSession(local)
            try await client.syncLocalSession(local)
            let retried = try await client.listeningHistory(itemID: book.id)
            let matching = retried.sessions.filter { $0.id == local.id }
            try require(matching.count == 1 && abs(matching[0].timeListening - 3) < 0.01, "local cumulative retry is idempotent")
            let shared = try unwrap(try await client.progress(itemID: book.id), "post playback progress")
            try require(shared.ebookLocation == location && shared.ebookProgress == 0.25, "audio session preserves ebook progress")
            _ = try await client.listeningStats()
            _ = try await client.adminPlaybackSessions(userID: fixture.userID)
            _ = try await client.userListeningHistory(id: fixture.userID)
        }
        try await step("rss-share-reader-device-roundtrip") {
            let profile = await client.profile
            let feed = try await client.openRSSFeed(entity: .item, id: book.id, options: .init(serverAddress: try PersonalPublicationLinks.origin(profile: profile), slug: "compat-" + runID))
            let listed = try await client.rssFeeds()
            try require(listed.contains { $0.id == feed.id && $0.entityId == book.id }, "RSS feed listed")
            let feedURL = try PersonalPublicationLinks.rss(feed: feed, profile: profile)
            try require(feedURL.host == "127.0.0.1" && feedURL.port == fixture.baseURL.port && feedURL.path.hasPrefix("/compat/feed/"), "RSS subpath URL")
            try await client.closeRSSFeed(id: feed.id)
            let closed = try await client.rssFeeds()
            try require(!closed.contains { $0.id == feed.id }, "RSS closure")
            let internalID = try unwrap((try await client.item(id: book.id)).media.id, "internal media identity")
            let share = try await client.createShare(.init(mediaItemId: internalID, mediaItemType: .book, slug: "compat-" + runID, expiresAt: (Date().timeIntervalSince1970 + 3600) * 1000))
            let details = try await client.itemPersonalDetails(id: book.id)
            try require(details.mediaItemShare?.id == share.id && share.mediaItemId == internalID, "share persisted by internal book ID")
            try await client.deleteShare(id: share.id)
            let deleted = try await client.itemPersonalDetails(id: book.id)
            try require(deleted.mediaItemShare == nil, "share deleted")
            let before = try await client.personalAccountDetails()
            let name = "Compat " + runID
            let device = EReaderDevice(name: name, email: "fixture@example.invalid", userID: fixture.userID)
            let devices = try await client.updateEReaderDevices(before.ereaderDevices + [device])
            try require(devices.contains { $0.name == name && $0.users == [fixture.userID] }, "personal device persisted")
            let restored = try await client.updateEReaderDevices(before.ereaderDevices)
            try require(!restored.contains { $0.name == name }, "personal device removed")
        }
        try await step("admin-user-library-settings-roundtrip") {
            var draft = UserDraft(username: "compat-" + runID, password: UUID().uuidString)
            draft.permissions = .restrictedCreationDefaults
            let user = try await client.createUser(draft)
            try require(user.permissions?.update == false && user.permissions?.delete == false && user.permissions?.accessAllLibraries == false, "restricted user permissions")
            let secondary = ABSClient(profile: .init(name: "Isolated password test", baseURL: fixture.baseURL, serverVersion: fixture.version), tokenStore: MemoryTokenStore())
            _ = try await secondary.status()
            _ = try await secondary.login(username: draft.username, password: draft.password)
            let newPassword = UUID().uuidString
            _ = try await secondary.changePassword(currentPassword: draft.password, newPassword: newPassword)
            _ = try await secondary.login(username: draft.username, password: newPassword)
            let reauthenticated = try await secondary.currentUser()
            try require(reauthenticated.id == user.id, "password rotation and reauthentication")
            try await secondary.logout()
            var update = UserUpdate(); update.isActive = false
            let disabled = try await client.updateUser(id: user.id, update: update)
            try require(disabled.isActive == false, "user deactivated")
            try await client.deleteUser(id: user.id)
            let users = try await client.adminUsers()
            try require(!users.contains { $0.id == user.id }, "user deleted")
            let folder = directory.appendingPathComponent("empty-library-" + runID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = try await client.createLibrary(.init(name: "Compatibility " + runID, folders: [.init(fullPath: folder.path)]))
            var libraryUpdate = LibraryUpdate(); libraryUpdate.name = "Compatibility updated " + runID
            var settings = LibrarySettingsUpdate(); settings.disableWatcher = true; libraryUpdate.settings = settings
            let changed = try await client.updateLibrary(id: created.id, update: libraryUpdate)
            try require(changed.name == libraryUpdate.name && changed.settings?.disableWatcher == true, "library update")
            _ = try await client.deleteLibrary(id: created.id)
            let libraries = try await client.libraries()
            try require(!libraries.contains { $0.id == created.id }, "library deleted")
            let previous = try await client.serverSettings()
            var settingsUpdate = ServerSettingsUpdate(); settingsUpdate.scannerParseSubtitle = !(previous.scannerParseSubtitle ?? false)
            let saved = try await client.updateServerSettings(settingsUpdate)
            try require(saved.scannerParseSubtitle == settingsUpdate.scannerParseSubtitle, "server setting persisted")
            var restore = ServerSettingsUpdate(); restore.scannerParseSubtitle = previous.scannerParseSubtitle ?? false
            _ = try await client.updateServerSettings(restore)
            _ = try await client.notificationConfiguration()
            _ = try await client.authenticationSettings()
            _ = try await client.smtpSettings()
            _ = try await client.serverTasks()
            _ = try await client.serverStorageStatistics()
            _ = try await client.metadataProviders()
        }
        if ServerVersion(fixture.version) >= ServerVersion("2.37.1") {
            try await step("api-keys-authentication-sessions") {
                let key = try await client.createAPIKey(.init(name: "Compatibility " + runID, userId: fixture.userID, expiresIn: 3600))
                let list = try await client.apiKeys()
                try require(list.contains { $0.id == key.id }, "API key listed")
                let disabled = try await client.updateAPIKey(id: key.id, update: .init(isActive: false))
                try require(!disabled.isActive, "API key disabled")
                try await client.deleteAPIKey(id: key.id)
                let sessions = try await client.authenticationSessions()
                try require(sessions.sessions.contains(where: \.current), "current authentication session")
            }
        } else { print("GATED \(fixture.version) API-keys/authentication-sessions require 2.37.1") }
        try await step("backup-create-download-delete") {
            let previous = try await client.backups()
            let created = try await client.createBackup()
            let backup = try unwrap(created.backups.first { value in !previous.backups.contains { $0.id == value.id } }, "new backup listed")
            let destination = directory.appendingPathComponent("smoke-" + runID + ".audiobookshelf")
            defer { try? FileManager.default.removeItem(at: destination) }
            try await client.downloadBackup(id: backup.id, destination: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            try require((values.fileSize ?? 0) > 100, "backup bytes downloaded")
            let deleted = try await client.deleteBackup(id: backup.id)
            try require(!deleted.backups.contains { $0.id == backup.id }, "backup deleted")
        }
        try await step("upload-progress-and-sidecar-cleanup") {
            let library = try await client.managedLibrary(id: fixture.libraryID)
            let folderID = try unwrap(library.folders.first?.id, "upload folder ID")
            let source = directory.deletingLastPathComponent().appendingPathComponent("synthetic-source/sample.mp3")
            let evidence = UploadEvidence()
            let title = "Compat Upload " + runID
            try await client.uploadLibraryFiles([.init(localURL: source, filename: "fixture.mp3", mimeType: "audio/mpeg")], details: .init(libraryID: fixture.libraryID, folderID: folderID, title: title, author: "Compat Upload Author"), progress: evidence.record)
            try require(evidence.completedUpload(), "actual multipart preparation and transfer byte progress")
            let libraryFolder = try unwrap(library.folders.first?.fullPath, "upload library folder")
            let expected = URL(fileURLWithPath: libraryFolder).appendingPathComponent("Compat Upload Author").appendingPathComponent(title).appendingPathComponent("fixture.mp3")
            defer { try? FileManager.default.removeItem(at: expected.deletingLastPathComponent()) }
            try require(FileManager.default.fileExists(atPath: expected.path), "uploaded original on isolated disk")
            let previous = try await client.serverSettings()
            var enabled = ServerSettingsUpdate(); enabled.storeMetadataWithItem = true
            var restore = ServerSettingsUpdate(); restore.storeMetadataWithItem = previous.storeMetadataWithItem ?? false
            _ = try await client.updateServerSettings(enabled)
            do {
                var metadata = MetadataUpdate(); metadata.subtitle = "Sidecar " + runID
                _ = try await client.updateItemMedia(id: book.id, update: .init(metadata: metadata))
                // These releases do not always mark the in-place libraryFiles JSON
                // append dirty when generating a new sidecar. Scan the actual file.
                _ = try await client.scanItem(id: book.id)
                let files = try await client.managedItemFiles(id: book.id)
                let json = try unwrap(files.first { $0.metadata.filename == "metadata.json" }, "server generated metadata.json")
                let jsonPath = try unwrap(json.metadata.path, "metadata sidecar path")
                let jsonURL = URL(fileURLWithPath: jsonPath).resolvingSymlinksInPath()
                try require(jsonURL.path.hasPrefix(directory.appendingPathComponent("media").resolvingSymlinksInPath().path + "/"), "isolated sidecar directory")
                let folder = jsonURL.deletingLastPathComponent()
                let absURL = folder.appendingPathComponent("metadata.abs")
                // Legacy .abs is no longer parsed by these releases. Seed its real indexed
                // filename to exercise the explicit legacy cleanup route with actual bytes.
                try Data(";ABMETADATA\ntitle=Audilse synthetic cleanup fixture\n".utf8).write(to: absURL)
                let opfURL = folder.appendingPathComponent("metadata.opf")
                try Data("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Compat Sample</dc:title><dc:creator>Compat Author</dc:creator></metadata></package>".utf8).write(to: opfURL)
                _ = try await client.scanItem(id: book.id)
                let scanned = try await client.managedItemFiles(id: book.id)
                try require(scanned.contains { $0.metadata.filename == "metadata.abs" } && scanned.contains { $0.metadata.filename == "metadata.json" }, "sidecars indexed before cleanup")
                let absResult = try await client.removeLibraryMetadataFiles(id: fixture.libraryID, kind: .abs)
                try require(absResult.found > 0 && absResult.removed == absResult.found && !FileManager.default.fileExists(atPath: absURL.path), "legacy ABS sidecar actually deleted")
                let jsonResult = try await client.removeLibraryMetadataFiles(id: fixture.libraryID, kind: .json)
                try require(jsonResult.found > 0 && jsonResult.removed == jsonResult.found && !FileManager.default.fileExists(atPath: jsonURL.path), "JSON sidecar actually deleted")
                _ = try await client.updateServerSettings(restore)
                let opf = try unwrap(scanned.first { $0.metadata.filename.lowercased().hasSuffix(".opf") }, "indexed OPF fixture")
                try await client.deleteMediaFile(itemID: book.id, fileID: opf.ino)
                let remaining = try await client.managedItemFiles(id: book.id)
                try require(!remaining.contains { $0.ino == opf.ino } && !FileManager.default.fileExists(atPath: opfURL.path), "OPF file actually removed")
            } catch {
                _ = try? await client.updateServerSettings(restore)
                throw error
            }
        }
        try await step("logout") { try await client.logout() }
        print("COMPATIBILITY_OK \(fixture.version) groups=\(checks)")
    }
    private func ebookBook() async throws -> LibraryItem {
        for id in fixture.itemIDs {
            let item = try await client.item(id: id)
            let files = try await client.managedItemFiles(id: id)
            if files.filter(\.isEBook).count == 2 { return item }
        }
        throw CheckFailure(reason: "EPUB/PDF fixture missing")
    }
}
private func unwrap<T>(_ value: T?, _ reason: String) throws -> T {
    guard let value else { throw CheckFailure(reason: reason) }; return value
}
private func safeError(_ error: Error) -> String {
    if let failure = error as? CheckFailure { return "invariant: " + failure.reason }
    if case ABSError.http(let status, _) = error { return "HTTP \(status)" }
    if let error = error as? DecodingError {
        let path: [any CodingKey]
        switch error { case .keyNotFound(let key, let context): path = context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
        @unknown default: path = [] }
        return "decode field " + path.map(\.stringValue).joined(separator: ".")
    }
    return String(reflecting: type(of: error))
}
@main private struct CompatibilitySmoke {
    @MainActor static func main() async {
        let all = ["2.26.0", "2.36.1", "2.37.1"]
        let selected = CommandLine.arguments.count == 2 ? [CommandLine.arguments[1]] : all
        guard selected.allSatisfy(all.contains) else { print("Use no arguments or one fixed release version"); exit(2) }
        let base = URL(fileURLWithPath: "/private/tmp/shelf-compat-servers", isDirectory: true)
        var failures = 0
        for version in selected {
            var run: CompatibilityRun?
            do {
                let directory = base.appendingPathComponent("v" + version, isDirectory: true)
                let path = directory.appendingPathComponent("auth.json")
                let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
                try require(mode?.intValue == 0o600, "private credential file permissions")
                let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: path))
                try require(fixture.version == version, "manifest version")
                run = try CompatibilityRun(fixture: fixture, directory: directory)
                try await run!.run()
            } catch {
                failures += 1
                print("FAIL \(version) \(run?.currentStep ?? "fixture-guard"): \(safeError(error))")
            }
        }
        print("COMPATIBILITY_SUMMARY versions=\(selected.count) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
