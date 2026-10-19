import SwiftUI
import AudilseCore
import UniformTypeIdentifiers

struct PodcastSubscriptionView: View {
    let store: AppStore
    let library: Library
    @State private var model = PodcastSubscriptionModel()
    @State private var tab = 0
    @State private var importingFile = false
    @State private var exportingFile = false
    @Environment(\.dismiss) private var dismiss
    private var canManage: Bool { store.user.map { AdminPolicy.allows(.manageServer, user: $0) } == true && !store.isOffline }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(.tint)
                Text(L10n.tr("播客订阅")).font(.title2.bold())
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.loadFolders() } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.tr("重新加载目标文件夹")).disabled(model.isBusy || store.isOffline)
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(12) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary).padding(10) }
            if model.library != nil {
                HStack {
                    Text(model.library?.name ?? library.name).font(.headline)
                    Spacer()
                    Picker(L10n.tr("目标文件夹"), selection: $model.folderID) { ForEach(model.folders) { folder in Text(folder.fullPath).tag(folder.id) } }.pickerStyle(.menu).frame(maxWidth: 430)
                }.padding(16)
                TabView(selection: $tab) {
                    directory.tabItem { Label(L10n.tr("搜索播客"), systemImage: "magnifyingglass") }.tag(2)
                    rss.tabItem { Label(L10n.tr("RSS 订阅"), systemImage: "plus.circle") }.tag(0)
                    opml.tabItem { Label(L10n.tr("OPML 导入导出"), systemImage: "square.and.arrow.up.on.square") }.tag(1)
                }.padding(16)
            } else { ContentUnavailableView(L10n.tr("尚无播客书库"), systemImage: "podcasts", description: Text(L10n.tr("请先在服务器管理中创建播客书库。"))) }
        }
        .frame(minWidth: 700, idealWidth: 820, minHeight: 550, idealHeight: 700)
        .task { await model.open(store: store, library: library) }
        .onDisappear { model.cancel() }
        .onChange(of: store.partition) { _, _ in model.cancel(); dismiss() }
        .onChange(of: model.folderID) { _, _ in model.updatePath() }
        .sheet(item: $model.selectedExistingItem) { PodcastManagementView(store: store, item: $0) }
        .onChange(of: model.exportedOPML) { _, data in if data != nil { exportingFile = true } }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.podcastOPML, .xml]) { result in
            switch result { case .success(let url): Task { await model.readOPML(url) }; case .failure(let error): model.error = L10n.error(error) }
        }
        .fileExporter(isPresented: $exportingFile, document: PodcastOPMLDocument(data: model.exportedOPML ?? Data()), contentType: .podcastOPML, defaultFilename: "podcasts.opml") { result in
            if case .failure(let error) = result { model.error = L10n.error(error) }
            model.exportedOPML = nil
        }
    }
    private var directory: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(L10n.tr("节目名称、作者或关键词"), text: $model.searchTerm).textFieldStyle(.shelfLeading)
                    .onSubmit { Task { await model.searchDirectory() } }
                SettingsChoicePicker(title: L10n.tr("地区"), selection: $model.searchCountry, choices: ClientSettingsChoices.podcastRegions).frame(width: 170)
                Button(L10n.tr("搜索")) { Task { await model.searchDirectory() } }.disabled(!canManage || model.isBusy || model.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(L10n.tr("通过服务器搜索 iTunes 播客目录；选择结果后解析 RSS，再确认服务器保存位置。"))
                .font(.caption).foregroundStyle(.secondary)
            List(model.searchResults) { result in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(result.title).font(.headline)
                        Text(result.artistName ?? "").font(.caption).foregroundStyle(.secondary)
                        Text(L10n.format("%1$@ 集 · ", String(describing: result.trackCount)) + result.genres.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        if result.explicit { Text(L10n.tr("限制内容")).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if model.existingPodcast(result) != nil { Button(L10n.tr("已订阅 · 查看")) { Task { await model.openExistingPodcast(result) } }.disabled(model.isBusy) }
                    else {
                        Button(L10n.tr("选择…")) { Task { await model.selectDirectoryResult(result); if model.feed != nil { tab = 0 } } }
                            .disabled(!canManage || model.isBusy)
                    }
                }.padding(.vertical, 7)
            }.listStyle(.inset)
        }
    }
    private var rss: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { TextField("https://…/feed.xml", text: $model.rssURL).textFieldStyle(.shelfLeading); Button(L10n.tr("解析 RSS")) { Task { await model.parseRSS() } }.disabled(!canManage || model.isBusy || model.rssURL.isEmpty) }
            if let feed = model.feed {
                Text(feed.metadata.title).font(.title2.bold())
                if let author = feed.metadata.author { Text(author).foregroundStyle(.secondary) }
                Text(L10n.format("%1$@ 集", String(describing: feed.numEpisodes))).font(.caption).foregroundStyle(.secondary)
                if let description = feed.metadata.descriptionPlain ?? feed.metadata.description { ScrollView { Text(description).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150) }
                TextField(L10n.tr("服务器保存路径"), text: $model.path).textFieldStyle(.shelfLeading)
                PodcastTypePicker(selection: $model.podcastType).disabled(!canManage || model.isBusy)
                Toggle(L10n.tr("自动检查并下载新单集"), isOn: $model.autoDownload)
                if model.autoDownload { CronSchedulePicker(title: L10n.tr("下载计划（Cron）"), selection: $model.schedule) }
                Spacer()
                HStack { Spacer(); Button(L10n.tr("订阅播客")) { Task { await model.subscribe() } }.buttonStyle(.borderedProminent).disabled(!canManage || model.isBusy || model.folderID.isEmpty) }
            } else { ContentUnavailableView(L10n.tr("添加喜爱的播客"), systemImage: "podcasts", description: Text(L10n.tr("输入 RSS 地址解析内容，再选择服务器保存位置。"))) }
        }
    }
    private var opml: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(L10n.tr("打开 OPML 文件…")) { importingFile = true }.disabled(!canManage || model.isBusy)
                Button(L10n.tr("解析粘贴的 OPML")) { Task { await model.parseOPML() } }.disabled(!canManage || model.isBusy || model.opmlText.isEmpty)
                Spacer()
                Button(L10n.tr("导出当前书库 OPML…")) { Task { await model.exportOPML() } }.disabled(model.isBusy || store.isOffline)
            }
            if model.opmlFeeds.isEmpty { LeadingTextEditor(text: $model.opmlText).font(.system(.body, design: .monospaced)).border(.quaternary).overlay(alignment: .topLeading) { if model.opmlText.isEmpty { Text(L10n.tr("也可以在这里粘贴 OPML XML…")).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false) } } }
            else {
                HStack { Text(L10n.format("%1$@ 个订阅", String(describing: model.opmlFeeds.count))).font(.headline); Spacer(); Button(L10n.tr("全选")) { model.selectedFeeds = Set(model.opmlFeeds.map(\.id)) }; Button(L10n.tr("重新选择文件")) { model.opmlFeeds = []; importingFile = true } }
                List(model.opmlFeeds) { feed in
                    Toggle(isOn: Binding(get: { model.selectedFeeds.contains(feed.id) }, set: { if $0 { model.selectedFeeds.insert(feed.id) } else { model.selectedFeeds.remove(feed.id) } })) {
                        VStack(alignment: .leading, spacing: 4) { Text(feed.title); Text(feed.feedUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.toggleStyle(.checkbox).padding(.vertical, 5)
                }
                HStack { Toggle(L10n.tr("导入后自动下载新单集"), isOn: $model.autoDownload); Spacer(); Button(L10n.format("导入所选 %1$@ 个订阅", String(describing: model.selectedFeeds.count))) { Task { await model.importOPML() } }.buttonStyle(.borderedProminent).disabled(!canManage || model.isBusy || model.folderID.isEmpty || model.selectedFeeds.isEmpty) }
            }
        }
    }
}

struct PodcastTypePicker: View {
    @Binding var selection: String
    var body: some View {
        SettingsChoicePicker(title: L10n.tr("播客类型"), selection: $selection, choices: [
            .init("episodic", "单元剧"), .init("serial", "连续剧")
        ])
    }
}

private extension UTType {
    static let podcastOPML = UTType(importedAs: "org.opml.opml", conformingTo: .xml)
}

private struct PodcastOPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.podcastOPML, .xml] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
