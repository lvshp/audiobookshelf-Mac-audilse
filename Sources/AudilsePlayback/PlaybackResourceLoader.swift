import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// The delegate and all AV request mutations run on the explicitly selected main
/// queue. Only immutable byte ranges cross to the Sendable transport source.
@MainActor
final class PlaybackResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let maximumChunkLength = 1_048_576
    static let maximumRequests = 8
    let url: URL
    private let source: any PlaybackResourceSource
    private var requests: [ObjectIdentifier: (AVAssetResourceLoadingRequest, Task<Void, Never>)] = [:]
    private var waiting: [AVAssetResourceLoadingRequest] = []
    private var cancelled = false
    private var totalLength: Int64?
    private var mimeType: String?

    init(source: any PlaybackResourceSource, filenameExtension: String) {
        self.source = source
        let suffix = filenameExtension.filter { $0.isLetter || $0.isNumber }.prefix(12)
        url = URL(string: "shelf-resource://\(UUID().uuidString)/media.\(suffix)")!
        super.init()
    }
    func makeAsset() -> AVURLAsset {
        // Public AVFoundation policy: even a container with embedded references
        // cannot resolve data outside itself through the default HTTP/file loaders.
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
        ])
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }
    func cancelAll() {
        cancelled = true
        let pending = Array(requests.values)
        requests.removeAll()
        let queued = waiting; waiting.removeAll()
        for request in queued where !request.isCancelled && !request.isFinished { request.finishLoading(with: URLError(.cancelled)) }
        for (request, task) in pending {
            task.cancel()
            if !request.isCancelled && !request.isFinished { request.finishLoading(with: URLError(.cancelled)) }
        }
    }
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { begin(loadingRequest) }
        return true
    }
    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated {
            requests.removeValue(forKey: ObjectIdentifier(loadingRequest))?.1.cancel()
            waiting.removeAll { $0 === loadingRequest }
            startPending()
        }
    }
    private func begin(_ request: AVAssetResourceLoadingRequest) {
        guard !cancelled else { request.finishLoading(with: URLError(.cancelled)); return }
        guard request.request.url == url, !["m3u", "m3u8"].contains(url.pathExtension.lowercased()) else {
            request.finishLoading(with: URLError(.unsupportedURL)); return
        }
        guard requests.count < Self.maximumRequests else {
            // AV may issue more than eight requests during normal seek/probing.
            // Queue metadata only, without starting additional byte allocations.
            guard waiting.count < 64 else { request.finishLoading(with: URLError(.resourceUnavailable)); return }
            waiting.append(request); return
        }
        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.startPending() }
            do {
                try await self.fulfill(request, id: id)
                guard self.requests.removeValue(forKey: id) != nil, !request.isCancelled else { return }
                request.finishLoading()
            } catch {
                guard self.requests.removeValue(forKey: id) != nil, !request.isCancelled else { return }
                request.finishLoading(with: error)
            }
        }
        requests[id] = (request, task)
    }
    private func startPending() {
        guard !cancelled else { return }
        while requests.count < Self.maximumRequests, !waiting.isEmpty {
            let request = waiting.removeFirst()
            if !request.isCancelled && !request.isFinished { begin(request) }
        }
    }
    private func fulfill(_ request: AVAssetResourceLoadingRequest, id: ObjectIdentifier) async throws {
        let dataRequest = request.dataRequest
        let requestedOffset = dataRequest?.requestedOffset ?? 0
        let start = max(requestedOffset, dataRequest?.currentOffset ?? 0)
        let length = dataRequest?.requestedLength ?? 1
        let (end, overflow) = requestedOffset.addingReportingOverflow(Int64(length))
        guard requestedOffset >= 0, start >= 0, length >= 0, !overflow else { throw URLError(.badServerResponse) }
        let allToEnd = dataRequest?.requestsAllDataToEndOfResource == true
        var offset = start
        repeat {
            try Task.checkCancellation()
            guard requests[id] != nil, !cancelled, !request.isCancelled else { throw CancellationError() }
            let remaining = allToEnd ? Int64(Self.maximumChunkLength) : max(0, end - offset)
            // Metadata-only requests still need one bounded transport response.
            let count = dataRequest == nil ? 1 : Int(min(Int64(Self.maximumChunkLength), remaining))
            if count == 0 { return }
            let chunk = try await source.read(offset: offset, length: count)
            try Task.checkCancellation()
            guard requests[id] != nil, !cancelled, !request.isCancelled else { throw CancellationError() }
            try validate(chunk, offset: offset, requestedLength: count)
            if let information = request.contentInformationRequest {
                information.contentLength = chunk.totalLength
                information.isByteRangeAccessSupported = true
                information.contentType = UTType(mimeType: chunk.contentType)?.identifier
                    ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
            }
            guard let dataRequest else { return }
            if !chunk.data.isEmpty { dataRequest.respond(with: chunk.data) }
            offset += Int64(chunk.data.count)
            if offset >= chunk.totalLength || (!allToEnd && offset >= end) { return }
        } while true
    }
    /// Validate transport metadata before exposing any bytes to AVFoundation.
    func validate(_ chunk: PlaybackResourceChunk, offset: Int64, requestedLength: Int) throws {
        let mime = chunk.contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !mime.isEmpty, !mime.contains("mpegurl"), !mime.contains("dash+xml") else { throw URLError(.unsupportedURL) }
        guard chunk.offset == offset, offset >= 0, chunk.totalLength >= offset,
              chunk.data.count <= requestedLength, requestedLength <= Self.maximumChunkLength,
              Int64(chunk.data.count) <= chunk.totalLength - offset,
              !chunk.data.isEmpty || offset == chunk.totalLength,
              totalLength == nil || totalLength == chunk.totalLength,
              mimeType == nil || mimeType == mime else { throw URLError(.badServerResponse) }
        totalLength = chunk.totalLength; mimeType = mime
    }
}
