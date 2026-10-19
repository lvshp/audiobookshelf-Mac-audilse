import SwiftUI
import AudilseCore

struct ReaderView: View {
    let store: AppStore
    let item: AudilseCore.LibraryItem
    let fileIno: String?
    @State private var model = ReaderModel()
    @State private var readingPartition: AccountPartition?
    @State private var activityID = UUID()
    @GestureState private var comicMagnification = 1.0
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, item: AudilseCore.LibraryItem, fileIno: String? = nil) {
        self.store = store; self.item = item; self.fileIno = fileIno
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.showContents {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.hasSearched ? L10n.tr("搜索结果") : L10n.tr("目录")).font(.headline)
                        Spacer()
                        if model.hasSearched {
                            Button(L10n.tr("清除搜索")) { model.clearSearch() }
                                .buttonStyle(.borderless).disabled(model.isSearching)
                        }
                    }.padding(.horizontal)
                    if model.isSearching { ProgressView().frame(maxWidth: .infinity) }
                    if model.hasSearched && !model.isSearching && model.searchResults.isEmpty && model.error == nil {
                        Text(L10n.tr("没有搜索结果")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        Spacer()
                    } else {
                        List(model.hasSearched ? model.searchResults : model.toc) { entry in
                            Button { model.go(entry, searchResult: model.hasSearched) } label: {
                                Text(entry.title).lineLimit(3).padding(.leading, CGFloat(entry.depth) * 10).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }.listStyle(.sidebar)
                    }
                }.padding(.top, 16).frame(width: 260)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let closeError = model.closeError {
                    Label(closeError, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                ZStack {
                    background
                    if model.format == .pdf, model.pdfDocument != nil { NativePDFReader(model: model) }
                    else if model.format?.isComic == true, !model.comicPages.isEmpty {
                        GeometryReader { geometry in
                            ScrollView([.horizontal, .vertical]) {
                                if let image = NSImage(contentsOf: model.comicPages[max(0, min(model.page - 1, model.comicPages.count - 1))]) {
                                    Image(nsImage: image).resizable().scaledToFit()
                                        .frame(width: min(1100, max(1, geometry.size.width - 48)) * min(3, max(0.5, model.comicScale * comicMagnification)))
                                        .padding(24).frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                                        .gesture(MagnifyGesture().updating($comicMagnification) { value, state, _ in
                                            state = value.magnification
                                        }.onEnded { value in model.setComicScale(model.comicScale * value.magnification) })
                                } else { ContentUnavailableView(L10n.tr("无法显示图片"), systemImage: "photo.badge.exclamationmark") }
                            }
                        }
                    } else if model.fileURL != nil, [.epub, .mobi, .azw3].contains(model.format) { LocalTextReader(model: model) }
                    if model.isLoading { ProgressView(L10n.tr("正在打开书籍…")).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
                    if let error = model.error { readerError(error) }
                }
                Divider()
                HStack {
                    Button { model.previous() } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                    if model.pageCount > 0 {
                        Text("\(model.page) / \(model.pageCount)").monospacedDigit().frame(minWidth: 90)
                    } else if model.isCalculatingProgress {
                        Text(L10n.tr("正在计算进度…"))
                    } else { Text("\(Int(model.progress * 100))%").monospacedDigit().frame(minWidth: 70) }
                    Button { model.next() } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                    Spacer()
                    if let notice = model.syncNotice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 780, idealWidth: 1080, minHeight: 620, idealHeight: 780)
        .interactiveDismissDisabled()
        .onExitCommand(perform: requestClose)
        .task {
            readingPartition = store.partition
            store.readingActivityID = activityID
            store.readingIsActive = true
            let reader = model
            store.readingShutdown = { [reader] in try await reader.shutdown() }
            await model.open(store: store, item: item, fileIno: fileIno)
        }
        .onDisappear {
            Task {
                let saved = await model.close()
                if saved, store.partition == readingPartition, store.readingActivityID == activityID {
                    store.readingIsActive = false
                    store.readingActivityID = nil
                    store.readingShutdown = nil
                }
            }
        }
        .onChange(of: store.partition) { _, _ in Task { if await model.close(synchronize: false) { dismiss() } } }
        .onChange(of: store.client.map(ObjectIdentifier.init)) { _, _ in Task { if await model.close(synchronize: false) { dismiss() } } }
        .onChange(of: store.accountOperationID) { _, _ in Task { if await model.close(synchronize: false) { dismiss() } } }
        .alert(L10n.tr("阅读位置发生冲突"), isPresented: Binding(get: { model.conflict != nil }, set: { _ in })) {
            Button(L10n.tr("保留本机位置")) { Task { await model.resolve(useLocal: true) } }
            Button(L10n.tr("使用服务器位置")) { Task { await model.resolve(useLocal: false) } }
        } message: {
            Text(L10n.tr("本机和其他设备都更新了阅读位置。请选择接下来使用的位置；音频进度将保留。"))
        }
    }

    private func requestClose() { Task { if await model.close() { dismiss() } } }

    private func readerError(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed").font(.system(size: 44))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L10n.tr("无法打开阅读器")).font(.title2.bold())
            Text(message).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var background: Color {
        model.theme == "dark" ? Color(red: 0.12, green: 0.13, blue: 0.14) : model.theme == "sepia" ? Color(red: 0.94, green: 0.89, blue: 0.79) : Color(red: 0.98, green: 0.97, blue: 0.95)
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            SheetCloseButton(label: L10n.tr("关闭阅读器"), identifier: "reader.close", action: requestClose).disabled(model.isClosing)
            Button { model.showContents.toggle() } label: { Image(systemName: "sidebar.left") }.help(L10n.tr("目录"))
            Text(model.title.isEmpty ? item.title : model.title).font(.headline).lineLimit(1)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("搜索书中内容"), text: $model.search).textFieldStyle(.plain).frame(width: 150).onSubmit { model.find() }.disabled(!model.canSearch)
            }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            if model.format?.isComic == true {
                HStack(spacing: 8) {
                    Button { model.zoomComic(by: -0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help(L10n.tr("缩小")).disabled(!model.canZoomComicOut || model.isClosing)
                    Button { model.setComicScale(1) } label: { Text("\(Int((model.comicScale * 100).rounded()))%").monospacedDigit() }
                        .help(L10n.tr("适合宽度")).disabled(model.isClosing)
                    Button { model.zoomComic(by: 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help(L10n.tr("放大")).disabled(!model.canZoomComicIn || model.isClosing)
                }.accessibilityElement(children: .contain).accessibilityLabel(L10n.tr("漫画缩放"))
            }
            Menu {
                Picker(L10n.tr("主题"), selection: $model.theme) { Text(L10n.tr("纸白")).tag("paper"); Text(L10n.tr("暖棕")).tag("sepia"); Text(L10n.tr("深色")).tag("dark") }
                if model.format == .epub || model.format == .mobi || model.format == .azw3 {
                    Picker(L10n.tr("字体"), selection: $model.fontFamily) { Text(L10n.tr("衬线")).tag("serif"); Text(L10n.tr("无衬线")).tag("sans-serif") }
                    Picker(L10n.tr("字号"), selection: $model.fontSize) {
                        ForEach(Array(Set(Array(stride(from: 12, through: 36, by: 2)) + [model.fontSize])).sorted(), id: \.self) { size in
                            Text(String(size)).tag(size)
                        }
                    }.pickerStyle(.menu)
                }
            } label: { Image(systemName: "textformat.size") }.help(L10n.tr("阅读设置"))
        }.buttonStyle(.borderless).padding(16)
        .onChange(of: model.theme) { _, _ in model.settingsChanged() }
        .onChange(of: model.fontSize) { _, _ in model.settingsChanged() }
        .onChange(of: model.fontFamily) { _, _ in model.settingsChanged() }
    }
}
