// Opt-in live acceptance test. Credentials enter through stdin and remain in
// memory. Every local file belongs to a new temporary account partition.
import Foundation
import AppKit
import AVFoundation
import Darwin
import AudilseCore
import AudilsePlayback

private struct LiveCredentials: Codable, Sendable {
    var address: String
    var username: String
    var password: String
}

private struct LiveManifest: Codable, Sendable {
    var profile: ServerProfile
    var partition: AccountPartition
    var item: AudilseCore.LibraryItem
    var baseline: MediaProgress
    var originalBytes: Int64
    var downloadProcessID: Int32?
}

private struct OfflineResult: Codable, Sendable {
    var processID: Int32
    var sessionID: String
    var initialPosition: Double
    var finalPosition: Double
    var timeListening: Double
}

private struct HistoryEnvelope: Decodable, Sendable {
    var sessions: [HistorySession]
}

private struct HistorySession: Decodable, Sendable {
    var id: String
    var currentTime: Double
    var timeListening: Double
}

private struct LiveFailure: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

private final class LiveRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let endpoint: ServerEndpoint
    init(endpoint: ServerEndpoint) { self.endpoint = endpoint }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? endpoint.url(path: url.absoluteString)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

// Extra live-test protection: recheck the captured progress immediately before
// each mutation. ABS has no conditional progress PATCH; the production
// coordinator's conflict policy remains the primary persisted conflict check.
private actor GuardedLiveRemote: OfflineSyncRemote {
    let remote: ABSOfflineSyncRemote
    let itemID: String
    var expected: SyncProgressSnapshot?

    init(client: ABSClient, itemID: String, baseline: MediaProgress) {
        remote = ABSOfflineSyncRemote(client: client)
        self.itemID = itemID
        expected = .init(itemID: itemID, currentTime: baseline.currentTime, duration: baseline.duration,
                         isFinished: baseline.isFinished, updatedAt: baseline.lastUpdate ?? 0)
    }
    func progress(itemID: String, episodeID: String?) async throws -> SyncProgressSnapshot? {
        try await remote.progress(itemID: itemID, episodeID: episodeID)
    }
    private func checkBeforeWriting() async throws {
        let current = try await remote.progress(itemID: itemID, episodeID: nil)
        if let current, let expected {
            guard current.updatedAt == expected.updatedAt,
                  abs(current.currentTime - expected.currentTime) < 0.01,
                  current.isFinished == expected.isFinished else {
                throw OfflineSyncError.progressChangedDuringResolution
            }
        } else if current != nil || (expected?.updatedAt ?? 0) != 0 || (expected?.currentTime ?? 0) != 0 {
            throw OfflineSyncError.progressChangedDuringResolution
        }
    }
    func upload(_ session: OfflinePlaybackSession) async throws {
        try await checkBeforeWriting()
        try await remote.upload(session)
        expected = try await remote.progress(itemID: itemID, episodeID: nil)
    }
    func setAudioPosition(itemID: String, episodeID: String?, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        try await checkBeforeWriting()
        try await remote.setAudioPosition(itemID: itemID, episodeID: episodeID, currentTime: currentTime, duration: duration, isFinished: isFinished)
        expected = try await remote.progress(itemID: itemID, episodeID: episodeID)
    }
}

@main private enum ShelfOfflineLiveSmoke {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                guard arguments.count >= 2 else {
                    throw LiveFailure(message: "Usage: OfflineLiveSmoke run|download|offline|sync WORK_DIRECTORY [--pause-after-selection]")
                }
                let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
                switch arguments[0] {
                case "run": try await run(root: root, pauseAfterSelection: arguments.contains("--pause-after-selection"))
                case "resume-run": try await completePreparedRun(root: root, credentials: readInteractiveCredentials())
                case "download": try await download(root: root, credentials: readPipedCredentials())
                case "offline": try await offline(root: root)
                case "sync": try await synchronize(root: root, credentials: readPipedCredentials())
                case "headers": try await diagnoseHeaders(root: root, credentials: readInteractiveCredentials())
                default: throw LiveFailure(message: "Unknown acceptance-test phase")
                }
                exit(0)
            } catch {
                // Never print URLSession error userInfo, URLs, response bodies or
                // generic errors that could contain an authentication resource.
                if let error = error as? LiveFailure { log("FAIL: " + error.message) }
                else if let error = error as? OfflineSyncError { log("STOP: " + error.localizedDescription) }
                else if let error = error as? ABSError {
                    switch error {
                    case .http(let status, _): log("FAIL: ABS HTTP status \(status)")
                    default: log("FAIL: ABS request or authentication error")
                    }
                } else { log("FAIL: \(String(reflecting: type(of: error)))") }
                exit(1)
            }
        }
        application.run()
    }

    @MainActor private static func run(root: URL, pauseAfterSelection: Bool) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path), "Use a fresh work directory for each live acceptance test")
        let credentials = try readInteractiveCredentials()
        let provisional = ServerProfile(name: "Offline live acceptance", baseURL: try validatedAddress(credentials.address))
        let client = try await authenticate(credentials, profile: provisional)
        let user = try await client.currentUser()
        try require(user.permissions.download, "This account does not allow original downloads")
        let profile = await client.profile
        let partition = AccountPartition(serverID: profile.id, userID: user.id)
        let libraries = try await client.libraries()
        var candidates: [(item: AudilseCore.LibraryItem, progress: MediaProgress, bytes: Int64)] = []
        for library in libraries {
            var page = 0
            while true {
                let response = try await client.libraryItems(libraryID: library.id, page: page, limit: 500)
                for item in response.results where item.mediaType == "book" && !item.title.contains("凡人修仙传") {
                    let full = try await client.item(id: item.id)
                    let progress = try await client.progress(itemID: full.id) ?? .init(libraryItemId: full.id, duration: full.media.duration, lastUpdate: 0)
                    let files = full.media.audioFiles
                    guard !progress.isFinished, full.media.duration > progress.currentTime + 30,
                          !files.isEmpty, files.allSatisfy({ !$0.exclude && !$0.isInvalid && ($0.metadata.size ?? 0) > 0 && ($0.duration ?? 0) > 0 }) else { continue }
                    candidates.append((full, progress, files.reduce(Int64(0)) { $0 + ($1.metadata.size ?? 0) }))
                }
                if (page + 1) * 500 >= response.total { break }
                page += 1
            }
        }
        var selected: (item: AudilseCore.LibraryItem, progress: MediaProgress, bytes: Int64)?
        for candidate in candidates.sorted(by: { $0.bytes < $1.bytes }) {
            if try await originalsMatchMetadata(item: candidate.item, client: client) { selected = candidate; break }
        }
        guard let selected else { throw LiveFailure(message: "No unfinished candidate has original HTTP lengths matching all scanned file sizes; no download or progress write was attempted") }
        let manifest = LiveManifest(profile: profile, partition: partition, item: selected.item, baseline: selected.progress, originalBytes: selected.bytes)
        try save(manifest, to: root.appendingPathComponent("manifest.json"))
        log("SELECTED: \(selected.item.title); files=\(selected.item.media.audioFiles.count); originalBytes=\(selected.bytes); MiB=\(rounded(Double(selected.bytes) / 1_048_576)); initialPosition=\(rounded(selected.progress.currentTime)); eligibleBooks=\(candidates.count)")
        log("ISOLATION: random profile/device UUID; temporary SQLite and originals; main application credentials and playback are untouched")
        try await client.logout()
        if pauseAfterSelection {
            log("SELECTION_READY: send continue on stdin to start the already-authorized test")
            try require(readLine() == "continue", "Test stopped before downloading")
        }
        try await completePreparedRun(root: root, credentials: credentials)
    }

    @MainActor private static func completePreparedRun(root: URL, credentials: LiveCredentials) async throws {
        let manifest = try load(LiveManifest.self, from: root.appendingPathComponent("manifest.json"))
        try require(manifest.partition.serverID == manifest.profile.id && manifest.partition.userID == manifest.profile.userID,
                    "The acceptance manifest changed account partitions")
        try await phase("download", root: root, credentials: credentials, denyNetwork: false)
        try await phase("offline", root: root, credentials: nil, denyNetwork: true)
        try await phase("sync", root: root, credentials: credentials, denyNetwork: false)
        log("PASS: real originals → fresh process with network denied → offline resume → verified history/progress sync")
    }

    @MainActor private static func download(root: URL, credentials: LiveCredentials) async throws {
        var manifest = try load(LiveManifest.self, from: root.appendingPathComponent("manifest.json"))
        let client = try await authenticate(credentials, profile: manifest.profile)
        let database = try ShelfDatabase(path: root.appendingPathComponent("ShelfSmoke.sqlite"))
        let manager = DownloadManager(database: database, rootDirectory: root.appendingPathComponent("Downloads", isDirectory: true))
        let files = manifest.item.media.audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var offset = 0.0
        var tracks: [DownloadTrack] = []
        for (index, file) in files.enumerated() {
            let matching = manifest.item.media.tracks.first { $0.index == (file.index ?? index) }
            let duration = file.duration ?? matching?.duration ?? 0
            let start = matching?.startOffset ?? offset
            let url = try await client.resourceURL(path: "api/items/\(ServerEndpoint.component(manifest.item.id))/file/\(ServerEndpoint.component(file.ino))")
            tracks.append(.init(ino: file.ino, title: matching?.title ?? file.metadata.filename, filename: file.metadata.filename, contentURL: url, duration: duration, startOffset: start, expectedBytes: file.metadata.size))
            offset = start + duration
        }
        try await manager.start(partition: manifest.partition, itemID: manifest.item.id, title: manifest.item.title, tracks: tracks) { url in
            try await client.authorizedRequest(path: url.absoluteString)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1_800
        var lastLog = 0.0
        while manager.records.first(where: { $0.itemID == manifest.item.id })?.state != .ready {
            guard let record = manager.records.first(where: { $0.itemID == manifest.item.id }) else { throw LiveFailure(message: "The download record disappeared") }
            try require(record.state != .failed && manager.storageError == nil, "Original download failed; inspect its account-scoped record locally")
            let now = ProcessInfo.processInfo.systemUptime
            try require(now < deadline, "Original download exceeded the 30-minute acceptance-test timeout")
            if now - lastLog >= 10 { log("DOWNLOAD: bytes=\(record.bytesWritten)/\(manifest.originalBytes)"); lastLog = now }
            try await Task.sleep(for: .milliseconds(250))
        }
        let ready = try await manager.readyTracks(partition: manifest.partition, itemID: manifest.item.id)
        let record = manager.records.first { $0.itemID == manifest.item.id }!
        try require(ready.count == files.count && record.bytesWritten == manifest.originalBytes, "The complete original file set did not match its advertised lengths")
        manifest.baseline = try await client.progress(itemID: manifest.item.id) ?? .init(libraryItemId: manifest.item.id, duration: manifest.item.media.duration, lastUpdate: 0)
        try require(!manifest.baseline.isFinished && manifest.baseline.currentTime + 20 < manifest.item.media.duration, "Another device finished this book before offline playback; no test progress was written")
        manifest.downloadProcessID = getpid()
        try await database.save(manifest.item, key: "item.\(manifest.item.id)", partition: manifest.partition)
        try await database.saveResume(manifest.baseline, partition: manifest.partition)
        try save(manifest, to: root.appendingPathComponent("manifest.json"))
        try await client.logout()
        log("PASS DOWNLOAD: originalFiles=\(ready.count); validatedBytes=\(record.bytesWritten); serverResume=\(rounded(manifest.baseline.currentTime)); pid=\(getpid())")
    }

    private static func diagnoseHeaders(root: URL, credentials: LiveCredentials) async throws {
        let manifest = try load(LiveManifest.self, from: root.appendingPathComponent("manifest.json"))
        let client = try await authenticate(credentials, profile: manifest.profile)
        let fresh = try await client.item(id: manifest.item.id)
        guard let file = fresh.media.audioFiles.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }).first else { throw LiveFailure(message: "No original file exists for header diagnostics") }
        let libraryFile = fresh.libraryFiles.first { $0.ino == file.ino }
        log("HTTP_DIAG metadata: audioBytes=\(file.metadata.size ?? -1); libraryBytes=\(libraryFile?.metadata.size ?? -1)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: LiveRedirectDelegate(endpoint: try ServerEndpoint(baseURL: manifest.profile.baseURL)), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for suffix in ["", "/download"] {
            for method in ["HEAD", "GET"] {
                var request = try await client.authorizedRequest(path: "api/items/\(ServerEndpoint.component(fresh.id))/file/\(ServerEndpoint.component(file.ino))\(suffix)", method: method)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
                let (_, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw LiveFailure(message: "The header diagnostic returned a non-HTTP response") }
                let length = response.value(forHTTPHeaderField: "Content-Length") ?? "none"
                let range = response.value(forHTTPHeaderField: "Content-Range") ?? "none"
                let encoding = response.value(forHTTPHeaderField: "Content-Encoding") ?? "none"
                log("HTTP_DIAG route=\(suffix.isEmpty ? "file" : "download"); method=\(method); status=\(response.statusCode); length=\(length); expectedContentLength=\(response.expectedContentLength); range=\(range); encoding=\(encoding); mime=\(response.mimeType ?? "none")")
            }
        }
        try await client.logout()
    }

    private static func originalsMatchMetadata(item: AudilseCore.LibraryItem, client: ABSClient) async throws -> Bool {
        let profile = await client.profile
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: LiveRedirectDelegate(endpoint: try ServerEndpoint(baseURL: profile.baseURL)), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let files = item.media.audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        for (index, file) in files.enumerated() {
            let path = "api/items/\(ServerEndpoint.component(item.id))/file/\(ServerEndpoint.component(file.ino))"
            var head = try await client.authorizedRequest(path: path, method: "HEAD")
            head.cachePolicy = .reloadIgnoringLocalCacheData
            head.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (_, headResponse) = try await session.bytes(for: head)
            var range = try await client.authorizedRequest(path: path)
            range.cachePolicy = .reloadIgnoringLocalCacheData
            range.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            range.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let (rangeBytes, rangeResponse) = try await session.bytes(for: range)
            var rangeIterator = rangeBytes.makeAsyncIterator()
            let firstByte = try await rangeIterator.next()
            let secondByte = try await rangeIterator.next()
            guard let headResponse = headResponse as? HTTPURLResponse, let rangeResponse = rangeResponse as? HTTPURLResponse else { throw LiveFailure(message: "Original preflight returned a non-HTTP response") }
            let expected = file.metadata.size ?? -1
            let contentRange = rangeResponse.value(forHTTPHeaderField: "Content-Range") ?? "none"
            let headValidator = headResponse.value(forHTTPHeaderField: "ETag") ?? headResponse.value(forHTTPHeaderField: "Last-Modified")
            let rangeValidator = rangeResponse.value(forHTTPHeaderField: "ETag") ?? rangeResponse.value(forHTTPHeaderField: "Last-Modified")
            let matches = headResponse.statusCode == 200 && rangeResponse.statusCode == 206 &&
                headResponse.expectedContentLength == expected && rangeResponse.expectedContentLength == 1 &&
                firstByte != nil && secondByte == nil &&
                contentRange == "bytes 0-0/\(expected)" && headValidator == rangeValidator &&
                headResponse.value(forHTTPHeaderField: "Content-Encoding") == nil &&
                rangeResponse.value(forHTTPHeaderField: "Content-Encoding") == nil
            if !matches {
                log("PREFLIGHT SKIP: \(item.title); fileIndex=\(index); scannedBytes=\(expected); headStatus=\(headResponse.statusCode); headBytes=\(headResponse.expectedContentLength); rangeStatus=\(rangeResponse.statusCode); range=\(contentRange)")
                return false
            }
        }
        log("PREFLIGHT PASS: \(item.title); allFiles=\(files.count); HEAD and Range match scanned original lengths")
        return true
    }

    @MainActor private static func offline(root: URL) async throws {
        try proveNetworkDenied()
        let manifest = try load(LiveManifest.self, from: root.appendingPathComponent("manifest.json"))
        try require(manifest.downloadProcessID != getpid(), "The offline phase did not restart in a new process")
        let database = try ShelfDatabase(path: root.appendingPathComponent("ShelfSmoke.sqlite"))
        let manager = DownloadManager(database: database, rootDirectory: root.appendingPathComponent("Downloads", isDirectory: true))
        try await manager.restore(partition: manifest.partition)
        let original = try await manager.readyTracks(partition: manifest.partition, itemID: manifest.item.id)
        try require(original.allSatisfy { $0.url.isFileURL }, "An offline track referenced the network")
        guard let item = try await database.load(AudilseCore.LibraryItem.self, key: "item.\(manifest.item.id)", partition: manifest.partition),
              let resume = try await database.loadResume(itemID: manifest.item.id, partition: manifest.partition) else { throw LiveFailure(message: "Restart lost the cached book or its resume checkpoint") }
        try require(abs(resume.currentTime - manifest.baseline.currentTime) < 0.01, "The restored checkpoint reset or changed the server position")
        let controller = PlaybackController(persist: { snapshot in
            var local = snapshot
            local.deviceInfo = .init(deviceId: manifest.profile.id.uuidString, clientName: "Audilse Offline Acceptance")
            try await database.enqueue(local, partition: manifest.partition, baseline: manifest.baseline)
        }, checkpoint: { try await database.saveResume($0, partition: manifest.partition) })
        do {
            let media = PlaybackMedia(itemID: item.id, title: item.title, author: item.authorName, duration: item.media.duration,
                                      chapters: item.media.chapters.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end) })
            let tracks = original.enumerated().map { index, track in PlaybackTrack(index: index, title: track.title, url: track.url, duration: track.duration, startOffset: track.startOffset, isLocal: true) }
            await controller.playOffline(media: media, tracks: tracks, initialPosition: resume.currentTime)
            try await eventually("Downloaded originals did not play in the network-denied process", seconds: 20) {
                controller.error != nil || (controller.isPlaying && controller.position >= resume.currentTime + 0.1)
            }
            try require(controller.error == nil, "The local audio engine reported a playback error")
            try await eventually("Offline playback did not accumulate three seconds of real listening", seconds: 20) {
                controller.error != nil || (controller.timeListening >= 3 && controller.position >= resume.currentTime + 2.5)
            }
            try require(controller.error == nil, "The local audio engine failed during offline listening")
            controller.pause()
            await controller.stop()
            await controller.shutdown()
            let pending = try await database.pendingSessions(partition: manifest.partition)
            guard let saved = pending.first else { throw LiveFailure(message: "Offline listening history was not durably journaled") }
            let result = OfflineResult(processID: getpid(), sessionID: saved.id, initialPosition: resume.currentTime, finalPosition: saved.currentTime, timeListening: saved.timeListening)
            try require(saved.currentTime > resume.currentTime + 2 && saved.timeListening >= 3, "The durable snapshot lost position or listening time")
            try require(saved.serverProgressUpdatedAt == manifest.baseline.lastUpdate && saved.serverCurrentTime == manifest.baseline.currentTime, "The original server baseline was replaced")
            try save(result, to: root.appendingPathComponent("offline-result.json"))
            log("PASS OFFLINE: restoredFiles=\(original.count); initial=\(rounded(resume.currentTime)); final=\(rounded(saved.currentTime)); listened=\(rounded(saved.timeListening)); pending=\(pending.count); pid=\(getpid())")
        } catch { await controller.shutdown(); throw error }
    }

    @MainActor private static func synchronize(root: URL, credentials: LiveCredentials) async throws {
        let manifest = try load(LiveManifest.self, from: root.appendingPathComponent("manifest.json"))
        let result = try load(OfflineResult.self, from: root.appendingPathComponent("offline-result.json"))
        try require(result.processID != getpid() && manifest.downloadProcessID != getpid(), "Sync must run after both earlier processes have exited")
        let client = try await authenticate(credentials, profile: manifest.profile)
        let database = try ShelfDatabase(path: root.appendingPathComponent("ShelfSmoke.sqlite"))
        let pending = try await database.pendingSessions(partition: manifest.partition)
        try require(pending.count == 1 && pending[0].id == result.sessionID, "The restarted sync process did not recover the original cumulative session")
        let remote = GuardedLiveRemote(client: client, itemID: manifest.item.id, baseline: manifest.baseline)
        let coordinator = SyncCoordinator(database: database)
        let report = try await coordinator.synchronize(partition: manifest.partition, remote: remote)
        guard report.conflicts.isEmpty else {
            log("STOP CONFLICT: another device changed this book; pending history retained; no automatic position choice")
            try await client.logout()
            throw LiveFailure(message: "Live acceptance stopped for an actual progress conflict")
        }
        try require(report.uploaded == 1, "The cumulative offline session was not uploaded exactly once")
        guard let progress = try await client.progress(itemID: manifest.item.id) else { throw LiveFailure(message: "No server progress exists after synchronization") }
        try require(abs(progress.currentTime - result.finalPosition) <= 1 && progress.currentTime >= manifest.baseline.currentTime && !progress.isFinished, "The server position did not match the offline checkpoint or moved backward")
        let history: HistoryEnvelope = try await client.getJSON(path: "api/me/item/listening-sessions/\(ServerEndpoint.component(manifest.item.id))?itemsPerPage=100&page=0")
        let matches = history.sessions.filter { $0.id == result.sessionID }
        try require(matches.count == 1 && abs(matches[0].timeListening - result.timeListening) < 0.1 && abs(matches[0].currentTime - result.finalPosition) <= 1, "Server history did not retain the session's cumulative listening time and position")
        let retry = try await coordinator.synchronize(partition: manifest.partition, remote: remote)
        let remaining = try await database.pendingSessions(partition: manifest.partition)
        try require(retry.uploaded == 0 && remaining.isEmpty, "A repeated synchronization resent listening time or left an acknowledged journal row")
        log("PASS SYNC: uploaded=\(report.uploaded); historyMatches=\(matches.count); historyListening=\(rounded(matches[0].timeListening)); remotePosition=\(rounded(progress.currentTime)); retryUploaded=\(retry.uploaded); pending=\(remaining.count); pid=\(getpid())")
        try await client.logout()
    }

    @MainActor private static func phase(_ name: String, root: URL, credentials: LiveCredentials?, denyNetwork: Bool) async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let process = Process()
        if denyNetwork {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            var arguments = ["-p", "(version 1)(allow default)(deny network*)"]
            // The system sandbox launcher strips DYLD_* variables. Restore only
            // the local framework search path after launching the sandbox; its
            // network restriction remains inherited by env and the test process.
            if let frameworks = ProcessInfo.processInfo.environment["DYLD_FRAMEWORK_PATH"], !frameworks.isEmpty {
                arguments += ["/usr/bin/env", "DYLD_FRAMEWORK_PATH=" + frameworks]
            }
            process.arguments = arguments + [executable.path, name, root.path]
        } else {
            process.executableURL = executable; process.arguments = [name, root.path]
        }
        process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
        let pipe = Pipe(); process.standardInput = pipe
        try process.run()
        if let credentials { try pipe.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(credentials) + Data([10])) }
        try pipe.fileHandleForWriting.close()
        let status = await Task.detached { process.waitUntilExit(); return process.terminationStatus }.value
        try require(status == 0, "The \(name) process exited with status \(status); work directory retained for inspection")
    }

    private static func authenticate(_ credentials: LiveCredentials, profile: ServerProfile) async throws -> ABSClient {
        let address = try validatedAddress(credentials.address).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try require(address == profile.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "The credential server differs from the selected manifest server")
        let client = ABSClient(profile: profile, tokenStore: MemoryTokenStore())
        _ = try await client.status()
        let response = try await client.login(username: credentials.username, password: credentials.password)
        if let expected = profile.userID { try require(response.user.id == expected, "The test account changed between phases") }
        return client
    }

    private static func readInteractiveCredentials() throws -> LiveCredentials {
        var previous = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &previous) == 0
        if hasTerminal { var hidden = previous; hidden.c_lflag &= ~tcflag_t(ECHO); _ = tcsetattr(STDIN_FILENO, TCSANOW, &hidden) }
        defer { if hasTerminal { var restore = previous; _ = tcsetattr(STDIN_FILENO, TCSANOW, &restore) } }
        log("AUTH_STDIN_READY: send baseURL, username and password as three lines; terminal echo is disabled")
        guard let address = readLine(), let username = readLine(), let password = readLine(), !username.isEmpty, !password.isEmpty else { throw LiveFailure(message: "Missing interactive authentication input") }
        return .init(address: address, username: username, password: password)
    }
    private static func readPipedCredentials() throws -> LiveCredentials {
        guard let input = readLine(), let data = input.data(using: .utf8) else { throw LiveFailure(message: "Missing in-memory phase authentication") }
        return try JSONDecoder().decode(LiveCredentials.self, from: data)
    }
    private static func validatedAddress(_ value: String) throws -> URL {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw LiveFailure(message: "Invalid server address") }
        return url
    }
    private static func proveNetworkDenied() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        if descriptor < 0 { try require(errno == EPERM || errno == EACCES, "Socket creation failed without proving network sandboxing"); return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian; address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let failure = errno
        try require(status == -1 && (failure == EPERM || failure == EACCES), "The offline process was not denied network access by the OS sandbox")
        log("PASS ISOLATION: operating-system sandbox denied the test process's socket (EPERM/EACCES); system network unchanged")
    }
    @MainActor private static func eventually(_ message: String, seconds: Double, condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() { try require(ProcessInfo.processInfo.systemUptime < deadline, message); try await Task.sleep(for: .milliseconds(100)) }
    }
    private static func save<T: Encodable>(_ value: T, to url: URL) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    private static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw LiveFailure(message: message) } }
    private static func rounded(_ value: Double) -> String { String(format: "%.3f", value) }
    private static func log(_ value: String) { try? FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
}
