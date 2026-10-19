import SwiftUI
import ShelfCore
import UniformTypeIdentifiers

struct LibraryManagementView: View {
    let store: AppStore
    let library: Library?
    @State private var model = LibraryManagementModel()
    @State private var confirmation: ManagementConfirmation?
    @State private var importingFiles = false
    @State private var selectedTab = 0
    @State private var statisticsTarget: LibraryStatisticsPresentation?
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, library: Library? = nil) {
        self.store = store; self.library = library
    }
    private var busy: Bool { model.operation.isBusy }
    private var canManage: Bool { model.operation.allows(.manageLibraries) && !busy }
    private var canUpdate: Bool { model.operation.allows(.updateContent) && !busy }
    private var canDelete: Bool { model.operation.allows(.deleteContent) && !busy }
    private var canUpload: Bool { model.operation.allows(.upload) && !busy }
    var body: some View {
        let statisticsSource = library.flatMap { LibraryStatisticsSource(store: store, library: $0) }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "books.vertical").font(.title2).foregroundStyle(.tint)
                Text(library == nil ? L10n.tr("书库组织") : (model.name.isEmpty ? library?.name ?? "" : model.name)).font(.title2.bold()).lineLimit(1)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if let library { Button(L10n.tr("书库统计"), systemImage: "chart.bar.xaxis") {
                    guard let statisticsSource, statisticsSource.isCurrent(store) else { return }
                    statisticsTarget = .init(source: statisticsSource, library: library)
                }
                    .disabled(statisticsSource == nil) }
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(busy)
                Button(L10n.tr("完成")) {
                    let expectedPartition = store.partition
                    let expectedClient = store.client
                    let expectedEpoch = store.accountOperationID
                    model.cancel()
                    dismiss()
                    Task { @MainActor in
                        guard expectedPartition != nil, expectedClient != nil,
                              store.partition == expectedPartition, store.client === expectedClient,
                              store.accountOperationID == expectedEpoch, !store.isConnecting else { return }
                        await store.refresh()
                    }
                }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ManagementNotice(operation: model.operation)
            if let notice = model.creationNotice {
                Label(notice, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            }
            if library == nil { libraries.padding(16) }
            else { TabView(selection: $selectedTab) {
                settings.tabItem { Label(L10n.tr("书库设置"), systemImage: "slider.horizontal.3") }.tag(0)
                upload.tabItem { Label(L10n.tr("上传"), systemImage: "square.and.arrow.up") }.tag(1)
                batch.tabItem { Label(L10n.tr("批量管理"), systemImage: "checklist") }.tag(2)
                tools.tabItem { Label(L10n.tr("扫描与清理"), systemImage: "wrench.and.screwdriver") }.tag(3)
                libraries.tabItem { Label(L10n.tr("书库组织"), systemImage: "square.stack.3d.up") }.tag(4)
            }.padding(16) }
        }.frame(minWidth: 900, idealWidth: 1100, minHeight: 690, idealHeight: 850)
        .task { if let library { await model.open(store: store, library: library) } else { await model.openOrganization(store: store) } }
        .onDisappear { model.cancel() }
        .sheet(item: $statisticsTarget) { target in
            LibraryStatisticsView(store: store, library: target.library, origin: target.source) {
                statisticsTarget = nil; model.cancel(); dismiss()
            }
        }
        .onChange(of: store.partition) { _, _ in invalidateSource() }
        .onChange(of: store.client.map(ObjectIdentifier.init)) { _, _ in invalidateSource() }
        .onChange(of: store.accountOperationID) { _, _ in invalidateSource() }
        .onChange(of: selectedTab) { _, tab in
            if tab == 2 && model.page == nil { Task { await model.loadItems() } }
            if tab == 4 && model.libraryOrder.isEmpty { Task { await model.loadOrder() } }
        }
        .alert(confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) { Task { await confirmation.operation() }; self.confirmation = nil }
                Button(L10n.tr("取消"), role: .cancel) { self.confirmation = nil }
            }
        } message: { Text(confirmation?.message ?? "") }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.uploadURLs = urls
            case .failure(let error): model.operation.error = L10n.error(error)
            }
        }
    }
    private func invalidateSource() {
        confirmation = nil; statisticsTarget = nil; importingFiles = false
        model.cancel(); dismiss()
    }
    private var settings: some View {
        Form {
            Section(L10n.tr("基本信息")) {
                FormInputRow(L10n.tr("书库名称")) { TextField("", text: $model.name).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("书库名称")) }
                SettingsChoicePicker(title: L10n.tr("图标"), selection: $model.icon, choices: ClientSettingsChoices.libraryIcons)
                SettingsChoicePicker(title: L10n.tr("默认匹配来源"), selection: $model.provider, choices: model.providers.map { .init($0.value, $0.text, localizesLabel: false) })
            }
            Section(L10n.tr("服务器目录")) {
                ForEach(model.folders) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text(folder.path).textSelection(.enabled)
                        if folder.serverID == nil { Text(L10n.tr("待添加")).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) {
                            confirmation = .init(title: L10n.tr("从书库移除此目录？"), message: L10n.tr("保存设置时，该目录内的全部书库记录和关联进度将被移除；服务器原文件会保留。"), destructive: true, operation: { model.folders.removeAll { $0.id == folder.id } })
                        } label: { Image(systemName: "minus.circle") }.disabled(!canManage)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FormInputRow(L10n.tr("服务器绝对目录路径")) { TextField("", text: $model.newFolderPath).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("服务器绝对目录路径")) }
                    Button(L10n.tr("添加")) { model.addFolder() }.disabled(!canManage || model.newFolderPath.isEmpty)
                    Button(L10n.tr("浏览服务器…")) { Task { await model.browseDirectories() } }.disabled(!canManage)
                }
                if !model.directories.isEmpty || !model.directoryPath.isEmpty { directoryBrowser }
                Text(L10n.tr("路径属于 Audiobookshelf 服务器。新增路径不存在时，服务器会尝试创建目录。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("显示与扫描")) {
                Toggle(L10n.tr("使用方形封面"), isOn: $model.squareCovers)
                Toggle(L10n.tr("启用书库文件监视"), isOn: $model.enableWatcher)
                CronSchedulePicker(title: L10n.tr("自动扫描 Cron（留空关闭）"), selection: $model.autoScanCron, allowsDisabled: true)
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.tr("自动标记完成"), selection: $model.finishMode) { Text(L10n.tr("剩余秒数")).tag("time"); Text(L10n.tr("完成百分比")).tag("percent") }.pickerStyle(.menu)
                    FormInputRow(L10n.tr("阈值")) { TextField("", value: $model.finishValue, format: .number).frame(width: 100).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("阈值")) }
                }
                if library?.mediaType == "book" {
                    Toggle(L10n.tr("仅展示有声书"), isOn: $model.audiobooksOnly)
                    Toggle(L10n.tr("跳过已有 ASIN 的匹配"), isOn: $model.skipASIN)
                    Toggle(L10n.tr("跳过已有 ISBN 的匹配"), isOn: $model.skipISBN)
                    Toggle(L10n.tr("隐藏只有一本书的系列"), isOn: $model.hideSingleSeries)
                    Toggle(L10n.tr("系列续听仅显示较后作品"), isOn: $model.laterBooksOnly)
                    Toggle(L10n.tr("服务器 Web 阅读器允许 EPUB 脚本"), isOn: $model.allowEpubScripts)
                } else { SettingsChoicePicker(title: L10n.tr("播客搜索地区"), selection: $model.podcastRegion, choices: ClientSettingsChoices.podcastRegions) }
            }
            if library?.mediaType == "book" { metadataPrecedence }
            Button(L10n.tr("保存书库设置")) {
                confirmation = .init(title: L10n.tr("保存书库设置？"), message: model.removedFolderCount > 0 ? L10n.format("将移除 %1$@ 个目录及其全部书库记录；原文件保留。", String(describing: model.removedFolderCount)) : L10n.tr("服务器将更新书库配置，并应用目录和扫描设置。"), destructive: model.removedFolderCount > 0, operation: { await model.save() })
            }.buttonStyle(.borderedProminent).disabled(!canManage || model.library == nil)
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    private var directoryBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { Task { await model.parentDirectory() } } label: { Image(systemName: "arrow.up") }.disabled(busy)
                TextField(L10n.tr("当前目录"), text: $model.directoryPath)
                Button(L10n.tr("前往")) { Task { await model.browseDirectories() } }.disabled(busy)
                Button(L10n.tr("选择此目录")) { model.newFolderPath = model.directoryPath }.disabled(model.directoryPath.isEmpty || busy)
            }
            ScrollView { LazyVStack(alignment: .leading, spacing: 6) { ForEach(model.directories) { directory in
                HStack {
                    Button { Task { await model.browseDirectories(path: directory.path) } } label: { Label(directory.dirname, systemImage: "folder") }.buttonStyle(.plain)
                    Spacer()
                    Button(L10n.tr("选择")) { model.newFolderPath = directory.path }
                }.disabled(busy).padding(.vertical, 3)
            } } }.frame(maxHeight: 200)
        }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private var metadataPrecedence: some View {
        Section(L10n.tr("元数据优先级（上方优先）")) {
            ForEach(Array(model.metadataSources.enumerated()), id: \.element.id) { index, source in
                HStack {
                    Toggle(source.label, isOn: Binding(get: { model.metadataSources.first { $0.id == source.id }?.included ?? false }, set: { value in if let i = model.metadataSources.firstIndex(where: { $0.id == source.id }) { model.metadataSources[i].included = value } }))
                    Spacer()
                    Button { model.moveSource(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                    Button { model.moveSource(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == model.metadataSources.count)
                }
            }
            Button(L10n.tr("恢复默认优先级")) { model.resetSources() }.disabled(!canManage)
        }
    }
    private var upload: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("上传本机文件到服务器书库")).font(.headline)
            Text(L10n.tr("所选文件会作为同一项内容上传；服务器按作者、系列与标题组织目录。")).font(.callout).foregroundStyle(.secondary)
            HStack { Button(L10n.tr("选择文件…")) { importingFiles = true }.disabled(!canUpload); Text(L10n.format("%1$@ 个文件", String(describing: model.uploadURLs.count))).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("清空")) { model.uploadURLs = [] }.disabled(busy) }
            List(model.uploadURLs, id: \.self) { url in Label(url.lastPathComponent, systemImage: "doc") }
            Form {
                Picker(L10n.tr("目标服务器目录"), selection: $model.uploadFolderID) { ForEach(model.library?.folders ?? [], id: \.fullPath) { folder in Text(folder.fullPath).tag(folder.id ?? "") } }.pickerStyle(.menu)
                FormInputRow(L10n.tr("内容标题")) { TextField("", text: $model.uploadTitle).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("内容标题")) }
                FormInputRow(L10n.tr("作者")) { TextField("", text: $model.uploadAuthor).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("作者")) }
                FormInputRow(L10n.tr("系列")) { TextField("", text: $model.uploadSeries).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("系列")) }
            }.textFieldStyle(.shelfLeading)
            HStack {
                if model.uploadIsActive {
                    VStack(alignment: .leading, spacing: 6) {
                        if let progress = model.uploadProgress, let fraction = progress.fraction {
                            ProgressView(value: fraction).frame(minWidth: 220)
                            Text("\(progress.phase == .preparing ? L10n.tr("准备文件") : L10n.tr("正在上传")) \(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                            if progress.phase == .uploading && fraction >= 1 { Text(L10n.tr("文件传输完成，等待服务器处理。")).font(.caption).foregroundStyle(.secondary) }
                        } else { ProgressView(L10n.tr("准备上传…")) }
                    }
                    Button(L10n.tr("取消上传"), role: .cancel) { model.cancelUpload() }
                } else if busy { Text(L10n.tr("正在处理请求，请等待服务器响应。")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.tr("上传到书库")) { model.startUpload() }.buttonStyle(.borderedProminent).disabled(!canUpload || model.uploadIsActive || model.uploadURLs.isEmpty || model.uploadTitle.isEmpty || model.uploadFolderID.isEmpty)
            }
        }.padding(12)
    }
    private var batch: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(L10n.tr("仅显示问题内容"), isOn: $model.issuesOnly).onChange(of: model.issuesOnly) { _, _ in Task { await model.loadItems() } }.disabled(busy)
                    Spacer()
                    Button { Task { await model.loadItems() } } label: { Image(systemName: "arrow.clockwise") }.disabled(busy)
                }
                HStack { Button(L10n.tr("选择已加载内容")) { model.selectLoaded() }; Button(L10n.tr("取消选择")) { model.selectedIDs = [] }; Spacer(); Text(L10n.format("已选 %1$@ 项", String(describing: model.selectedIDs.count))).font(.caption).foregroundStyle(.secondary) }.disabled(busy)
                List(model.items) { item in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggleSelection(item.id) })) { EmptyView() }.labelsHidden()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            Text(item.authorName).font(.caption).foregroundStyle(.secondary)
                            if item.isMissing || item.isInvalid { Label(item.isMissing ? L10n.tr("文件缺失") : L10n.tr("内容无效"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        }
                    }.padding(.vertical, 5)
                }.overlay { if model.items.isEmpty && !busy { ContentUnavailableView(L10n.tr("没有内容"), systemImage: "books.vertical") } }
                HStack { Text(L10n.format("已加载 %1$@ / %2$@ 项", String(describing: model.items.count), String(describing: model.page?.total ?? 0))).font(.caption).foregroundStyle(.secondary); Spacer(); if model.page?.hasMore == true { Button(L10n.tr("加载更多")) { Task { await model.loadItems(more: true) } }.disabled(busy) } }
            }.padding(12).frame(minWidth: 350)
            batchEditor.padding(12).frame(minWidth: 390)
        }
    }
    private var batchEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.format("批量修改 %1$@ 项", String(describing: model.selectedIDs.count))).font(.headline)
                Text(L10n.tr("只保存启用的字段。列表字段每行一个值；替换模式留空会清空该字段。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("向现有列表追加（关闭则替换）"), isOn: $model.batchAppend)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if library?.mediaType == "book" { additionalBatchBookFields }
                        Toggle(L10n.tr("修改标签"), isOn: $model.batchTagsEnabled)
                        if model.batchTagsEnabled { LeadingTextEditor(text: $model.batchTags).frame(height: 72) }
                        Toggle(L10n.tr("修改分类"), isOn: $model.batchGenresEnabled)
                        if model.batchGenresEnabled { LeadingTextEditor(text: $model.batchGenres).frame(height: 72) }
                        Toggle(L10n.tr("修改演播者"), isOn: $model.batchNarratorsEnabled)
                        if model.batchNarratorsEnabled { LeadingTextEditor(text: $model.batchNarrators).frame(height: 72) }
                        Toggle(L10n.tr("修改出版社"), isOn: $model.batchPublisherEnabled)
                        if model.batchPublisherEnabled { TextField(L10n.tr("出版社"), text: $model.batchPublisher) }
                        Toggle(L10n.tr("修改语言"), isOn: $model.batchLanguageEnabled)
                        if model.batchLanguageEnabled { MetadataLanguagePicker(selection: $model.batchLanguage) }
                        Toggle(L10n.tr("修改成人内容标记"), isOn: $model.batchExplicitEnabled)
                        if model.batchExplicitEnabled { Toggle(L10n.tr("包含成人内容"), isOn: $model.batchExplicit) }
                    }.padding(6)
                }
                Toggle(L10n.tr("修改简介"), isOn: $model.batchDescriptionEnabled)
                if model.batchDescriptionEnabled { LeadingTextEditor(text: $model.batchDescription).frame(height: 90) }
                Button(L10n.tr("保存选中内容的字段")) { confirmation = .init(title: L10n.format("批量修改 %1$@ 项？", String(describing: model.selectedIDs.count)), message: model.batchAppend ? L10n.tr("启用的列表字段会追加，其他启用字段会替换为表单中的值。") : L10n.tr("启用字段将被替换；空列表会清空已有值。"), operation: { await model.saveBatch() }) }.buttonStyle(.borderedProminent).disabled(!canUpdate || model.selectedIDs.isEmpty)
                Divider()
                HStack { Button(L10n.tr("扫描选中内容")) { Task { await model.scanSelected() } }; Button(L10n.tr("匹配选中内容")) { confirmation = .init(title: L10n.tr("匹配选中内容？"), message: L10n.format("服务器将为 %1$@ 项内容查找并保存匹配结果。", String(describing: model.selectedIDs.count)), operation: { await model.matchSelected() }) } }.disabled(!canManage || model.selectedIDs.isEmpty)
                Toggle(L10n.tr("嵌入前备份原文件"), isOn: $model.backupOriginals)
                Toggle(L10n.tr("强制覆盖文件内章节"), isOn: $model.forceChapters)
                Button(L10n.tr("将元数据嵌入选中内容")) { confirmation = .init(title: L10n.tr("修改选中内容的原文件？"), message: L10n.format("服务器会向 %1$@ 项内容的文件写入元数据。", String(describing: model.selectedIDs.count)), operation: { await model.embedSelected() }) }.disabled(!canManage || model.selectedIDs.isEmpty)
                Divider()
                Toggle(L10n.tr("同时删除服务器原文件"), isOn: $model.batchDeleteFiles)
                Button(L10n.tr("删除选中内容"), role: .destructive) { confirmation = .init(title: L10n.format("删除 %1$@ 项内容？", String(describing: model.selectedIDs.count)), message: model.batchDeleteFiles ? L10n.tr("书库记录及服务器原文件将永久删除。") : L10n.tr("只移除书库记录，原文件保留。"), destructive: true, operation: { await model.deleteSelected() }) }.disabled(!canDelete || model.selectedIDs.isEmpty)
            }.textFieldStyle(.shelfLeading)
        }
    }
    private var additionalBatchBookFields: some View {
        Group {
            Toggle(L10n.tr("修改作者"), isOn: $model.batchAuthorsEnabled)
            if model.batchAuthorsEnabled { LeadingTextEditor(text: $model.batchAuthors).frame(height: 72) }
            Toggle(L10n.tr("修改系列关系"), isOn: $model.batchSeriesEnabled)
            if model.batchSeriesEnabled {
                ForEach(model.batchSeries) { draft in
                    HStack {
                        TextField(L10n.tr("系列名称"), text: batchSeriesBinding(draft, \.name))
                        TextField(L10n.tr("卷序（可空）"), text: batchSeriesBinding(draft, \.sequence)).frame(maxWidth: 120)
                        Button(role: .destructive) { model.batchSeries.removeAll { $0.id == draft.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
                Button(L10n.tr("添加系列")) { model.batchSeries.append(.init(name: "", sequence: "")) }
                Text(L10n.tr("追加时保留已有系列与卷序；替换时使用此列表，留空则移除全部系列关系。")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L10n.tr("修改副标题"), isOn: $model.batchSubtitleEnabled)
            if model.batchSubtitleEnabled { TextField(L10n.tr("副标题"), text: $model.batchSubtitle) }
            Toggle(L10n.tr("修改出版年份"), isOn: $model.batchPublishedYearEnabled)
            if model.batchPublishedYearEnabled { TextField(L10n.tr("出版年份"), text: $model.batchPublishedYear) }
            Toggle(L10n.tr("修改出版日期"), isOn: $model.batchPublishedDateEnabled)
            if model.batchPublishedDateEnabled { TextField(L10n.tr("出版日期"), text: $model.batchPublishedDate) }
            Toggle(L10n.tr("修改 ISBN"), isOn: $model.batchISBNEnabled)
            if model.batchISBNEnabled { TextField("ISBN", text: $model.batchISBN) }
            Toggle(L10n.tr("修改 ASIN"), isOn: $model.batchASINEnabled)
            if model.batchASINEnabled { TextField("ASIN", text: $model.batchASIN) }
            Toggle(L10n.tr("修改删节版标记"), isOn: $model.batchAbridgedEnabled)
            if model.batchAbridgedEnabled { Toggle(L10n.tr("删节版"), isOn: $model.batchAbridged) }
        }
    }
    private func batchSeriesBinding(_ draft: SeriesDraft, _ keyPath: WritableKeyPath<SeriesDraft, String>) -> Binding<String> {
        Binding(get: { model.batchSeries.first { $0.id == draft.id }?[keyPath: keyPath] ?? draft[keyPath: keyPath] }, set: { value in
            guard let index = model.batchSeries.firstIndex(where: { $0.id == draft.id }) else { return }
            model.batchSeries[index][keyPath: keyPath] = value
        })
    }
    private var tools: some View {
        Form {
            Section(L10n.tr("服务器任务")) {
                Button(L10n.tr("扫描整个书库")) { Task { await model.scan() } }.disabled(!canManage)
                Button(L10n.tr("强制重新扫描整个书库")) { confirmation = .init(title: L10n.tr("强制重新扫描书库？"), message: L10n.tr("服务器将重新读取全部内容的文件与元数据，这可能需要较长时间。"), operation: { await model.scan(force: true) }) }.disabled(!canManage)
                if library?.mediaType == "book" { Button(L10n.tr("自动匹配整个书库")) { confirmation = .init(title: L10n.tr("匹配整个书库？"), message: L10n.tr("服务器将查找并保存整个书库的匹配结果。"), operation: { await model.matchAll() }) }.disabled(!canManage) }
                Text(L10n.tr("任务交给服务器执行，实际进度可在服务器管理的任务列表查看。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("清理")) {
                Button(L10n.tr("查看缺失或无效内容")) { model.issuesOnly = true; selectedTab = 2; Task { await model.loadItems() } }.disabled(busy)
                Button(L10n.tr("移除全部缺失或无效记录"), role: .destructive) { confirmation = .init(title: L10n.tr("清理所有问题记录？"), message: L10n.tr("该书库中被服务器标记为缺失或无效的内容记录、关联进度将被移除，原文件保留。"), destructive: true, operation: { await model.removeIssues() }) }.disabled(!canManage)
                ForEach(LibraryMetadataFileKind.allCases, id: \.rawValue) { kind in
                    Button(L10n.format("删除全部 %1$@", String(describing: kind.filename)), role: .destructive) { confirmation = .init(title: L10n.format("删除书库内全部 %1$@？", String(describing: kind.filename)), message: L10n.format("服务器将永久删除书库内容目录中的 %1$@。音频和电子书原件保留；OPF 文件可在单项内容的文件与工具中删除。", String(describing: kind.filename)), destructive: true, operation: { await model.removeMetadataFiles(kind: kind) }) }.disabled(!canManage)
                }
            }
            Section(L10n.tr("删除书库")) {
                Text(L10n.tr("会移除书库配置、内容记录和相关进度，服务器原文件保留。")).foregroundStyle(.secondary)
                Button(L10n.tr("删除此书库"), role: .destructive) { confirmation = .init(title: L10n.format("删除书库“%1$@”？", library?.name ?? ""), message: L10n.tr("整个书库的记录及关联进度将移除。此操作无法撤销；服务器原文件保留。"), destructive: true, operation: { if await model.deleteLibrary() { dismiss(); await store.refresh() } }) }.disabled(!canManage)
            }
        }.formStyle(.grouped)
    }
    private var libraries: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(L10n.tr("书库顺序")).font(.headline); Spacer(); Button { Task { await model.loadOrder() } } label: { Image(systemName: "arrow.clockwise") }.disabled(!canManage) }
                List(Array(model.libraryOrder.enumerated()), id: \.element.id) { index, library in
                    HStack {
                        Text(library.name); Spacer()
                        Button { model.moveLibrary(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(!canManage || index == 0)
                        Button { model.moveLibrary(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(!canManage || index + 1 == model.libraryOrder.count)
                    }
                }
                HStack { Spacer(); Button(L10n.tr("保存书库顺序")) { Task { await model.saveOrder() } }.buttonStyle(.borderedProminent).disabled(!canManage || model.libraryOrder.isEmpty) }
            }.padding(12).frame(minWidth: 360)
            Form {
                Section(L10n.tr("新建书库")) {
                    FormInputRow(L10n.tr("名称")) { TextField("", text: $model.createName).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("名称")) }
                    Picker(L10n.tr("内容类型"), selection: $model.createType) { Text(L10n.tr("图书")).tag("book"); Text(L10n.tr("播客")).tag("podcast") }.pickerStyle(.menu)
                    FormInputRow(L10n.tr("服务器绝对目录路径")) { TextField("", text: $model.createPath).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("服务器绝对目录路径")) }
                    Text(L10n.tr("服务器会使用现有目录，路径不存在时会尝试创建。")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("创建书库")) {
                        guard let request = model.prepareLibraryCreation() else { return }
                        confirmation = .init(title: L10n.tr("创建新书库？"),
                                             message: L10n.format("服务器将为“%1$@”建立书库并添加目录 %2$@。", request.draft.name, request.draft.folders.first?.fullPath ?? ""),
                                             operation: {
                            if await model.createLibrary(request), model.operation.sourceID == request.sourceID { await store.refresh() }
                        })
                    }.buttonStyle(.borderedProminent).disabled(!canManage || !model.isCreationDraftValid)
                }
            }.formStyle(.grouped).textFieldStyle(.shelfLeading).frame(minWidth: 360).disabled(!canManage)
        }
    }
}

private struct LibraryStatisticsPresentation: Identifiable {
    let id = UUID()
    let source: LibraryStatisticsSource
    let library: Library
}
