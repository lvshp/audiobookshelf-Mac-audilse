import Foundation

/// Anonymous share context. No account profile, TokenStore, global cookie jar,
/// account progress store, or account download manager participates in this actor.
public actor PublicShareClient {
    public nonisolated let location: PublicShareLocation
    private let store: any PublicShareStateStore
    private var generation = UUID()
    private var snapshot: PublicShareSnapshot?
    private var stored = StoredShareState(cookie: nil, progress: nil)
    private var storedBytes: Data?
    private var loaded = false
    private var closing = false
    private var closed = false
    private var initialTimeApplied = false
    private var opening: Task<PublicShareSnapshot, Error>?
    private var saveTail: Task<Void, Error>?
    private var progressTail: Task<PublicShareCheckpoint, Error>?
    private var transfers: [UUID: ShareHTTPTransfer] = [:]

    public init(location: PublicShareLocation, stateStore: any PublicShareStateStore = LocalPublicShareStateStore.shared) {
        self.location = location; store = stateStore
    }
    public func open() async throws -> PublicShareSnapshot {
        try Task.checkCancellation()
        guard !closing, !closed else { throw PublicShareError.closed }
        if let snapshot { try require(snapshot.handle); return snapshot }
        if let opening { return try await awaitOpening(opening) }
        let epoch = generation
        let task = Task { try await self.performOpen(epoch: epoch) }
        opening = task
        defer { if generation == epoch { opening = nil } }
        return try await awaitOpening(task)
    }
    /// Explicit bounded recovery after a server restart/session loss. Old handles
    /// are invalidated; callers must replace their snapshot and loader context.
    public func reopen() async throws -> PublicShareSnapshot {
        guard !closing else { throw PublicShareError.closed }
        closing = true; opening?.cancel(); transfers.values.forEach { $0.cancel() }
        _ = await opening?.result; _ = await progressTail?.result; _ = await saveTail?.result
        generation = UUID(); snapshot = nil; opening = nil; progressTail = nil; saveTail = nil
        loaded = false; storedBytes = nil; stored = .init(cookie: nil, progress: nil)
        closing = false; closed = false
        return try await open()
    }
    public func readTrackRange(index: Int, offset: Int64, length: Int, handle: PublicShareHandle) async throws -> PublicShareTrackRange {
        try require(handle)
        guard offset >= 0, length > 0, length <= 1_048_576, offset <= Int64.max - Int64(length),
              snapshot?.tracks.contains(where: { $0.index == index }) == true else { throw PublicShareError.invalidRange }
        var request = try request(suffix: "/track/\(index)")
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")
        let response = try await perform(request, policy: .range(offset: offset, length: length), epoch: handle.generation)
        try require(handle); try status(response, expected: 206)
        guard let actual = response.actualRange, let total = response.totalLength else { throw PublicShareError.invalidResponse }
        return .init(data: response.data, totalLength: total, contentType: response.header("content-type"), range: actual)
    }
    public func cover(handle: PublicShareHandle) async throws -> Data? {
        try require(handle)
        guard snapshot?.hasCover == true else { return nil }
        let response = try await perform(request(suffix: "/cover"), policy: .bounded(8 * 1_048_576), epoch: handle.generation)
        try require(handle)
        if response.status == 404 { return nil }
        try status(response, expected: 200)
        guard response.header("content-type")?.lowercased().hasPrefix("image/") == true else { throw PublicShareError.invalidResponse }
        return response.data
    }
    /// Uses the permission-gated download endpoint, never assembles streamed
    /// tracks to bypass isDownloadable. Cancellation removes every partial file.
    public func download(handle: PublicShareHandle) async throws -> PublicShareExport {
        try require(handle)
        guard snapshot?.isDownloadable == true else { throw PublicShareError.downloadForbidden }
        let metadata = try await perform(request(suffix: ""), policy: .bounded(2 * 1_048_576), epoch: handle.generation)
        try require(handle); try status(metadata, expected: 200)
        let wire = try decode(metadata.data)
        guard wire.id == handle.shareID, wire.playbackSession.id == handle.serverSessionID else { throw PublicShareError.sessionChanged }
        guard wire.isDownloadable == true else { throw PublicShareError.downloadForbidden }
        if let expiry = try expiry(wire.expiresAt), expiry <= Date() { throw PublicShareError.unavailable }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfMac-PublicShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("download")
        do {
            let response = try await perform(request(suffix: "/download"), policy: .export(file), epoch: handle.generation)
            try require(handle); try status(response, expected: 200, download: true); try Task.checkCancellation()
            return .init(fileURL: file, suggestedFilename: Self.filename(response.header("content-disposition")), contentType: response.header("content-type"))
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    @discardableResult public func checkpoint(currentTime: Double, handle: PublicShareHandle) async throws -> PublicShareCheckpoint {
        try await checkpoint(currentTime: currentTime, handle: handle, allowClosing: false)
    }
    @discardableResult public func syncProgress(currentTime: Double, handle: PublicShareHandle) async throws -> PublicShareCheckpoint {
        let checkpoint = try await checkpoint(currentTime: currentTime, handle: handle)
        return try await sendProgress(checkpoint, handle: handle, allowClosing: false)
    }
    @discardableResult public func close(currentTime: Double, handle: PublicShareHandle) async throws -> PublicShareCheckpoint {
        try require(handle, checkExpiry: false); closing = true
        let checkpoint: PublicShareCheckpoint
        do { checkpoint = try await self.checkpoint(currentTime: currentTime, handle: handle, allowClosing: true) }
        catch { closing = false; throw error }
        defer { closed = true; closing = false; generation = UUID(); snapshot = nil; transfers.values.forEach { $0.cancel() } }
        return try await sendProgress(checkpoint, handle: handle, allowClosing: true)
    }
    /// Release a safely checkpointed context without another remote PATCH.
    /// The coordinator decides whether its durable receipt permits handoff.
    public func retire(handle: PublicShareHandle) async throws {
        if closed { return }
        try require(handle, checkExpiry: false)
        closing = true
        defer { closing = false }
        opening?.cancel(); transfers.values.forEach { $0.cancel() }
        _ = await opening?.result; _ = await progressTail?.result
        if let saveTail { try await saveTail.value }
        generation = UUID(); snapshot = nil; closed = true; closing = false
    }
    public func forget() async throws {
        guard !closing else { throw PublicShareError.closed }
        closing = true
        defer { closing = false }
        opening?.cancel(); transfers.values.forEach { $0.cancel() }
        _ = await opening?.result; _ = await progressTail?.result; _ = await saveTail?.result
        if !loaded { storedBytes = try await store.load(key: location.storageKey); loaded = true }
        guard try await store.compareAndSwap(key: location.storageKey, expected: storedBytes, replacement: nil) else { closing = false; throw PublicShareError.stateConflict }
        storedBytes = nil; stored = .init(cookie: nil, progress: nil); generation = UUID(); snapshot = nil
        closed = true; closing = false
    }

    private func awaitOpening(_ task: Task<PublicShareSnapshot, Error>) async throws -> PublicShareSnapshot {
        try await withTaskCancellationHandler {
            let result = try await task.value; try Task.checkCancellation(); return result
        } onCancel: { task.cancel() }
    }
    private func performOpen(epoch: UUID) async throws -> PublicShareSnapshot {
        if !loaded {
            let bytes = try await store.load(key: location.storageKey)
            guard generation == epoch, !closing else { throw PublicShareError.sessionChanged }
            storedBytes = bytes
            if let bytes { stored = try JSONDecoder().decode(StoredShareState.self, from: bytes) }
            loaded = true
        }
        var request = URLRequest(url: try location.url(includeStart: !initialTimeApplied))
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let cookie = validCookie() { request.setValue("share_session_id=\(cookie.value)", forHTTPHeaderField: "Cookie") }
        let response = try await perform(request, policy: .bounded(2 * 1_048_576), epoch: epoch)
        guard generation == epoch, !closing else { throw PublicShareError.sessionChanged }
        try Task.checkCancellation()
        try status(response, expected: 200)
        let wire = try decode(response.data)
        let cookie = try responseCookie(response, url: request.url!) ?? validCookie()
        guard let cookie else { throw PublicShareError.invalidResponse }
        let handle = PublicShareHandle(serverSessionID: wire.playbackSession.id, shareID: wire.id, generation: epoch)
        let session = wire.playbackSession
        var position = session.currentTime
        if let saved = stored.progress, saved.shareID == wire.id, saved.mediaID == wire.mediaItemId,
           saved.checkpoint.savedAt > Date().addingTimeInterval(-30 * 86400),
           saved.serverSessionID != session.id || !saved.checkpoint.remoteAcknowledged { position = saved.checkpoint.currentTime }
        if !initialTimeApplied, let explicit = location.initialTime { position = explicit }
        position = min(max(position, 0), session.duration)
        let expiresAt = try expiry(wire.expiresAt)
        if let expiresAt, expiresAt <= Date() { throw PublicShareError.unavailable }
        let tracks = try session.audioTracks.map { track -> PublicShareTrack in
            try location.validateTrackURL(track.contentUrl, index: track.index)
            return .init(index: track.index, title: track.title ?? "", startOffset: track.startOffset,
                         duration: track.duration, url: try location.url(suffix: "/track/\(track.index)"), mimeType: track.mimeType)
        }
        let result = PublicShareSnapshot(handle: handle, shareID: wire.id, mediaID: wire.mediaItemId, mediaType: wire.mediaItemType,
            title: session.displayTitle ?? "", author: session.displayAuthor ?? "", duration: session.duration, currentTime: position,
            tracks: tracks, chapters: session.chapters ?? [], isDownloadable: wire.isDownloadable == true, expiresAt: expiresAt,
            hasCover: !(session.coverPath ?? "").isEmpty, serverVersion: session.serverVersion)
        try await persist(epoch: epoch) { state in
            state.cookie = cookie
            if state.progress?.shareID != wire.id || state.progress?.mediaID != wire.mediaItemId { state.progress = nil }
        }
        guard generation == epoch, !closing else { throw PublicShareError.sessionChanged }
        try Task.checkCancellation()
        snapshot = result; initialTimeApplied = true; return result
    }
    private func decode(_ data: Data) throws -> ShareWireDocument {
        let wire: ShareWireDocument
        do { wire = try JSONDecoder().decode(ShareWireDocument.self, from: data) }
        catch { throw PublicShareError.invalidResponse }
        let s = wire.playbackSession
        guard !wire.id.isEmpty, !wire.mediaItemId.isEmpty, wire.slug == location.slug, wire.mediaItemType == "book",
              !s.id.isEmpty, s.duration.isFinite, s.duration > 0, s.currentTime.isFinite, s.currentTime >= 0,
              !s.audioTracks.isEmpty, Set(s.audioTracks.map(\.index)).count == s.audioTracks.count,
              s.audioTracks.allSatisfy({ $0.index >= 0 && $0.duration.isFinite && $0.duration > 0 && $0.startOffset.isFinite && $0.startOffset >= 0 && $0.startOffset + $0.duration <= s.duration + 0.1 }),
              (s.chapters ?? []).allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { throw PublicShareError.invalidResponse }
        return wire
    }
    private func checkpoint(currentTime: Double, handle: PublicShareHandle, allowClosing: Bool) async throws -> PublicShareCheckpoint {
        try require(handle, allowClosing: allowClosing, checkExpiry: false)
        guard currentTime.isFinite, currentTime >= 0, let snapshot else { throw PublicShareError.invalidResponse }
        let checkpoint = PublicShareCheckpoint(id: UUID(), currentTime: min(currentTime, snapshot.duration), savedAt: Date(), remoteAcknowledged: false)
        let progress = StoredShareProgress(shareID: snapshot.shareID, mediaID: snapshot.mediaID, serverSessionID: handle.serverSessionID, checkpoint: checkpoint)
        try await persist(epoch: handle.generation) { $0.progress = progress }
        return checkpoint
    }
    private func sendProgress(_ checkpoint: PublicShareCheckpoint, handle: PublicShareHandle, allowClosing: Bool) async throws -> PublicShareCheckpoint {
        let previous = progressTail
        let task = Task { () throws -> PublicShareCheckpoint in
            _ = await previous?.result
            var result = checkpoint
            do {
                try Task.checkCancellation(); try self.require(handle, allowClosing: allowClosing)
                guard self.stored.progress?.checkpoint.id == checkpoint.id else { throw PublicShareError.progressSuperseded }
                var request = try self.request(suffix: "/progress"); request.httpMethod = "PATCH"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["currentTime": checkpoint.currentTime])
                let response = try await self.perform(request, policy: .bounded(4096), epoch: handle.generation)
                try self.require(handle, allowClosing: allowClosing); try self.status(response, expected: 204)
                result = .init(id: checkpoint.id, currentTime: checkpoint.currentTime, savedAt: checkpoint.savedAt, remoteAcknowledged: true)
                let acknowledged = result
                try await self.persist(epoch: handle.generation) { state in
                    if state.progress?.checkpoint.id == acknowledged.id { state.progress?.checkpoint = acknowledged }
                }
                return result
            } catch { throw PublicShareProgressSyncFailure(checkpoint: result, reason: (error as? PublicShareError) ?? .localStateUnavailable) }
        }
        progressTail = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func persist(epoch: UUID, mutation: @escaping @Sendable (inout StoredShareState) -> Void) async throws {
        let previous = saveTail
        let task = Task {
            _ = await previous?.result
            guard self.generation == epoch else { throw PublicShareError.sessionChanged }
            var next = self.stored; mutation(&next)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let bytes = try encoder.encode(next)
            guard try await self.store.compareAndSwap(key: self.location.storageKey, expected: self.storedBytes, replacement: bytes) else { throw PublicShareError.stateConflict }
            self.stored = next; self.storedBytes = bytes
        }
        saveTail = task
        try await task.value
    }
    private func require(_ handle: PublicShareHandle, allowClosing: Bool = false, checkExpiry: Bool = true) throws {
        guard !closed, (!closing || allowClosing), handle.generation == generation, snapshot?.handle == handle else { throw PublicShareError.sessionChanged }
        if checkExpiry, let expiry = snapshot?.expiresAt, expiry <= Date() { throw PublicShareError.unavailable }
    }
    private func request(suffix: String) throws -> URLRequest {
        guard let cookie = validCookie() else { throw PublicShareError.sessionChanged }
        var request = URLRequest(url: try location.url(suffix: suffix))
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("share_session_id=\(cookie.value)", forHTTPHeaderField: "Cookie")
        return request
    }
    private func validCookie() -> ShareCookie? {
        guard let cookie = stored.cookie, cookie.expiresAt > Date(), Self.validCookieValue(cookie.value) else { return nil }
        return cookie
    }
    private static func validCookieValue(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value.lowercased() else { return false }
        return Array(value)[14] == "4" && "89abAB".contains(Array(value)[19])
    }
    private func responseCookie(_ response: ShareHTTPResponse, url: URL) throws -> ShareCookie? {
        guard let raw = response.header("set-cookie") else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url).filter { $0.name == "share_session_id" }
        guard cookies.count == 1, let cookie = cookies.first,
              cookie.domain.lowercased() == url.host?.lowercased(), Self.validCookieValue(cookie.value),
              let expiry = cookie.expiresDate, expiry > Date() else { throw PublicShareError.invalidResponse }
        return .init(value: cookie.value, expiresAt: min(expiry, Date().addingTimeInterval(30 * 86400)))
    }
    private func perform(_ request: URLRequest, policy: ShareResponsePolicy, epoch: UUID) async throws -> ShareHTTPResponse {
        guard generation == epoch else { throw PublicShareError.sessionChanged }
        let id = UUID(), transfer = ShareHTTPTransfer(policy: policy); transfers[id] = transfer
        defer { transfers.removeValue(forKey: id) }
        let response = try await transfer.perform(request)
        guard generation == epoch else { throw PublicShareError.sessionChanged }
        return response
    }
    private func status(_ response: ShareHTTPResponse, expected: Int, download: Bool = false) throws {
        guard response.status == expected else {
            if response.status == 404 { throw PublicShareError.unavailable }
            if response.status == 403, download { throw PublicShareError.downloadForbidden }
            throw PublicShareError.http(response.status)
        }
    }
    private func expiry(_ text: String?) throws -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw PublicShareError.invalidResponse }; return date
    }
    private static func filename(_ disposition: String?) -> String {
        guard let disposition, let match = disposition.range(of: "filename=", options: .caseInsensitive) else { return "shared-media" }
        let text = disposition[match.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let value = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
        let safe = value.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters)).joined(separator: "_")
        return safe.isEmpty || safe == "." || safe == ".." ? "shared-media" : String(safe.prefix(200))
    }
}
