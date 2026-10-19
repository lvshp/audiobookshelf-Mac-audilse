import AppKit
import ShelfCore
import SwiftUI
import WebKit

struct LocalTextReader: NSViewRepresentable {
    @Bindable var model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "reader")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        model.webView = view
        #if SWIFT_PACKAGE
        let readerURL = Bundle.module.url(forResource: "reader", withExtension: "html")
        #else
        let readerURL = Bundle.main.url(forResource: "reader", withExtension: "html", subdirectory: "Reader")
        #endif
        if let url = readerURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { model.error = L10n.tr("本地阅读组件未正确打包。"); model.isLoading = false }
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var model: ReaderModel?
        init(model: ReaderModel) { self.model = model }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let model, let url = model.fileURL, let format = model.format else { return }
            Task {
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                    guard data.count < 256 * 1024 * 1024 else { throw ReadingError.oversizedArchive }
                    let options: [String: Any] = ["fontSize": model.fontSize, "fontFamily": model.fontFamily, "theme": model.theme]
                    let args: [Any] = [data.base64EncodedString(), format.rawValue, model.location, options]
                    let encoded = try JSONSerialization.data(withJSONObject: args)
                    let json = String(decoding: encoded, as: UTF8.self)
                    _ = try await webView.evaluateJavaScript("void ShelfReader.open.apply(ShelfReader,\(json))")
                } catch { model.error = L10n.error(error); model.isLoading = false }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if ["file", "blob", "about"].contains(url.scheme ?? "") { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { model?.error = L10n.error(error); model?.isLoading = false }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let model, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": model.isLoading = false
            case "progressPending": model.isCalculatingProgress = body["value"] as? Bool ?? false
            case "error": model.error = body["value"] as? String ?? L10n.tr("阅读组件发生错误。"); model.isLoading = false
            case "location":
                if let value = body["value"] as? [String: Any], let location = value["location"] as? String {
                    model.moved(location: location, progress: value["progress"] as? Double ?? model.progress)
                }
            case "toc", "search":
                let entries = (body["value"] as? [[String: Any]] ?? []).compactMap { value -> ReaderEntry? in
                    guard let id = value["id"] as? String, let title = value["title"] as? String else { return nil }
                    return ReaderEntry(id: id, title: title.isEmpty ? L10n.tr("章节") : title, depth: value["depth"] as? Int ?? 0)
                }
                if type == "toc" { model.toc = entries } else { model.searchResults = entries; model.isSearching = false }
            default: break
            }
        }
    }
}
