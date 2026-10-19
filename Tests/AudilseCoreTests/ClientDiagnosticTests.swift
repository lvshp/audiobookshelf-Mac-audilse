import Foundation
import Testing
@testable import AudilseCore

@Suite struct ClientDiagnosticTests {
    @Test func typedCapturePreservesCodesAndVerbatimArguments() throws {
        let values: [(DownloadTransferError, String, [String])] = [(.invalidResponse, "download.invalidResponse", []), (.invalidRange, "download.invalidRange", []), (.sourceChanged, "download.sourceChanged", []), (.http(416), "download.http", ["416"])]
        for (error, code, arguments) in values {
            let issue = ClientDiagnostic.capture(error)
            #expect(issue.code == code && issue.arguments == arguments)
            #expect(issue.fallbackMessage == error.localizedDescription)
        }
        let remote = "用户内容 %@ 中文 %1$@"
        let issue = ClientDiagnostic.capture(ABSError.http(status: 503, message: remote))
        #expect(issue.arguments == ["503", remote])
        #expect(ClientDiagnostic.capture(issue) == issue)
        #expect(ClientDiagnostic.capture(OfflineStorageError.incompleteDownload).code == "storage.incompleteDownload")
        #expect(ClientDiagnostic.capture(OfflineSyncError.verificationFailed).code == "sync.verificationFailed")
        let raw = NSError(domain: "Synthetic", code: 7, userInfo: [NSLocalizedDescriptionKey: remote, "secret": "must-not-be-serialized"])
        let unknown = ClientDiagnostic.capture(raw)
        #expect(unknown.code == "system.verbatim" && unknown.fallbackMessage == remote)
        #expect(!String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self).contains("must-not-be-serialized"))
    }
    private var legacyJSON: [String: Any] {
        ["itemID": "legacy", "title": "Book", "files": [], "state": "failed", "error": "旧记录原文", "createdAt": 0, "updatedAt": 1]
    }
    @Test func legacyRecordRemainsReadableAndRawTextIsNotGuessed() throws {
        let record = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(record.error == "旧记录原文" && record.errorDiagnostic == nil)
        #expect(record.state == .failed && record.files.isEmpty)
        #expect(record.updatedAt.timeIntervalSinceReferenceDate == 1)
    }
    @Test func newAndFutureDiagnosticsRoundTripAndLegacyConsumersReadFallback() throws {
        var record = DownloadRecord(itemID: "book", title: "Book", files: [], state: .failed)
        let issue = ClientDiagnostic(code: "future.error", arguments: ["raw"], fallbackMessage: "Future raw fallback", schemaVersion: 99)
        record.setError(issue)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: data) == record)
        struct OldRecord: Decodable { let itemID: String; let error: String? }
        #expect(try JSONDecoder().decode(OldRecord.self, from: data).error == issue.fallbackMessage)
        record.error = "replacement raw"
        #expect(record.errorDiagnostic == nil)
        record.setError(issue); record.error = nil
        #expect(record.error == nil && record.errorDiagnostic == nil)
    }
    @Test func corruptOptionalDiagnosticDoesNotHideOriginalsButMandatoryFieldsStayStrict() throws {
        var payload = legacyJSON
        payload["errorDiagnostic"] = ["code": 8]
        let record = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: payload))
        #expect(record.errorDiagnostic == nil && record.error == "旧记录原文")
        payload["files"] = "corrupt"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: payload)) }
        payload = legacyJSON; payload["state"] = "corrupt"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: payload)) }
    }
    @Test func sqliteReopenPreservesStructuredFailureAndAccountBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-diagnostic-db-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite"), partition = AccountPartition(serverID: UUID(), userID: "one")
        let database = try ShelfDatabase(path: path)
        var record = DownloadRecord(itemID: "book", title: "Book", files: [], state: .failed)
        record.setError(.capture(DownloadTransferError.http(503)))
        try await database.saveDownload(record, partition: partition)
        let reopened = try ShelfDatabase(path: path)
        #expect(try await reopened.downloads(partition: partition) == [record])
        #expect(try await reopened.downloads(partition: .init(serverID: partition.serverID, userID: "other")).isEmpty)
    }
    @Test @MainActor func managerPersistsActualHTTPFailuresAndRestoreRetainsTypedCause() async throws {
        for (route, code) in [("range", "download.invalidRange"), ("source", "download.sourceChanged"), ("http", "download.http")] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-diagnostic-download-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let database = try ShelfDatabase(path: root.appendingPathComponent("db.sqlite")), partition = AccountPartition(serverID: UUID(), userID: "fixture")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiagnosticDownloadProtocol.self]
            let manager = DownloadManager(database: database, rootDirectory: root.appendingPathComponent("files"), transfer: DownloadTransfer(session: URLSession(configuration: config)))
            let url = URL(string: "https://diagnostic.fixture.test/" + route)!
            try await manager.start(partition: partition, itemID: "book", title: "Book", tracks: [.init(ino: "track", title: "Track", filename: "a.mp3", contentURL: url, duration: 20, startOffset: 0, expectedBytes: 3)]) { URLRequest(url: $0) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while manager.records.first?.state != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(manager.records.first?.state == .failed)
            // A database read waits behind fail()'s save, proving the snapshot was persisted.
            let stored = try await database.downloads(partition: partition)
            #expect(stored.first?.errorDiagnostic?.code == code)
            let reopened = DownloadManager(database: try ShelfDatabase(path: root.appendingPathComponent("db.sqlite")), rootDirectory: root.appendingPathComponent("files"))
            try await reopened.restore(partition: partition)
            #expect(reopened.records.first?.errorDiagnostic?.code == code)
            #expect(reopened.records.first?.error == stored.first?.error)
        }
    }
}
private final class DiagnosticDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "diagnostic.fixture.test" else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        let route = url.lastPathComponent
        let response = HTTPURLResponse(url: url, statusCode: route == "http" ? 503 : route == "range" ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "2", "Content-Range": "bytes 1-2/3"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2])); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
