import Foundation
import Testing
@testable import AudilseCore

private final class ContentExtraHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        if url.path.hasSuffix("/remove-metadata") {
            #expect(request.httpMethod == "POST")
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [.init(name: "ext", value: "abs")])
            body = #"{"found":3,"removed":2}"#
        } else if url.path.hasSuffix("/status") {
            #expect(request.httpMethod == "PATCH")
            #expect(request.httpBody == nil)
            body = "OK"
        } else {
            #expect(request.httpMethod == "GET")
            body = #"{"libraryFiles":[{"ino":"primary","fileType":"ebook","isSupplementary":false,"metadata":{"filename":"book.epub"}},{"ino":"extra","fileType":"ebook","isSupplementary":true,"metadata":{"filename":"notes.pdf"}},{"ino":"opf","fileType":"metadata","metadata":{"filename":"book.opf"}},{"ino":"abs","fileType":"metadata","metadata":{"filename":"metadata.abs"}}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite struct ContentManagementExtraTests {
    private func book() -> LibraryItem {
        var book = LibraryItem(id: "book", libraryId: "library", mediaType: "book", media: .init(metadata: .init(title: "Book", authors: [.init(id: "a", name: "作者")], narrators: ["原演播者"], genres: ["原分类"], series: [.init(id: "s", name: "系列", sequence: "2.5")]), tags: ["原标签"]))
        book.isMissing = false
        return book
    }
    @Test func appendPreservesExistingIdentityAndSeriesSequence() throws {
        var edits = BatchMetadataEdits()
        edits.authors = ["作者", "新作者", "新作者"]
        edits.series = [.init(name: "系列", sequence: "1"), .init(name: "新系列", sequence: "前传")]
        edits.tags = ["原标签", "新标签"]
        edits.subtitle = "统一副标题"
        edits.publishedYear = "2026"
        edits.abridged = false
        let update = edits.applying(to: book(), appendLists: true)
        #expect(update.mediaPayload.metadata?.authors?.map(\.name) == ["作者", "新作者"])
        #expect(update.mediaPayload.metadata?.authors?.first?.id == "a")
        #expect(update.mediaPayload.metadata?.series?.first == NamedEntity(id: "s", name: "系列", sequence: "2.5"))
        #expect(update.mediaPayload.metadata?.series?.last?.sequence == "前传")
        #expect(update.mediaPayload.tags == ["原标签", "新标签"])
        let data = try JSONEncoder().encode(update)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let media = try #require(object["mediaPayload"] as? [String: Any])
        let metadata = try #require(media["metadata"] as? [String: Any])
        #expect(metadata["narrators"] == nil && metadata["title"] == nil && metadata["description"] == nil)
        #expect(metadata["subtitle"] as? String == "统一副标题")
        #expect(metadata["abridged"] as? Bool == false)
    }
    @Test func replacementCanClearListsAndChangeSequenceWithoutLosingID() {
        var edits = BatchMetadataEdits()
        edits.authors = []; edits.tags = []; edits.subtitle = ""
        edits.series = [.init(name: "系列", sequence: nil)]
        let update = edits.applying(to: book(), appendLists: false)
        #expect(update.mediaPayload.metadata?.authors == [])
        #expect(update.mediaPayload.tags == [])
        #expect(update.mediaPayload.metadata?.subtitle == "")
        #expect(update.mediaPayload.metadata?.series == [.init(id: "s", name: "系列")])
    }
    @Test func podcastDoesNotReceiveBookOnlyFields() {
        var item = book(); item.mediaType = "podcast"
        var edits = BatchMetadataEdits(); edits.series = []; edits.authors = []; edits.abridged = true; edits.isbn = "fixture"; edits.genres = ["访谈"]
        let metadata = edits.applying(to: item, appendLists: false).mediaPayload.metadata
        #expect(metadata?.series == nil && metadata?.authors == nil && metadata?.abridged == nil && metadata?.isbn == nil)
        #expect(metadata?.genres == ["访谈"])
    }
    @Test func supplementaryFlagsAndMetadataCleanupFollowServerContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ContentExtraHTTP.self]
        let tokenStore = MemoryTokenStore()
        let client = ABSClient(profile: .init(name: "Fixture", baseURL: URL(string: "https://fixture.test")!), session: URLSession(configuration: configuration), tokenStore: tokenStore)
        await tokenStore.save(.init(accessToken: "fixture", userID: "user"), account: client.tokenAccount)
        let files = try await client.managedItemFiles(id: "book")
        #expect(files.filter(\.isEBook).count == 2)
        #expect(files.first?.isSupplementary == false)
        #expect(files[1].isSupplementary == true)
        #expect(files.filter(\.isMetadataSidecar).map(\.ino) == ["opf", "abs"])
        try await client.toggleEBookSupplementary(itemID: "book", fileID: "extra")
        let result = try await client.removeLibraryMetadataFiles(id: "library", kind: .abs)
        #expect(result.found == 3 && result.removed == 2)
    }
    @Test func multipartPreparationReportsRealByteCountsAndHonorsCancellation() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        let count = 2 * 1024 * 1024 + 13
        try Data(repeating: 0xAB, count: count).write(to: input)
        let observations = UploadObservations()
        let prepared = try await MultipartFileBuilder().build(fields: ["title": "fixture"], files: [.init(name: "file0", file: .init(localURL: input))], progress: observations.append)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let events = observations.values()
        #expect(events.first?.0 == 0 && events.first?.1 == Int64(count))
        #expect(events.last?.0 == Int64(count) && events.last?.1 == Int64(count))
        #expect(prepared.size > Int64(count))
        let cancelled = Task {
            try await MultipartFileBuilder().build(fields: [:], files: [.init(name: "file0", file: .init(localURL: input))])
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}

private final class UploadObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int64, Int64)] = []
    func append(_ completed: Int64, _ total: Int64) { lock.lock(); defer { lock.unlock() }; events.append((completed, total)) }
    func values() -> [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return events }
}
