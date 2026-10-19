import Foundation
import Network

/// Shields AVFoundation from ABS's temporary segment 404s. Each playback load
/// owns one proxy, so cancelling it also stops that load's transcoder requests.
actor HLSStreamProxy {
    private let manifestURL: URL
    private let session: URLSession
    private let timeout: Duration
    private let retryDelay: Duration
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "Audilse.HLSProxy")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var localURL: URL?
    private var playlist = Data()
    private(set) var timeOffset = 0.0
    private(set) var hasFailed = false
    private var segments: [URL] = []
    private var cancelled = false
    private var cancellationTask: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var handlers: [UUID: Task<Void, Never>] = [:]
    private var pending: [Int: Task<Data, Error>] = [:]
    private var tail: Task<Data, Error>?
    private var waiters: [Int: Set<UUID>] = [:]
    private var headerTimers: [UUID: Task<Void, Never>] = [:]
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cacheBytes = 0
    private static let segmentLimit = 16 * 1024 * 1024
    private static let cacheLimit = 16 * 1024 * 1024

    init(manifestURL: URL, session: URLSession? = nil, timeout: Duration = .seconds(90), retryDelay: Duration = .milliseconds(500)) {
        self.manifestURL = manifestURL
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.timeout = timeout
        self.retryDelay = retryDelay
    }

    func start(at position: Double = 0) async throws -> URL {
        try ensureActive()
        if let localURL { return localURL }
        guard listener == nil, ["http", "https"].contains(manifestURL.scheme) else { throw PlaybackFailure.invalidHLSManifest }
        let (data, response) = try await Self.download(manifestURL, session: session, limit: 2 * 1024 * 1024, seconds: 15)
        guard response.statusCode == 200 else { throw PlaybackFailure.invalidHLSManifest }
        playlist = try rewrite(data, at: position)
        try ensureActive()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                listener.start(queue: queue)
            }
        } onCancel: { Task { await self.cancel() } }
    }

    private func listenerChanged(_ state: NWListener.State) async {
        switch state {
        case .ready:
            guard let port = listener?.port, !cancelled else { return }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/playlist.m3u8")!
            localURL = url
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            await cancel()
        default: break
        }
    }

    func cancel() async {
        if let cancellationTask { await cancellationTask.value; return }
        guard !cancelled else { return }
        cancelled = true
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
        listener?.cancel()
        listener = nil
        let requests = Array(pending.values)
        for task in requests { task.cancel() }
        for task in handlers.values { task.cancel() }
        for task in headerTimers.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        pending.removeAll(); handlers.removeAll(); connections.removeAll(); headerTimers.removeAll(); waiters.removeAll()
        cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
        session.invalidateAndCancel()
        let completion = Task {
            for task in requests { _ = await task.result }
        }
        cancellationTask = completion
        await completion.value
    }

    /// Internal for deterministic validation without requiring a listening socket.
    func rewrite(_ data: Data, at position: Double = 0) throws -> Data {
        guard ["http", "https"].contains(manifestURL.scheme),
              let text = String(data: data, encoding: .utf8) else { throw PlaybackFailure.invalidHLSManifest }
        let manifest = try HLSManifest(data: data, url: manifestURL)
        // ABS uses plain MPEG-TS. Reject external resource tags and byte ranges
        // rather than accidentally allowing an unproxied URL or wrong byte data.
        guard !text.uppercased().contains("URI="), !text.contains("#EXT-X-BYTERANGE") else { throw PlaybackFailure.invalidHLSManifest }
        for segment in manifest.segments {
            guard segment.url.user == nil, segment.url.password == nil,
                  segment.url.standardized.deletingLastPathComponent().path == manifestURL.standardized.deletingLastPathComponent().path,
                  !(segment.url.path.removingPercentEncoding ?? "..").split(separator: "/").contains("..") else {
                throw PlaybackFailure.invalidHLSManifest
            }
        }
        let position = position.isFinite ? max(0, position) : 0
        let first = manifest.segments.lastIndex(where: { $0.start <= position }) ?? 0
        timeOffset = manifest.segments[first].start
        segments = manifest.segments.dropFirst(first).map(\.url)
        var index = 0
        var hasSequence = false
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let sequence = Int(trimmed.dropFirst(22)), sequence >= 0, sequence <= Int.max - first else { throw PlaybackFailure.invalidHLSManifest }
                lines.append("#EXT-X-MEDIA-SEQUENCE:\(sequence + first)")
                hasSequence = true
            } else if trimmed.hasPrefix("#EXTINF:") {
                if index >= first { lines.append(line) }
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                if index >= first { lines.append("/\(token)/\(index - first).ts") }
                index += 1
            } else if trimmed == "#EXT-X-DISCONTINUITY" || trimmed.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                if index >= first { lines.append(line) }
            } else { lines.append(line) }
        }
        if !hasSequence { lines.insert("#EXT-X-MEDIA-SEQUENCE:\(first)", at: 1) }
        return Data(lines.joined(separator: "\n").utf8)
    }

    func segmentData(index: Int) async throws -> Data {
        try ensureActive()
        guard segments.indices.contains(index) else { throw PlaybackFailure.invalidHLSManifest }
        if let data = cache[index] { return data }
        if let task = pending[index] { return try await waitForSegment(task, index: index) }
        let previous = tail
        let url = segments[index], session = session, timeout = timeout, retryDelay = retryDelay
        let task = Task<Data, Error> {
            _ = await previous?.result
            try Task.checkCancellation()
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let remaining = ContinuousClock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                do {
                    let (data, response) = try await Self.download(url, session: session, limit: Self.segmentLimit, seconds: min(8, max(0.01, seconds)))
                    if response.statusCode == 200 {
                        // A published path can still be growing. Reject incomplete TS
                        // packets and require its size to remain stable before serving.
                        if Self.hasCompleteTransportPackets(data), ContinuousClock.now.advanced(by: .milliseconds(250)) < deadline {
                            try await Task.sleep(for: .milliseconds(250))
                            let remaining = ContinuousClock.now.duration(to: deadline)
                            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                            let (_, confirmation) = try await Self.download(url, session: session, limit: Self.segmentLimit,
                                seconds: min(8, max(0.01, seconds)), method: "HEAD")
                            if confirmation.statusCode == 200, confirmation.expectedContentLength == Int64(data.count) { return data }
                        }
                    } else if response.statusCode != 404 && !(500...599).contains(response.statusCode) {
                        throw PlaybackFailure.streamNotReady
                    }
                } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
                    try Task.checkCancellation()
                }
                let delay = min(retryDelay, ContinuousClock.now.duration(to: deadline))
                if delay > .zero { try await Task.sleep(for: delay) }
            }
            throw PlaybackFailure.streamNotReady
        }
        pending[index] = task
        tail = task
        do {
            let data = try await waitForSegment(task, index: index)
            try ensureActive()
            pending[index] = nil
            while cacheBytes + data.count > Self.cacheLimit, let oldest = cacheOrder.first {
                cacheOrder.removeFirst()
                cacheBytes -= cache.removeValue(forKey: oldest)?.count ?? 0
            }
            cache[index] = data; cacheOrder.append(index); cacheBytes += data.count
            return data
        } catch {
            pending[index] = nil
            throw error
        }
    }

    private func waitForSegment(_ task: Task<Data, Error>, index: Int) async throws -> Data {
        let waiter = UUID()
        waiters[index, default: []].insert(waiter)
        defer { releaseWaiter(waiter, index: index) }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: { Task { await self.releaseWaiter(waiter, index: index) } }
    }

    private func releaseWaiter(_ waiter: UUID, index: Int) {
        guard waiters[index]?.remove(waiter) != nil else { return }
        if waiters[index]?.isEmpty == true {
            waiters[index] = nil
            pending[index]?.cancel()
        }
    }

    private static func hasCompleteTransportPackets(_ data: Data) -> Bool {
        !data.isEmpty && data.count.isMultiple(of: 188) && stride(from: 0, to: data.count, by: 188).allSatisfy { data[$0] == 0x47 }
    }

    private static func download(_ url: URL, session: URLSession, limit: Int, seconds: Double, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = method
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request, delegate: HLSNoRedirectDelegate())
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= Int64(limit) else { throw PlaybackFailure.invalidHLSManifest }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw PlaybackFailure.invalidHLSManifest }
            data.append(byte)
        }
        return (data, response)
    }

    private func ensureActive() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func accept(_ connection: NWConnection) {
        guard !cancelled, connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        headerTimers[id] = Task {
            do { try await Task.sleep(for: .seconds(15)); close(id) } catch { }
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(id) } }
            if case .cancelled = state { Task { await self?.close(id) } }
        }
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { await self?.received(connection, id: id, buffer: buffer, data: data, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ connection: NWConnection, id: UUID, buffer: Data, data: Data?, complete: Bool, failed: Bool) {
        guard connections[id] != nil else { return }
        var buffer = buffer
        if let data { buffer.append(data) }
        guard buffer.count <= 16384, !failed else { close(id); return }
        if let end = buffer.range(of: Data("\r\n\r\n".utf8)), let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
            headerTimers.removeValue(forKey: id)?.cancel()
            handlers[id] = Task { await respond(connection, id: id, header: header) }
            // Detect a client closing while its upstream segment is still pending.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
                if complete || error != nil { Task { await self?.close(id) } }
            }
        } else if complete { close(id) }
        else { receive(connection, id: id, buffer: buffer) }
    }

    private func respond(_ connection: NWConnection, id: UUID, header: String) async {
        let parts = header.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count == 3, ["GET", "HEAD"].contains(parts[0]), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            send(connection, id: id, status: "400 Bad Request", data: Data()); return
        }
        let path = String(parts[1]), head = parts[0] == "HEAD"
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { send(connection, id: id, status: "404 Not Found", data: Data()); return }
        let name = String(path.dropFirst(prefix.count))
        do {
            let data: Data, type: String
            if name == "playlist.m3u8" { data = playlist; type = "application/vnd.apple.mpegurl" }
            else if name.hasSuffix(".ts"), let index = Int(name.dropLast(3)), name == "\(index).ts", segments.indices.contains(index) {
                data = try await segmentData(index: index); type = "video/mp2t"
            } else { send(connection, id: id, status: "404 Not Found", data: Data()); return }
            try ensureActive()
            send(connection, id: id, status: "200 OK", data: data, type: type, head: head)
        } catch {
            if !cancelled, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled { hasFailed = true }
            send(connection, id: id, status: "503 Service Unavailable", data: Data())
        }
    }

    private func send(_ connection: NWConnection, id: UUID, status: String, data: Data, type: String = "text/plain", head: Bool = false) {
        guard connections[id] != nil, !cancelled else { return }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Length: \(data.count)\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { await self?.close(id) } })
    }

    private func close(_ id: UUID) {
        headerTimers.removeValue(forKey: id)?.cancel()
        handlers.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
}

private final class HLSNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
