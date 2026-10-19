import SwiftUI
import AudilseCore
import UniformTypeIdentifiers

struct ContentManagementView: View {
    let store: AppStore
    let item: AudilseCore.LibraryItem
    @State private var model = ContentManagementModel()
    @State private var tab = 0
    @State private var confirmation: ManagementConfirmation?
    @State private var importingCover = false
    @State private var selectedReader: SelectedReaderTarget?
    @State private var fileActionSource: ItemFileActionSource?
    @State private var diagnosticPage = 0
    @State private var ebookPage = 0
    @State private var metadataPage = 0
    @State private var attachmentPage = 0
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, item: AudilseCore.LibraryItem) {
        self.store = store; self.item = item
        _fileActionSource = State(initialValue: ItemFileActionSource(store: store, item: item))
    }

    private var canUpdate: Bool { model.operation.allows(.updateContent) && !model.operation.isBusy }
    private var canDelete: Bool { model.operation.allows(.deleteContent) && !model.operation.isBusy }
    private var canSetCover: Bool { canUpdate && model.operation.allows(.upload) }
    private var canUseTools: Bool { model.operation.allows(.manageServer) && !model.operation.isBusy }
    private var fileItem: AudilseCore.LibraryItem {
        if let loaded = model.item, loaded.id == item.id, loaded.libraryId == item.libraryId { return loaded }
        return item
    }
    private var fileActionSourceIsCurrent: Bool { fileActionSource?.isCurrent(store, item: fileItem) == true }
    private var diagnosticFiles: [MediaFile] { model.item?.media.audioFiles ?? [] }
    private var ebookFileRows: [ManagedLibraryFile] { model.libraryFiles.filter(\.isEBook) }
    private var metadataFileRows: [ManagedLibraryFile] { model.libraryFiles.filter(\.isMetadataSidecar) }
    private var attachmentFileRows: [ManagedLibraryFile] {
        let audioInodes = Set(diagnosticFiles.map(\.ino) + (model.item?.media.episodes.compactMap { $0.audioFile?.ino } ?? []))
        return model.libraryFiles.filter { !$0.isEBook && !$0.isMetadataSidecar && !audioInodes.contains($0.ino) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.tint)
                Text(fileItem.title).font(.title2.bold()).lineLimit(1)
                Spacer()
                if model.operation.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.operation.isBusy)
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ManagementNotice(operation: model.operation)
            TabView(selection: $tab) {
                metadata.tabItem { Label(L10n.tr("元数据"), systemImage: "text.alignleft") }.tag(0)
                matching.tabItem { Label(L10n.tr("匹配"), systemImage: "magnifyingglass") }.tag(1)
                covers.tabItem { Label(L10n.tr("封面"), systemImage: "photo") }.tag(2)
                tracks.tabItem { Label(L10n.tr("音轨"), systemImage: "waveform") }.tag(3)
                chapters.tabItem { Label(L10n.tr("章节"), systemImage: "list.bullet") }.tag(4)
                tools.tabItem { Label(L10n.tr("文件与工具"), systemImage: "wrench.and.screwdriver") }.tag(5)
            }.padding(16)
        }.frame(minWidth: 850, idealWidth: 1050, minHeight: 650, idealHeight: 820)
        .task { await model.open(store: store, item: item) }
        .onDisappear { model.cancel() }
        .onChange(of: store.partition) { _, _ in model.cancel(); dismiss() }
        .onChange(of: fileActionSourceIsCurrent) { _, isCurrent in if !isCurrent { selectedReader = nil } }
        .onChange(of: model.libraryFiles) { _, _ in ebookPage = 0; metadataPage = 0; attachmentPage = 0 }
        .onChange(of: diagnosticFiles) { _, _ in diagnosticPage = 0 }
        .sheet(item: $selectedReader) { target in SelectedReaderSheet(store: store, target: target) }
        .alert(confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) { Task { await confirmation.operation() }; self.confirmation = nil }
                Button(L10n.tr("取消"), role: .cancel) { self.confirmation = nil }
            }
        } message: { Text(confirmation?.message ?? "") }
        .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image]) { result in
            switch result { case .success(let url): Task { await model.uploadCover(url) }; case .failure(let error): model.operation.error = L10n.error(error) }
        }
    }
    private var metadata: some View {
        Form {
            FormInputRow(L10n.tr("标题")) { TextField("", text: $model.title).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("标题")) }
            FormInputRow(L10n.tr("副标题")) { TextField("", text: $model.subtitle).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("副标题")) }
            LabeledContent(L10n.tr("作者（每行一位）")) { LeadingTextEditor(text: $model.authors).frame(height: 72) }
            if model.item?.mediaType == "book" { seriesEditor }
            LabeledContent(L10n.tr("演播者（每行一位）")) { LeadingTextEditor(text: $model.narrators).frame(height: 72) }
            VStack(alignment: .leading, spacing: 8) { FormInputRow(L10n.tr("出版年份")) { TextField("", text: $model.publishedYear).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("出版年份")) }; FormInputRow(L10n.tr("出版日期")) { TextField("", text: $model.publishedDate).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("出版日期")) } }
            VStack(alignment: .leading, spacing: 8) { FormInputRow(L10n.tr("出版社")) { TextField("", text: $model.publisher).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("出版社")) }; MetadataLanguagePicker(selection: $model.language) }
            if model.item?.mediaType == "podcast" { PodcastTypePicker(selection: $model.podcastType).disabled(!canUpdate) }
            VStack(alignment: .leading, spacing: 8) { FormInputRow("ISBN") { TextField("", text: $model.isbn).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel("ISBN") }; FormInputRow("ASIN") { TextField("", text: $model.asin).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel("ASIN") } }
            LabeledContent(L10n.tr("分类（每行一个）")) { LeadingTextEditor(text: $model.genres).frame(height: 64) }
            LabeledContent(L10n.tr("标签（每行一个）")) { LeadingTextEditor(text: $model.tags).frame(height: 64) }
            LabeledContent(L10n.tr("简介")) { LeadingTextEditor(text: $model.description).frame(minHeight: 100) }
            HStack { Toggle(L10n.tr("包含成人内容"), isOn: $model.explicit); Toggle(L10n.tr("删节版"), isOn: $model.abridged) }
            Button(L10n.tr("保存信息")) { Task { await model.saveMetadata() } }.buttonStyle(.borderedProminent).disabled(!canUpdate)
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    private var seriesEditor: some View {
        Section(L10n.tr("系列关系")) {
            ForEach(model.series) { series in
                VStack(alignment: .leading, spacing: 8) {
                    FormInputRow(L10n.tr("系列名称")) { TextField("", text: seriesBinding(series, \.name)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("系列名称")) }
                    FormInputRow(L10n.tr("卷序（可空、小数或文字）")) { TextField("", text: seriesBinding(series, \.sequence)).frame(maxWidth: 210).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("卷序（可空、小数或文字）")) }
                    Button(role: .destructive) { model.series.removeAll { $0.id == series.id } } label: { Image(systemName: "minus.circle") }.disabled(!canUpdate)
                }
            }
            Button(L10n.tr("添加系列")) { model.series.append(.init(name: "", sequence: "")) }.disabled(!canUpdate)
            Text(L10n.tr("移除关系不会删除该系列的其他作品。卷序留空表示未指定。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func seriesBinding(_ draft: SeriesDraft, _ keyPath: WritableKeyPath<SeriesDraft, String>) -> Binding<String> {
        Binding(get: { model.series.first { $0.id == draft.id }?[keyPath: keyPath] ?? draft[keyPath: keyPath] }, set: { value in
            guard let index = model.series.firstIndex(where: { $0.id == draft.id }) else { return }
            model.series[index][keyPath: keyPath] = value
        })
    }
    private var matching: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { SettingsChoicePicker(title: L10n.tr("来源"), selection: $model.provider, choices: model.providers.map { .init($0.value, $0.text, localizesLabel: false) }).frame(maxWidth: 240); TextField(L10n.tr("标题"), text: $model.title); TextField(L10n.tr("作者"), text: $model.authors); Button(L10n.tr("搜索")) { Task { await model.searchMetadata() } }.disabled(model.operation.isBusy) }
            HStack { Toggle(L10n.tr("覆盖已有信息"), isOn: $model.overrideDetails); Toggle(L10n.tr("覆盖封面"), isOn: $model.overrideCover); Spacer(); Button(L10n.tr("自动匹配并保存")) { confirmation = .init(title: L10n.tr("匹配并更新内容？"), message: model.overrideDetails ? L10n.tr("匹配结果将覆盖现有内容信息。") : L10n.tr("服务器将补充匹配到的信息。"), operation: { await model.quickMatch() }) }.disabled(!canUpdate) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.metadataResults.enumerated()), id: \.offset) { _, result in
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(result.title ?? L10n.tr("未命名结果")).font(.headline); Text([result.author, result.publisher, result.publishedYear].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary); if let text = result.description { Text(text).font(.caption).lineLimit(3) } }
                    Spacer()
                    Button(L10n.tr("载入表单")) { model.previewMetadata(result); tab = 0 }
                }.padding(.vertical, 8)
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }.overlay { if model.metadataResults.isEmpty { ContentUnavailableView(L10n.tr("搜索内容信息"), systemImage: "magnifyingglass", description: Text(L10n.tr("先预览候选信息，再保存所需字段。"))) } }
        }.textFieldStyle(.shelfLeading)
    }
    private var covers: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { TextField(L10n.tr("远程图片地址"), text: $model.coverURL); Button(L10n.tr("设置封面")) { Task { await model.setCover() } }.disabled(!canSetCover || model.coverURL.isEmpty) }
            HStack { TextField(L10n.tr("服务器已有封面文件路径"), text: $model.serverCoverPath); Button(L10n.tr("选择服务器图片")) { Task { await model.selectCover() } }.disabled(!canUpdate || model.serverCoverPath.isEmpty) }
            HStack {
                Button(L10n.tr("上传本机图片…")) { importingCover = true }.disabled(!canSetCover)
                Button(L10n.tr("移除封面"), role: .destructive) { confirmation = .init(title: L10n.tr("移除此内容的封面？"), message: L10n.tr("可以之后重新上传或匹配封面。"), destructive: true, operation: { await model.deleteCover() }) }.disabled(!canDelete)
                Spacer()
                SettingsChoicePicker(title: L10n.tr("搜索来源"), selection: $model.coverProvider, choices: model.coverProviders.map { .init($0.value, $0.text, localizesLabel: false) }).frame(width: 190)
                Button(L10n.tr("搜索封面")) { Task { await model.searchCovers() } }.disabled(model.operation.isBusy)
            }
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) { ForEach(model.coverResults, id: \.self) { url in
                VStack { AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }.frame(height: 190); Button(L10n.tr("使用此封面")) { Task { await model.setCover(url: url) } }.disabled(!canSetCover) }
            } } }
        }.textFieldStyle(.shelfLeading)
    }
    private var tracks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("调整完整音轨列表的播放顺序，排除的文件仍保留在服务器。")).font(.caption).foregroundStyle(.secondary)
            List(Array(model.orderedFiles.enumerated()), id: \.element.id) { index, track in
                HStack {
                    Text("\(index + 1)").monospacedDigit().frame(width: 30)
                    Text(model.item?.media.audioFiles.first { $0.ino == track.ino }?.metadata.filename ?? track.ino)
                    Spacer()
                    if let file = model.item?.media.audioFiles.first(where: { $0.ino == track.ino }) {
                        originalFileActions(file)
                    }
                    Toggle(L10n.tr("排除"), isOn: Binding(get: { model.orderedFiles.first { $0.ino == track.ino }?.exclude ?? false }, set: { value in if let i = model.orderedFiles.firstIndex(where: { $0.ino == track.ino }) { model.orderedFiles[i].exclude = value } })).toggleStyle(.checkbox)
                    Button { if let i = model.orderedFiles.firstIndex(where: { $0.ino == track.ino }) { model.moveTrack(i, by: -1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { if let i = model.orderedFiles.firstIndex(where: { $0.ino == track.ino }) { model.moveTrack(i, by: 1) } } label: { Image(systemName: "arrow.down") }.disabled(index == model.orderedFiles.count - 1)
                }.padding(.vertical, 6)
            }
            HStack { Spacer(); Button(L10n.tr("保存音轨顺序")) { confirmation = .init(title: L10n.tr("更新播放顺序？"), message: L10n.tr("这会改变其他设备后续播放使用的音轨顺序。"), operation: { await model.saveTracks() }) }.buttonStyle(.borderedProminent).disabled(!canUpdate || model.orderedFiles.isEmpty) }
        }
    }
    private var chapters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TextField("Audible ASIN", text: $model.asin).frame(width: 220); Button(L10n.tr("查找章节")) { Task { await model.findChapters() } }.disabled(model.asin.isEmpty || model.operation.isBusy); Spacer(); Button(L10n.tr("添加章节")) { model.chapters.append(.init(title: L10n.tr("新章节"), start: model.chapters.last?.end ?? 0, end: (model.chapters.last?.end ?? 0) + 60)) }.disabled(!canUpdate) }
            HStack { Text(L10n.tr("标题")).frame(maxWidth: .infinity, alignment: .leading); Text(L10n.tr("开始（秒）")).frame(width: 100); Text(L10n.tr("结束（秒）")).frame(width: 100); Spacer().frame(width: 30) }.font(.caption).foregroundStyle(.secondary)
            List { ForEach(model.chapters) { chapter in
                HStack { TextField(L10n.tr("章节标题"), text: chapterField(chapter, \.title)); TextField(L10n.tr("开始"), value: chapterField(chapter, \.start), format: .number).frame(width: 100); TextField(L10n.tr("结束"), value: chapterField(chapter, \.end), format: .number).frame(width: 100); Button { model.chapters.removeAll { $0.id == chapter.id } } label: { Image(systemName: "minus.circle") }.disabled(!canUpdate) }
            } }
            HStack { Text(L10n.tr("章节按开始时间排列；保存前请确认起止时间。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("保存章节")) { confirmation = .init(title: L10n.tr("替换服务器章节？"), message: L10n.tr("当前章节列表将替换服务器中已有的章节。"), operation: { await model.saveChapters() }) }.buttonStyle(.borderedProminent).disabled(!canUpdate) }
        }.textFieldStyle(.shelfLeading)
    }
    private func chapterField<Value>(_ chapter: ChapterDraft, _ key: WritableKeyPath<ChapterDraft, Value>) -> Binding<Value> {
        Binding(get: { model.chapters.first { $0.id == chapter.id }?[keyPath: key] ?? chapter[keyPath: key] }, set: { value in
            guard let index = model.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
            model.chapters[index][keyPath: key] = value
        })
    }
    private var tools: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox(L10n.tr("扫描与编码")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button(L10n.tr("重新扫描此内容")) { Task { await model.scan() } }.disabled(!canUpdate || !canUseTools)
                            VStack(alignment: .leading, spacing: 12) {
                                EditableSettingsChoicePicker(title: L10n.tr("编码"), selection: $model.codec, choices: ClientSettingsChoices.audioCodecs)
                                EditableSettingsChoicePicker(title: L10n.tr("码率"), selection: $model.bitrate, choices: ClientSettingsChoices.audioBitrates)
                                EditableSettingsChoicePicker(title: L10n.tr("声道"), selection: $model.channels, choices: ClientSettingsChoices.audioChannels)
                            }.textFieldStyle(.shelfLeading)
                            HStack { Button(L10n.tr("生成 M4B")) { confirmation = .init(title: L10n.tr("生成 M4B 文件？"), message: L10n.tr("服务器将执行音频转换任务，并可能调整该内容的文件。"), operation: { await model.encodeM4B() }) }.disabled(!canUseTools); Button(L10n.tr("取消编码")) { Task { await model.encodeM4B(cancel: true) } }.disabled(!canUseTools) }
                            Toggle(L10n.tr("嵌入前备份原文件"), isOn: $model.backupOriginals)
                            Toggle(L10n.tr("强制覆盖文件内章节"), isOn: $model.forceChapters)
                            Button(L10n.tr("将元数据嵌入音频文件")) { confirmation = .init(title: L10n.tr("写入音频原文件？"), message: L10n.tr("服务器会修改音频文件中的元数据。"), operation: { await model.embed() }) }.disabled(!canUseTools)
                            Button(L10n.tr("读取文件内元数据")) { Task { await model.inspectEmbedded() } }.disabled(model.operation.isBusy)
                        }.padding(8)
                    }
                    GroupBox(L10n.tr("文件诊断")) {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.item?.isMissing == true { Label(L10n.tr("内容文件缺失"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            if model.item?.isInvalid == true { Label(L10n.tr("内容被标记为无效"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            OriginalFilePagination(count: diagnosticFiles.count, page: $diagnosticPage)
                            ForEach(diagnosticFiles[ItemFileCatalog.pageRange(count: diagnosticFiles.count, page: diagnosticPage)]) { file in
                                HStack { VStack(alignment: .leading) { Text(file.metadata.filename).lineLimit(2); if let error = file.error { Text(error).font(.caption).foregroundStyle(.orange) } }; Spacer(); originalFileActions(file); Button(L10n.tr("检查")) { Task { await model.probe(file) } }.disabled(!canUseTools); Button(role: .destructive) { confirmation = .init(title: L10n.tr("永久删除服务器文件？"), message: file.metadata.filename + L10n.tr(" 将被删除，无法撤销。"), destructive: true, operation: { await model.deleteFile(file) }) } label: { Image(systemName: "trash") }.disabled(!canDelete) }
                            }
                            OriginalFilePagination(count: diagnosticFiles.count, page: $diagnosticPage)
                        }.padding(8)
                    }
                    ebookFiles
                    metadataFiles
                    attachmentFiles
                    GroupBox(L10n.tr("删除内容")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(L10n.tr("同时删除服务器原文件"), isOn: $model.deleteOriginalFiles)
                            Button(L10n.tr("删除此内容"), role: .destructive) { confirmation = .init(title: L10n.tr("删除此内容？"), message: model.deleteOriginalFiles ? L10n.tr("书库记录和原文件都将永久删除。") : L10n.tr("书库记录将删除，原文件会保留。"), destructive: true, operation: { if await model.deleteItem() { store.selectedItem = nil; dismiss(); await store.refresh() } }) }.disabled(!canDelete)
                        }.padding(8)
                    }
                }.padding(10)
            }.frame(minWidth: 400)
            ScrollView { Text(model.diagnostic.isEmpty ? L10n.tr("选择文件检查或读取嵌入元数据后，在这里查看诊断结果。") : model.diagnostic).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }.frame(minWidth: 300)
        }
    }
    private var ebookFiles: some View {
        GroupBox(L10n.tr("电子书文件")) {
            VStack(alignment: .leading, spacing: 10) {
                OriginalFilePagination(count: ebookFileRows.count, page: $ebookPage)
                ForEach(ebookFileRows[ItemFileCatalog.pageRange(count: ebookFileRows.count, page: ebookPage)]) { file in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.metadata.filename).lineLimit(2)
                            Text(file.isSupplementary == true ? L10n.tr("补充电子书") : L10n.tr("主电子书")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        originalFileActions(.init(ino: file.ino, metadata: file.metadata))
                        Button(file.isSupplementary == true ? L10n.tr("设为主电子书") : L10n.tr("设为补充")) {
                            confirmation = .init(title: L10n.tr("切换电子书用途？"), message: file.isSupplementary == true ? L10n.tr("此文件将成为主电子书；原主电子书会改为补充文件。") : L10n.tr("此文件将成为补充文件，当前主电子书将取消。"), operation: { await model.toggleEBook(file) })
                        }.disabled(!canUpdate)
                        Button(role: .destructive) { confirmFileDeletion(file) } label: { Image(systemName: "trash") }.disabled(!canDelete)
                    }
                }
                if ebookFileRows.isEmpty { Text(L10n.tr("没有电子书文件。")).foregroundStyle(.secondary) }
                OriginalFilePagination(count: ebookFileRows.count, page: $ebookPage)
            }.padding(8)
        }
    }
    private var metadataFiles: some View {
        GroupBox(L10n.tr("元数据侧车文件")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("删除后，下次扫描不会再读取这些文件中的元数据。原音频和电子书保留。")).font(.caption).foregroundStyle(.secondary)
                OriginalFilePagination(count: metadataFileRows.count, page: $metadataPage)
                ForEach(metadataFileRows[ItemFileCatalog.pageRange(count: metadataFileRows.count, page: metadataPage)]) { file in
                    HStack { Text(file.metadata.filename).lineLimit(2); Spacer(); originalFileActions(.init(ino: file.ino, metadata: file.metadata)); Button(L10n.tr("永久删除"), role: .destructive) { confirmFileDeletion(file) }.disabled(!canDelete) }
                }
                if metadataFileRows.isEmpty { Text(L10n.tr("没有 metadata.json、metadata.abs 或 OPF 文件。")).foregroundStyle(.secondary) }
                OriginalFilePagination(count: metadataFileRows.count, page: $metadataPage)
            }.padding(8)
        }
    }

    private var attachmentFiles: some View {
        GroupBox(L10n.tr("其他附件")) {
            VStack(alignment: .leading, spacing: 10) {
                OriginalFilePagination(count: attachmentFileRows.count, page: $attachmentPage)
                ForEach(attachmentFileRows[ItemFileCatalog.pageRange(count: attachmentFileRows.count, page: attachmentPage)]) { file in
                    HStack {
                        Text(file.metadata.filename).lineLimit(2)
                        Spacer()
                        originalFileActions(.init(ino: file.ino, metadata: file.metadata))
                        Button(L10n.tr("永久删除"), role: .destructive) { confirmFileDeletion(file) }.disabled(!canDelete)
                    }
                }
                if attachmentFileRows.isEmpty { Text(L10n.tr("没有其他附件。")).foregroundStyle(.secondary) }
                OriginalFilePagination(count: attachmentFileRows.count, page: $attachmentPage)
            }.padding(8)
        }
    }

    @ViewBuilder private func originalFileActions(_ file: MediaFile) -> some View {
        if fileActionSourceIsCurrent, !file.ino.isEmpty {
            if ItemFileCatalog.canRead(file) {
                Button(L10n.tr("阅读"), systemImage: "book") {
                    selectedReader = SelectedReaderTarget(store: store, item: fileItem, file: file, source: fileActionSource)
                }.buttonStyle(.borderless)
            }
            if store.canDownload {
                FileExportButton(store: store, itemID: fileItem.id, file: file).id(file)
            }
        }
    }
    private func confirmFileDeletion(_ file: ManagedLibraryFile) {
        confirmation = .init(title: L10n.tr("永久删除服务器文件？"), message: file.metadata.filename + L10n.tr(" 将从服务器磁盘删除，无法撤销。"), destructive: true, operation: { await model.deleteLibraryFile(file) })
    }
}

struct ManagementNotice: View {
    let operation: ManagementOperation
    var body: some View {
        VStack(spacing: 5) { if let error = operation.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }; if let notice = operation.notice { Text(notice).foregroundStyle(.secondary) } }.font(.callout).padding(operation.error == nil && operation.notice == nil ? 0 : 10)
    }
}
