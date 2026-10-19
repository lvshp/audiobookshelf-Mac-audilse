import Foundation
import Testing
@testable import AudilseCore

private final class NarratorHTTP: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests = [URLRequest]()
        var handler: @Sendable (URLRequest) throws -> (Int, Data) = { _ in throw URLError(.unsupportedURL) }
        func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
            lock.lock(); defer { lock.unlock() }; self.handler = handler; requests = []
        }
        func respond(_ request: URLRequest) throws -> (Int, Data) {
            lock.lock(); requests.append(request); let handler = handler; lock.unlock(); return try handler(request)
        }
        func count(_ method: String? = nil) -> Int {
            lock.lock(); defer { lock.unlock() }; return requests.filter { method == nil || $0.httpMethod == method }.count
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.state.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func narratorClient(version: String?) async -> ABSClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NarratorHTTP.self]
    let store = MemoryTokenStore()
    let client = ABSClient(profile: .init(name: "Narrator fixture", baseURL: URL(string: "https://narrator.fixture/base")!, userID: "fixture-user", serverVersion: version),
                           session: URLSession(configuration: configuration), tokenStore: store)
    await store.save(.init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", userID: "fixture-user"), account: client.tokenAccount)
    return client
}
private func narratorBody(_ request: URLRequest) throws -> [String: String] {
    if let data = request.httpBody { return try JSONDecoder().decode([String: String].self, from: data) }
    guard let stream = request.httpBodyStream else { return [:] }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return try JSONDecoder().decode([String: String].self, from: data)
}

@Suite(.serialized) struct LibraryNarratorTests {
    @Test(arguments: ["2.26.0", "2.36.1", "2.37.1"])
    func directoryIsCompleteTypedAndUnpaginated(version: String) async throws {
        NarratorHTTP.state.install { request in
            #expect(request.httpMethod == "GET" && request.url?.path == "/base/api/libraries/library id/narrators" && request.url?.query == nil)
            return (200, Data(#"{"narrators":[{"id":"Pz8%2F","name":"???","numBooks":12},{"id":"YQ%3D%3D","name":"a","numBooks":0}]}"#.utf8))
        }
        let result = try await narratorClient(version: version).libraryNarrators(libraryID: "library id")
        #expect(result == [.init(id: "Pz8%2F", name: "???", numBooks: 12), .init(id: "YQ%3D%3D", name: "a", numBooks: 0)])
        #expect(try JSONDecoder().decode([LibraryNarrator].self, from: JSONEncoder().encode(result)) == result)
    }
    @Test func emptyDirectoryIsARealSuccessfulSnapshot() async throws {
        NarratorHTTP.state.install { _ in (200, Data(#"{"narrators":[]}"#.utf8)) }
        #expect(try await narratorClient(version: "2.26.0").libraryNarrators(libraryID: "lib") == [])
    }
    @Test(arguments: [nil, "", "unknown", "2.26.0", "2.36.0", "2.36.1-beta.1", "2.37", "2.37.1 invalid"] as [String?])
    func unsupportedWritesNeverReachHTTP(version: String?) async throws {
        NarratorHTTP.state.install { _ in Issue.record("Unsafe write reached HTTP"); return (200, Data(#"{"updated":1}"#.utf8)) }
        let client = await narratorClient(version: version)
        await #expect(throws: LibraryNarratorError.unsafeServerVersion) { try await client.renameLibraryNarrator(libraryID: "lib", currentName: "a", newName: "b") }
        await #expect(throws: LibraryNarratorError.unsafeServerVersion) { try await client.removeLibraryNarrator(libraryID: "lib", name: "a") }
        #expect(NarratorHTTP.state.count() == 0)
    }
    @Test func updatePermissionControlsBothRenameAndRemoval() {
        let updater = UserAccount(id: "u", username: "updater", permissions: .init(update: true, delete: false))
        let deleter = UserAccount(id: "u", username: "deleter", permissions: .init(update: false, delete: true))
        #expect(LibraryNarratorPolicy.allowsMutation(user: updater, serverVersion: "2.37.1"))
        #expect(!LibraryNarratorPolicy.allowsMutation(user: deleter, serverVersion: "2.37.1"))
        var inactive = updater; inactive.isActive = false
        #expect(!LibraryNarratorPolicy.allowsMutation(user: inactive, serverVersion: "2.37.1"))
        #expect(!LibraryNarratorPolicy.allowsMutation(user: updater, serverVersion: "2.26.0"))
    }
    @Test(arguments: ["2.36.1", "2.37.1"])
    func bothVerifiedVersionsUseTypedWriteOutcomes(version: String) async throws {
        NarratorHTTP.state.install { request in
            #expect(request.url?.path == "/base/api/libraries/lib/narrators/T2xk" && request.url?.query == nil)
            if request.httpMethod == "PATCH" { let body = try narratorBody(request); #expect(body == ["name": "Existing"]) }
            else { #expect(request.httpMethod == "DELETE" && request.httpBody == nil) }
            return (200, Data(#"{"updated":0}"#.utf8))
        }
        let client = await narratorClient(version: version)
        #expect(try await client.renameLibraryNarrator(libraryID: "lib", currentName: "Old", newName: "  Existing \n").updated == 0)
        #expect(try await client.removeLibraryNarrator(libraryID: "lib", name: "Old").updated == 0)
    }
    @Test(arguments: ["a", "ab", "???", "~~~", "é?", "中文 🎧", "% / + =", "\u{ffff}"])
    func narratorIdentifiersEncodeBase64Once(name: String) async throws {
        let encoded = LibraryNarratorPolicy.identifier(for: name)
        #expect(encoded.removingPercentEncoding == Data(name.utf8).base64EncodedString())
        #expect(!encoded.contains("%25"))
        NarratorHTTP.state.install { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
            #expect(path == "/base/api/libraries/lib/narrators/" + encoded)
            let component = String(path.split(separator: "/").last!)
            #expect(Data(base64Encoded: component.removingPercentEncoding!) == Data(name.utf8))
            return (200, Data(#"{"updated":2}"#.utf8))
        }
        let client = await narratorClient(version: "2.37.1")
        #expect(try await client.renameLibraryNarrator(libraryID: "lib", currentName: name, newName: "new").updated == 2)
        #expect(try await client.removeLibraryNarrator(libraryID: "lib", name: name).updated == 2)
    }
    @Test func emptyAndUnchangedNamesDoNotSendWrites() async throws {
        NarratorHTTP.state.install { _ in Issue.record("Invalid/no-op write reached HTTP"); return (200, Data(#"{"updated":1}"#.utf8)) }
        let client = await narratorClient(version: "2.37.1")
        #expect(try await client.renameLibraryNarrator(libraryID: "lib", currentName: "a", newName: " a \n").updated == 0)
        await #expect(throws: LibraryNarratorError.emptyName) { try await client.renameLibraryNarrator(libraryID: "lib", currentName: "a", newName: " \n") }
        await #expect(throws: LibraryNarratorError.emptyName) { try await client.removeLibraryNarrator(libraryID: "lib", name: "") }
        await #expect(throws: ABSError.invalidResourcePath) { try await client.libraryNarrators(libraryID: "") }
        await #expect(throws: ABSError.invalidResourcePath) { try await client.removeLibraryNarrator(libraryID: "", name: "a") }
        #expect(NarratorHTTP.state.count() == 0)
    }
    @Test(arguments: [401, 403, 503])
    func unsafeWritesNeverReplayAfterFailure(status: Int) async throws {
        NarratorHTTP.state.install { request in
            if request.url?.path == "/base/auth/refresh" {
                return (200, Data(#"{"user":{"id":"fixture-user","username":"fixture","isActive":true,"accessToken":"fresh-synthetic","refreshToken":"fresh-refresh"}}"#.utf8))
            }
            return (status, Data("synthetic failure".utf8))
        }
        let client = await narratorClient(version: "2.37.1")
        do { _ = try await client.renameLibraryNarrator(libraryID: "lib", currentName: "a", newName: "b"); Issue.record("Expected failure") }
        catch { #expect(NarratorHTTP.state.count("PATCH") == 1) }
        do { _ = try await client.removeLibraryNarrator(libraryID: "lib", name: "a"); Issue.record("Expected failure") }
        catch { #expect(NarratorHTTP.state.count("DELETE") == 1) }
    }
    @Test(arguments: ["{}", #"{"narrators":null}"#, #"{"narrators":[{"id":"a","name":"a","numBooks":"2"}]}"#, #"{"narrators":[{"id":"a","name":"a","numBooks":-1}]}"#])
    func malformedDirectoryCannotMasqueradeAsEmpty(json: String) async throws {
        NarratorHTTP.state.install { _ in (200, Data(json.utf8)) }
        await #expect(throws: (any Error).self) { try await narratorClient(version: "2.37.1").libraryNarrators(libraryID: "lib") }
    }
    @Test func retiredClientDoesNotSendNarratorRequests() async throws {
        NarratorHTTP.state.install { _ in Issue.record("Retired client sent HTTP"); return (200, Data(#"{"updated":1}"#.utf8)) }
        let client = await narratorClient(version: "2.37.1"); await client.retireForServerRestore()
        await #expect(throws: ABSError.sessionChanged) { try await client.removeLibraryNarrator(libraryID: "lib", name: "a") }
        await #expect(throws: ABSError.sessionChanged) { try await client.renameLibraryNarrator(libraryID: "lib", currentName: "a", newName: "a") }
        await #expect(throws: ABSError.sessionChanged) { try await client.libraryNarrators(libraryID: "lib") }
        #expect(NarratorHTTP.state.count() == 0)
    }
    @Test func alreadyCancelledWriteDoesNotSendHTTP() async throws {
        NarratorHTTP.state.install { _ in Issue.record("Cancelled write sent HTTP"); return (200, Data(#"{"updated":1}"#.utf8)) }
        let client = await narratorClient(version: "2.37.1")
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await client.removeLibraryNarrator(libraryID: "lib", name: "a") }
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        #expect(NarratorHTTP.state.count() == 0)
    }
}
