import Foundation
import Testing
@testable import AudilsePlayback

private let manifestText = """
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6,
output-0.ts
#EXTINF:6,
output-1.ts
#EXTINF:2.5,
output-2.ts
#EXT-X-ENDLIST
"""

@Test func hlsStartupUsesResumeAndFollowingSegment() throws {
    let url = URL(string: "https://shelf.example/abs/hls/session/output.m3u8")!
    let manifest = try HLSManifest(data: Data(manifestText.utf8), url: url)
    #expect(manifest.startupSegments(at: 5.9).map(\.lastPathComponent) == ["output-0.ts", "output-1.ts"])
    #expect(manifest.startupSegments(at: 6).map(\.lastPathComponent) == ["output-1.ts", "output-2.ts"])
    #expect(manifest.startupSegments(at: 999).map(\.lastPathComponent) == ["output-2.ts"])
    #expect(manifest.startupSegments(at: .nan).count == 2)
}

@Test func hlsManifestRejectsUnpairedAndExternalURIs() {
    let url = URL(string: "https://shelf.example/abs/hls/session/output.m3u8")!
    for text in ["#EXTM3U\noutput-0.ts", "#EXTM3U\n#EXTINF:-1,\noutput-0.ts", "#EXTM3U\n#EXTINF:6,\nhttps://other.example/0.ts", "#EXTM3U\n#EXTINF:6,\n../other/0.ts"] {
        #expect(throws: PlaybackFailure.invalidHLSManifest) { try HLSManifest(data: Data(text.utf8), url: url) }
    }
}

private final class HLSFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private final class HLSFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let counter = HLSFixtureCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isManifest = request.url!.pathExtension == "m3u8"
        let attempt = isManifest ? 0 : Self.counter.next()
        let status = isManifest ? 200 : (attempt == 1 ? 404 : 206)
        let data = isManifest ? Data(manifestText.utf8) : Data([0x47])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@Test func hlsGateRetriesUncreatedSegmentsBeforeReturning() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HLSFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    try await HLSReadinessGate(session: session, timeout: .seconds(2), retryDelay: .milliseconds(5))
        .wait(manifestURL: URL(string: "https://shelf.example/hls/session/output.m3u8")!, position: 6)
    #expect(HLSFixtureProtocol.counter.next() == 4)
}
