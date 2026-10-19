import Foundation
import Testing
@testable import AudilseCore

struct TaxonomyEndpointTests {
    @Test(arguments: ["tags", "genres"])
    func canonicalTaxonomyBase64RemainsOneComponent(route: String) throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/proxy/abs")))
        let identifier = ServerEndpoint.component(Data("ÿÿ".utf8).base64EncodedString())
        #expect(identifier.contains("%2F"))
        for path in ["api/\(route)/\(identifier)", "/proxy/abs/api/\(route)/\(identifier)",
                     "https://example.test/proxy/abs/api/\(route)/\(identifier)"] {
            let url = try endpoint.url(path: path)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/proxy/abs/api/\(route)/\(identifier)")
        }
    }

    @Test(arguments: ["api/tags/w7%2fDvw%3D%3D", "api/genres/w7%252FDvw%3D%3D",
                      "api/tags/w7%2FDvw%3D%3D/extra", "api/tags/extra/w7%2FDvw%3D%3D",
                      "api/items/w7%2FDvw%3D%3D", "api/tags/%2F", "api/genres/%2F%2F8%3D",
                      "api/tags/w7%2FDvw%3D", "api/genres/w7%2FDvw%3D%3D%3D",
                      "api/tags/%252e%252e%252fsecret", "api/genres/%5C", "api/%2e%2e/tags/w7%2FDvw%3D%3D"])
    func taxonomyExceptionRejectsEncodedTraversalAndNoncanonicalNames(path: String) throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs")))
        #expect(throws: ABSError.invalidResourcePath) { try endpoint.url(path: path) }
    }

    @Test func taxonomyExceptionPreservesOriginAndProxyRestrictions() throws {
        let endpoint = try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs")))
        for path in ["https://evil.test/abs/api/tags/w7%2FDvw%3D%3D",
                     "https://example.test/other/api/genres/w7%2FDvw%3D%3D",
                     "http://example.test/abs/api/tags/w7%2FDvw%3D%3D"] {
            #expect(throws: ABSError.untrustedResource) { try endpoint.url(path: path) }
        }
        #expect(throws: ABSError.invalidServerURL) { try ServerEndpoint(baseURL: #require(URL(string: "https://example.test/abs/w7%2FDvw%3D%3D"))) }
    }
}
