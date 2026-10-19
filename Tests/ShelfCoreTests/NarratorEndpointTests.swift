import Foundation
import Testing
@testable import ShelfCore

struct NarratorEndpointTests {
    @Test(arguments: ["???", "é?", "\u{FFFF}", "中文 🎧"])
    func canonicalNarratorIdentifiersStayOneURLComponent(name: String) throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/proxy/abs")))
        let identifier = ServerEndpoint.component(Data(name.utf8).base64EncodedString())
        for path in ["api/libraries/library/narrators/\(identifier)",
                     "/proxy/abs/api/libraries/library/narrators/\(identifier)",
                     "https://example.test/proxy/abs/api/libraries/library/narrators/\(identifier)"] {
            let url = try endpoint.url(path: path)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.percentEncodedPath == "/proxy/abs/api/libraries/library/narrators/\(identifier)")
            #expect(components.percentEncodedPath.split(separator: "/").count == 7)
        }
    }

    @Test(arguments: ["api/items/item/Pz8%2F", "api/libraries/library/authors/Pz8%2F",
                      "api/libraries/library/narrators/%2F", "api/libraries/library/narrators/Pz8%252F",
                      "api/libraries/library/narrators/Pz8%2f", "api/libraries/library/narrators/%252e%252e%252fsecret",
                      "api/libraries/%2F/narrators/Pz8%2F", "api/libraries/library/narrators/%2e%2e%2fsecret",
                      "api/libraries/library/narrators/%5C", "api/libraries/library/narrators/%2F%2F8%3D"])
    func encodedTraversalRemainsRejected(path: String) throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs")))
        #expect(throws: ABSError.invalidResourcePath) { try endpoint.url(path: path) }
    }

    @Test func narratorExceptionNeverAllowsAnotherOriginOrProxyPrefix() throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs")))
        for path in ["https://evil.test/abs/api/libraries/library/narrators/Pz8%2F",
                     "https://example.test/other/api/libraries/library/narrators/Pz8%2F",
                     "http://example.test/abs/api/libraries/library/narrators/Pz8%2F"] {
            #expect(throws: ABSError.untrustedResource) { try endpoint.url(path: path) }
        }
        #expect(throws: ABSError.invalidServerURL) { try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs/Pz8%2F"))) }
    }
}
