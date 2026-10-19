import Foundation
import Testing
@testable import ShelfPlayback

private let proxyManifest = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n#EXTINF:2.5,\nc.ts\n#EXT-X-ENDLIST\n"

private let proxyPacket = Data([0x47] + Array(repeating: UInt8(0), count: 187))

private final class ProxyFixtureState: @unchecked Sendable {
    let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        paths.append(path)
        return paths.filter { $0 == path }.count
    }
    func recorded() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

private final class ProxyFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProxyFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.pathExtension == "m3u8" {
            let data = Data(proxyManifest.utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "\(data.count)"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let head = request.httpMethod == "HEAD"
        let attempt = Self.state.record((head ? "HEAD " : "") + url.path)
        let status = url.path.contains("cancel") || (!head && url.lastPathComponent == "a.ts" && attempt <= 2) ? 404 : 200
        var data = proxyPacket
        if url.path.contains("partial") && !head && attempt == 1 { data = Data(proxyPacket.dropLast()) }
        if url.path.contains("growth") && (head || attempt > 1) { data.append(proxyPacket) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": "\(data.count)"])!, cacheStoragePolicy: .notAllowed)
        if !head { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private func makeProxy(_ name: String, timeout: Duration = .seconds(2)) -> HLSStreamProxy {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProxyFixtureProtocol.self]
    return HLSStreamProxy(manifestURL: URL(string: "https://shelf.example/\(name)/output.m3u8")!, session: URLSession(configuration: configuration), timeout: timeout, retryDelay: .milliseconds(10))
}

@Test func proxyCropsToResumeSegmentAndPreservesTimeline() async throws {
    let proxy = makeProxy("crop")
    let data = try await proxy.rewrite(Data(proxyManifest.utf8), at: 9)
    let text = String(decoding: data, as: UTF8.self)
    #expect(await proxy.timeOffset == 6)
    #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:11"))
    let firstURI = text.components(separatedBy: "\n").first(where: { $0.hasSuffix(".ts") })!
    let localManifest = URL(string: "http://127.0.0.1" + firstURI)!.deletingLastPathComponent().appendingPathComponent("playlist.m3u8")
    let manifest = try HLSManifest(data: data, url: localManifest)
    #expect(manifest.segments.map(\.duration) == [6, 2.5])
    #expect(text.contains("#EXT-X-ENDLIST"))
    await proxy.cancel()
}

@Test func proxyRejectsExternalAndUnsupportedResources() async {
    let proxy = makeProxy("paths")
    for uri in ["https://evil.example/a.ts", "../a.ts", "%2e%2e/a.ts", "file:///a.ts"] {
        do {
            _ = try await proxy.rewrite(Data("#EXTM3U\n#EXTINF:6,\n\(uri)".utf8))
            Issue.record("Accepted unsafe URI: \(uri)")
        } catch { }
    }
    do {
        _ = try await proxy.rewrite(Data((proxyManifest + "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n").utf8))
        Issue.record("Accepted unproxied resource")
    } catch { }
    await proxy.cancel()
}

@Test func proxyRetriesFullSegmentAndCachesIt() async throws {
    let proxy = makeProxy("retry")
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    let first = try await proxy.segmentData(index: 0)
    let second = try await proxy.segmentData(index: 0)
    #expect(first == proxyPacket)
    #expect(second == first)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "/retry/a.ts" }.count == 3)
    await proxy.cancel()
}

@Test func proxySerializesRetriesBeforeFetchingNextSegment() async throws {
    let proxy = makeProxy("serial")
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    let first = Task { try await proxy.segmentData(index: 0) }
    while !ProxyFixtureProtocol.state.recorded().contains("/serial/a.ts") { await Task.yield() }
    async let duplicate = proxy.segmentData(index: 0)
    async let next = proxy.segmentData(index: 1)
    _ = try await (first.value, duplicate, next)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0.hasPrefix("/serial/") } == ["/serial/a.ts", "/serial/a.ts", "/serial/a.ts", "/serial/b.ts"])
    await proxy.cancel()
}

@Test func proxyCancellationStopsRetriesAndQueuedSegments() async throws {
    let proxy = makeProxy("cancel")
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    let first = Task { try await proxy.segmentData(index: 0) }
    while !ProxyFixtureProtocol.state.recorded().contains("/cancel/a.ts") { await Task.yield() }
    let next = Task { try await proxy.segmentData(index: 1) }
    await proxy.cancel()
    for task in [first, next] {
        do { _ = try await task.value; Issue.record("Cancelled proxy returned a segment") }
        catch { }
    }
    #expect(!ProxyFixtureProtocol.state.recorded().contains("/cancel/b.ts"))
}

@Test func proxyTimesOutTemporary404() async throws {
    let proxy = makeProxy("cancel-timeout", timeout: .milliseconds(35))
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    do { _ = try await proxy.segmentData(index: 0); Issue.record("404 did not time out") }
    catch { #expect(error as? PlaybackFailure == .streamNotReady) }
    await proxy.cancel()
}

@Test func proxyRetriesTruncatedTransportPackets() async throws {
    let proxy = makeProxy("partial")
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    let data = try await proxy.segmentData(index: 1)
    #expect(data == proxyPacket)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "/partial/b.ts" }.count == 2)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "HEAD /partial/b.ts" }.count == 1)
    await proxy.cancel()
}

@Test func proxyRetriesSegmentThatGrewAfterDownload() async throws {
    let proxy = makeProxy("growth")
    _ = try await proxy.rewrite(Data(proxyManifest.utf8))
    let data = try await proxy.segmentData(index: 1)
    #expect(data == proxyPacket + proxyPacket)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "/growth/b.ts" }.count == 2)
    #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "HEAD /growth/b.ts" }.count == 2)
    await proxy.cancel()
}

@Test func proxyServesLoopbackPlaylistAndSegmentAndClosesOnCancel() async throws {
    let proxy = makeProxy("loopback")
    let localURL = try await proxy.start(at: 9)
    #expect(localURL.host == "127.0.0.1")
    #expect(await proxy.timeOffset == 6)
    let client = URLSession(configuration: .ephemeral)
    defer { client.invalidateAndCancel() }
    do {
        let (playlist, playlistResponse) = try await client.data(from: localURL)
        #expect((playlistResponse as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding: playlist, as: UTF8.self)
        #expect(text.contains("#EXT-X-MEDIA-SEQUENCE:11"))
        let manifest = try HLSManifest(data: playlist, url: localURL)
        #expect(manifest.segments.map(\.duration) == [6, 2.5])
        let (segment, segmentResponse) = try await client.data(from: manifest.segments[0].url)
        #expect((segmentResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(segment == proxyPacket)
        #expect(ProxyFixtureProtocol.state.recorded().filter { $0 == "/loopback/b.ts" }.count == 1)
        #expect(!ProxyFixtureProtocol.state.recorded().contains("/loopback/a.ts"))

        let wrongToken = localURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("unknown-token/0.ts")
        let (_, missingResponse) = try await client.data(from: wrongToken)
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 404)
        let wrongPath = localURL.deletingLastPathComponent().appendingPathComponent("999.ts")
        let (_, wrongPathResponse) = try await client.data(from: wrongPath)
        #expect((wrongPathResponse as? HTTPURLResponse)?.statusCode == 404)
    } catch {
        await proxy.cancel()
        throw error
    }
    await proxy.cancel()
    var request = URLRequest(url: localURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
    request.setValue("close", forHTTPHeaderField: "Connection")
    do {
        _ = try await client.data(for: request)
        Issue.record("Cancelled proxy still accepted a loopback request")
    } catch { #expect(error is URLError) }
}

@Test func proxyMarksExhaustedLoopbackSegmentAsFailed() async throws {
    let proxy = makeProxy("cancel-loopback-timeout", timeout: .milliseconds(35))
    let localURL = try await proxy.start()
    let client = URLSession(configuration: .ephemeral)
    defer { client.invalidateAndCancel() }
    do {
        let (playlist, _) = try await client.data(from: localURL)
        let manifest = try HLSManifest(data: playlist, url: localURL)
        let (_, response) = try await client.data(from: manifest.segments[0].url)
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        #expect(await proxy.hasFailed)
    } catch {
        await proxy.cancel()
        throw error
    }
    await proxy.cancel()
}

@Test func proxyCancellationDoesNotMarkLoopbackSegmentFailed() async throws {
    let proxy = makeProxy("cancel-loopback-request")
    let localURL = try await proxy.start()
    let client = URLSession(configuration: .ephemeral)
    defer { client.invalidateAndCancel() }
    do {
        let (playlist, _) = try await client.data(from: localURL)
        let manifest = try HLSManifest(data: playlist, url: localURL)
        let request = Task { try await client.data(from: manifest.segments[0].url) }
        while !ProxyFixtureProtocol.state.recorded().contains("/cancel-loopback-request/a.ts") { await Task.yield() }
        await proxy.cancel()
        _ = await request.result
        #expect(await proxy.hasFailed == false)
    } catch {
        await proxy.cancel()
        throw error
    }
}
