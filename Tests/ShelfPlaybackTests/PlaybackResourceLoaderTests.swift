import Foundation
@preconcurrency import AVFoundation
import Testing
import ShelfCore
@testable import ShelfPlayback

private actor ResourceGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private actor MemoryResource: PlaybackResourceSource {
    let bytes: Data
    let gate: ResourceGate?
    var ranges: [(Int64, Int)] = []
    init(bytes: Data, gate: ResourceGate? = nil) { self.bytes = bytes; self.gate = gate }
    func read(offset: Int64, length: Int) async throws -> PlaybackResourceChunk {
        ranges.append((offset, length)); await gate?.wait()
        guard offset >= 0, offset <= bytes.count else { throw URLError(.badServerResponse) }
        let start = Int(offset), end = min(bytes.count, start + length)
        return .init(offset: offset, data: bytes.subdata(in: start..<end), totalLength: Int64(bytes.count), contentType: "audio/wav")
    }
}
private func resourceWAV() -> Data {
    let byteCount = 1_920_000
    var bytes = Data()
    func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
    func long(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
    bytes.append(contentsOf: "RIFF".utf8); long(UInt32(36 + byteCount)); bytes.append(contentsOf: "WAVEfmt ".utf8)
    long(16); word(1); word(1); long(48_000); long(96_000); word(2); word(16)
    bytes.append(contentsOf: "data".utf8); long(UInt32(byteCount)); bytes.append(Data(count: byteCount))
    return bytes
}
private actor ResourcePlaybackService: PlaybackService {
    let source: MemoryResource
    init(source: MemoryResource) { self.source = source }
    func prepare(media: PlaybackMedia) -> PreparedPlayback {
        .init(media: media, tracks: [.init(index: 0, url: URL(string: "https://never-request.invalid/synthetic.wav")!, duration: 20, startOffset: 0)], sessionID: nil, initialPosition: 0)
    }
    func authorize(track: PlaybackTrack) -> PlaybackTrack { track }
    func resourceSource(for track: PlaybackTrack) -> (any PlaybackResourceSource)? { source }
    func sync(sessionID: String, currentTime: Double, timeListened: Double) {}
    func close(sessionID: String, currentTime: Double, timeListened: Double) {}
}
@MainActor private func resourceWait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard await condition() else { throw URLError(.timedOut) }
}

@Test @MainActor func resourceTransportRejectsMismatchedOrNonProgressingChunks() throws {
    let source = MemoryResource(bytes: Data(count: 4))
    let loader = PlaybackResourceLoader(source: source, filenameExtension: "wav")
    #expect(throws: (any Error).self) { try loader.validate(.init(offset: 1, data: Data([1]), totalLength: 4, contentType: "audio/wav"), offset: 0, requestedLength: 1) }
    #expect(throws: (any Error).self) { try loader.validate(.init(offset: 0, data: Data(), totalLength: 4, contentType: "audio/wav"), offset: 0, requestedLength: 1) }
    #expect(throws: (any Error).self) { try loader.validate(.init(offset: 0, data: Data([1, 2]), totalLength: 4, contentType: "audio/wav"), offset: 0, requestedLength: 1) }
    #expect(throws: (any Error).self) { try loader.validate(.init(offset: 0, data: Data([1]), totalLength: 4, contentType: "application/vnd.apple.mpegurl"), offset: 0, requestedLength: 1) }
    try loader.validate(.init(offset: 0, data: Data([1]), totalLength: 4, contentType: "audio/wav"), offset: 0, requestedLength: 1)
    #expect(throws: (any Error).self) { try loader.validate(.init(offset: 1, data: Data([2]), totalLength: 5, contentType: "audio/wav"), offset: 1, requestedLength: 1) }
    try loader.validate(.init(offset: 4, data: Data(), totalLength: 4, contentType: "audio/wav"), offset: 4, requestedLength: 1)
}

@Test @MainActor func customResourceAssetUsesBoundedSourceAndControllerSeeksWithoutHTTP() async throws {
    let source = MemoryResource(bytes: resourceWAV())
    let controller = PlaybackController(ownsSystemMediaControls: false, service: ResourcePlaybackService(source: source), persist: { _ in })
    await controller.play(media: .init(itemID: "resource", title: "Resource", duration: 20))
    try await resourceWait { controller.isPlaying && controller.position > 0 }
    controller.pause(); await controller.seek(to: 4)
    #expect(controller.position == 4)
    controller.resume(); try await resourceWait { controller.position > 4.1 }
    let ranges = await source.ranges
    #expect(!ranges.isEmpty && ranges.allSatisfy { $0.0 >= 0 && $0.1 > 0 && $0.1 <= 1_048_576 })
    #expect(controller.error == nil)
    #expect((await controller.shutdownForQuit()).mayQuit)
}

@Test @MainActor func cancellingAssetDiscardsAnUncooperativeLateRead() async throws {
    let gate = ResourceGate(), source = MemoryResource(bytes: resourceWAV(), gate: gate)
    let loader = PlaybackResourceLoader(source: source, filenameExtension: "wav")
    let asset = loader.makeAsset()
    let operation = Task { try await asset.load(.duration) }
    try await resourceWait { !(await source.ranges).isEmpty }
    loader.cancelAll(); await gate.release()
    do { _ = try await operation.value; Issue.record("Cancelled custom resource unexpectedly completed") } catch { }
    let count = await source.ranges.count
    try await Task.sleep(for: .milliseconds(100))
    #expect(await source.ranges.count == count)
}

@Test @MainActor func normalNinthResourceRequestWaitsForCapacityInsteadOfFailing() async throws {
    let gate = ResourceGate(), source = MemoryResource(bytes: resourceWAV(), gate: gate)
    let loader = PlaybackResourceLoader(source: source, filenameExtension: "wav")
    let assets = (0..<12).map { _ in loader.makeAsset() }
    let operations = assets.map { asset in Task { try await asset.load(.duration) } }
    try await resourceWait { await source.ranges.count == PlaybackResourceLoader.maximumRequests }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await source.ranges.count == PlaybackResourceLoader.maximumRequests)
    await gate.release()
    for operation in operations { let duration = try await operation.value; #expect(abs(duration.seconds - 20) < 0.01) }
    loader.cancelAll()
}

@Test @MainActor func customResourceAssetForbidsAllExternalContainerReferences() {
    let loader = PlaybackResourceLoader(source: MemoryResource(bytes: resourceWAV()), filenameExtension: "wav")
    #expect(loader.makeAsset().referenceRestrictions == .forbidAll)
}
