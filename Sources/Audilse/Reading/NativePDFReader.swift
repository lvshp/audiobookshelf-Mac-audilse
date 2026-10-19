import AppKit
import PDFKit
import SwiftUI
import AudilseCore

struct NativePDFReader: NSViewRepresentable {
    @Bindable var model: ReaderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = model.pdfDocument
        model.pdfView = view
        if let page = view.document?.page(at: model.page - 1) { view.go(to: page) }
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.backgroundColor = model.theme == "dark" ? .darkGray : .windowBackgroundColor
    }
    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }
    @MainActor final class Coordinator: NSObject {
        weak var model: ReaderModel?
        var observer: NSObjectProtocol?
        init(model: ReaderModel) { self.model = model }
        @MainActor func observe(_ view: PDFView) {
            stopObserving()
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let model = self.model, let view, let page = view.currentPage, let document = view.document else { return }
                    let number = document.index(for: page) + 1
                    model.page = number
                    model.moved(location: String(number), progress: ReadingCheckpoint.pageProgress(page: number, count: document.pageCount))
                }
            }
        }
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
