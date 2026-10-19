import Foundation

/// ABS publishes a complete VOD playlist before its on-demand transcoder has
/// created any segments. Giving AVFoundation a 404 here can cause long retries.
struct HLSManifest: Sendable {
    struct Segment: Sendable { let url: URL; let start: Double; let duration: Double }
    let segments: [Segment]

    init(data: Data, url: URL) throws {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw PlaybackFailure.invalidHLSManifest }
        var result: [Segment] = [], offset = 0.0, segmentDuration: Double?
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
                guard let value, value.isFinite, value > 0 else { throw PlaybackFailure.invalidHLSManifest }
                segmentDuration = value
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let duration = segmentDuration, let segmentURL = URL(string: line, relativeTo: url)?.absoluteURL,
                      segmentURL.scheme == url.scheme, segmentURL.host == url.host, segmentURL.port == url.port,
                      segmentURL.deletingLastPathComponent().path == url.deletingLastPathComponent().path else { throw PlaybackFailure.invalidHLSManifest }
                result.append(Segment(url: segmentURL, start: offset, duration: duration))
                offset += duration
                // Each URI must have its own EXTINF declaration.
                segmentDuration = nil
            }
        }
        guard !result.isEmpty else { throw PlaybackFailure.invalidHLSManifest }
        segments = result
    }

    func startupSegments(at seconds: Double) -> [URL] {
        let time = seconds.isFinite ? max(0, seconds) : 0
        let index = segments.lastIndex(where: { $0.start <= time }) ?? 0
        return Array(segments[index...min(index + 1, segments.count - 1)]).map(\.url)
    }
}

struct HLSReadinessGate: Sendable {
    let session: URLSession
    let timeout: Duration
    let retryDelay: Duration

    init(session: URLSession = URLSession(configuration: .ephemeral), timeout: Duration = .seconds(30), retryDelay: Duration = .milliseconds(500)) {
        self.session = session; self.timeout = timeout; self.retryDelay = retryDelay
    }

    func wait(manifestURL: URL, position: Double) async throws {
        var request = URLRequest(url: manifestURL); request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw PlaybackFailure.invalidHLSManifest }
        let targets = try HLSManifest(data: data, url: manifestURL).startupSegments(at: position)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var ready = true
            for url in targets {
                var probe = URLRequest(url: url); probe.timeoutInterval = 4
                probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                do {
                    let (data, response) = try await session.data(for: probe)
                    guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode), !data.isEmpty else { ready = false; break }
                } catch is CancellationError { throw CancellationError() }
                catch { ready = false; break }
            }
            if ready { return }
            try await Task.sleep(for: retryDelay)
        }
        throw PlaybackFailure.streamNotReady
    }
}
