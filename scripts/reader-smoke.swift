import AppKit
import WebKit
import Foundation

@MainActor final class ReaderHarness: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let format = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "epub"
    let initialLocation = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : ""
    var firstLocation: String?
    var searchPassed = false
    var ready = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "reader")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Audilse Reader Verification"
        window.contentView = web
        window.orderFront(nil)
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("FAIL: reader timeout"); fflush(stdout); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            if format == "azw3" {
                // Assert the fixture reaches the KF8 parser, rather than renamed MOBI6.
                guard data.count > 86 else { throw CocoaError(.fileReadCorruptFile) }
                let recordOffset = data[78..<82].reduce(0) { ($0 << 8) | Int($1) }
                guard data.count > recordOffset + 40,
                      data[(recordOffset + 36)..<(recordOffset + 40)].reduce(0, { ($0 << 8) | Int($1) }) == 8 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                print("KF8 version 8 header verified")
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: [data.base64EncodedString(), format, initialLocation, ["fontSize": 20, "fontFamily": "serif", "theme": "paper"]]), as: UTF8.self)
            webView.evaluateJavaScript("void ShelfReader.open.apply(ShelfReader,\(json))") { _, error in if let error { print("FAIL JS:", error); fflush(stdout); exit(1) } }
        } catch { print("FAIL:", error); exit(1) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "error" { print("FAIL bridge:", body["value"] ?? "unknown"); fflush(stdout); exit(1) }
        if type == "ready" { ready = true; print("ready") }
        if type == "toc" { print("toc", (body["value"] as? [Any])?.count ?? 0) }
        if type == "location", let value = body["value"] as? [String: Any], let location = value["location"] as? String {
            print("location", location, "percentage", value["progress"] ?? 0)
            if firstLocation == nil {
                if !initialLocation.isEmpty, location != initialLocation { print("FAIL position restore:", location); fflush(stdout); exit(1) }
                firstLocation = location
                web.evaluateJavaScript("void ShelfReader.search('needle')")
            } else if searchPassed && location != firstLocation {
                if CommandLine.arguments.count > 5 {
                    do { try location.write(toFile: CommandLine.arguments[5], atomically: true, encoding: .utf8) }
                    catch { print("FAIL saving fixture position"); fflush(stdout); exit(1) }
                }
                print("PASS \(format.uppercased()): local engine, search, supplied position restore and navigation"); fflush(stdout); exit(0)
            }
        }
        if type == "search", let results = body["value"] as? [Any] {
            guard ready, !results.isEmpty else { print("FAIL empty search"); fflush(stdout); exit(1) }
            searchPassed = true
            print("search", results.count)
            web.evaluateJavaScript("void ShelfReader.next()")
        }
        fflush(stdout)
    }
}
@main struct Main {
    static func main() {
        let application = NSApplication.shared
        let delegate = ReaderHarness()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
