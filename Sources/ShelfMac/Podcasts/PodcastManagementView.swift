import SwiftUI
import ShelfCore

struct PodcastManagementView: View {
    let store: AppStore
    let item: ShelfCore.LibraryItem
    @State private var model = PodcastManagementModel()
    @State private var tab = 0
    @State private var checkCountValid = true
    @State private var keepCountValid = true
    @State private var autoCountValid = true
    @State private var editing: PodcastEpisode?
    @State private var deleting: PodcastEpisode?
    @State private var deleteOriginal = false
    @State private var clearConfirmation = false
    @State private var settingsConfirmation = false
    @State private var overrideMatches = false
    @State private var matchConfirmation = false
    @State private var confirmedSettings: (@MainActor () async -> Void)?
    @State private var confirmedClear: (@MainActor () async -> Void)?
    @State private var confirmedMatch: (@MainActor () async -> Void)?
    @State private var confirmedDelete: (@MainActor () async -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var canManage: Bool { store.user.map { AdminPolicy.allows(.manageServer, user: $0) } == true && !store.isOffline }
    private var canUpdate: Bool { store.user.map { AdminPolicy.allows(.updateContent, user: $0) } == true && !store.isOffline }
    private var canDelete: Bool { store.user.map { AdminPolicy.allows(.deleteContent, user: $0) } == true && !store.isOffline }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "podcasts").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) { Text(item.title).font(.title2.bold()); Text(L10n.tr("播客与服务器下载")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }.help(L10n.tr("刷新"))
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(12) }
            if model.refreshFailed {
                HStack {
                    Text(L10n.tr("详情刷新失败，请重试刷新。"))
                    Button(L10n.tr("重试刷新")) { Task { await model.reload() } }.disabled(model.isBusy)
                }.font(.caption).padding(8)
            }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.secondary).padding(8) }
            TabView(selection: $tab) {
                episodes.tabItem { Label(L10n.tr("单集"), systemImage: "list.bullet") }.tag(0)
                feed.tabItem { Label(L10n.tr("RSS 选集"), systemImage: "dot.radiowaves.left.and.right") }.tag(1)
                downloads.tabItem { Label(L10n.tr("服务器队列"), systemImage: "arrow.down.circle") }.tag(2)
                settings.tabItem { Label(L10n.tr("订阅设置"), systemImage: "slider.horizontal.3") }.tag(3)
            }.padding(16)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 580, idealHeight: 720)
        .task { await model.open(store: store, item: item) }
        .onDisappear { model.cancel() }
        .onChange(of: store.partition) { _, _ in model.cancel(); dismiss() }
        .onChange(of: store.accountOperationID) { _, _ in model.cancel(); dismiss() }
        .sheet(item: $editing) { episode in
            PodcastEpisodeEditor(store: store, itemID: item.id, episode: episode, hasFeed: !(model.item?.media.metadata.feedUrl ?? "").isEmpty) { await model.reload() }
        }
        .alert(L10n.tr("删除单集？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(deleteOriginal ? L10n.tr("删除单集与原文件") : L10n.tr("移除单集"), role: .destructive) { let action = confirmedDelete; confirmedDelete = nil; deleting = nil; Task { await action?() } }
            Button(L10n.tr("取消"), role: .cancel) { deleting = nil }
        } message: { Text(deleteOriginal ? L10n.tr("服务器上的原音频文件也会被删除，此操作无法撤销。") : L10n.tr("将从播客中移除此单集，服务器上的原音频文件会保留。")) }
        .alert(L10n.tr("清空服务器等待队列？"), isPresented: $clearConfirmation) {
            Button(L10n.tr("清空队列"), role: .destructive) { let action = confirmedClear; confirmedClear = nil; Task { await action?() } }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("正在进行的下载可能继续完成。")) }
        .alert(L10n.tr("减少保留的单集数量？"), isPresented: $settingsConfirmation) {
            Button(L10n.tr("保存并允许清理旧单集"), role: .destructive) { let action = confirmedSettings; confirmedSettings = nil; Task { await action?() } }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("服务器后续下载时可能永久删除超出保留数量的旧单集原文件。")) }
        .alert(L10n.tr("覆盖已有单集信息？"), isPresented: $matchConfirmation) {
            Button(L10n.tr("覆盖并匹配"), role: .destructive) { let action = confirmedMatch; confirmedMatch = nil; Task { await action?() } }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: { Text(L10n.tr("将用 RSS 的匹配结果覆盖已有单集信息。取消勾选覆盖选项时，仅补充缺失的信息。")) }
    }
    private var episodes: some View {
        VStack(spacing: 10) {
            HStack {
                Text(L10n.format("%1$@ 集", String(describing: model.item?.media.episodes.count ?? item.media.episodes.count))).foregroundStyle(.secondary)
                Spacer()
                if canDelete {
                    Toggle(L10n.tr("删除时同时移除服务器原文件"), isOn: $deleteOriginal).font(.caption).toggleStyle(.checkbox)
                }
                if canManage && canUpdate {
                    Toggle(L10n.tr("覆盖已有信息"), isOn: $overrideMatches).font(.caption).toggleStyle(.checkbox)
                    Button(L10n.tr("匹配单集信息")) { if overrideMatches { confirmedMatch = model.confirmation(requiring: [.updateContent]) { await model.matchEpisodes(overrideDetails: true) }; matchConfirmation = confirmedMatch != nil } else { Task { await model.matchEpisodes() } } }.disabled(model.isBusy || model.refreshFailed)
                }
            }
            List(model.item?.media.episodes ?? item.media.episodes) { episode in
                HStack(spacing: 14) {
                    Button { accountAction { await store.play(model.item ?? item, episode: episode) } } label: { Image(systemName: "play.circle.fill").font(.title2) }.buttonStyle(.plain).help(L10n.tr("播放单集"))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.headline).lineLimit(2)
                        HStack {
                            if let date = episode.publishedAt { Text(Date(timeIntervalSince1970: date / 1000), style: .date) }
                            if let duration = episode.duration ?? episode.audioFile?.duration { Text(Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))) }
                        }.font(.caption).foregroundStyle(.secondary)
                        localStatus(episode)
                    }
                    Spacer(minLength: 8)
                    if store.canDownload { localActions(episode) }
                    if canUpdate { Button { editing = episode } label: { Image(systemName: "square.and.pencil") }.help(L10n.tr("编辑单集")).disabled(model.isBusy) }
                    if canDelete { Button(role: .destructive) { let removeFile = deleteOriginal; confirmedDelete = model.confirmation(admin: false, requiring: [.deleteContent]) { await model.deleteEpisode(episode, deleteFile: removeFile) }; if confirmedDelete != nil { deleting = episode } } label: { Image(systemName: "trash") }.help(L10n.tr("删除单集")).disabled(model.isBusy) }
                }.padding(.vertical, 8)
            }.listStyle(.inset)
        }
    }
    private func record(_ episode: PodcastEpisode) -> DownloadRecord? {
        guard store.downloads?.partition == store.partition else { return nil }
        return store.downloads?.records.first { $0.itemID == PodcastDownloadIdentity.key(itemID: item.id, episodeID: episode.id) }
    }
    @ViewBuilder private func localStatus(_ episode: PodcastEpisode) -> some View {
        if let record = record(episode) {
            if record.state == .downloading { ProgressView(value: record.progress).frame(maxWidth: 220) }
            Text(record.state == .ready ? L10n.tr("已下载到本机，可离线播放") : record.errorDiagnostic.map(L10n.diagnostic) ?? record.error ?? stateName(record.state)).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func localActions(_ episode: PodcastEpisode) -> some View {
        if let record = record(episode), let downloads = store.downloads {
            if record.state == .downloading || record.state == .queued {
                Button { localOperation { try await downloads.pause(itemID: record.itemID) } } label: { Image(systemName: "pause.circle") }.help(L10n.tr("暂停本机下载"))
            } else if record.state != .ready, let client = store.client, !store.isOffline {
                Button { localOperation { try await downloads.resume(itemID: record.itemID) { try await client.authorizedRequest(path: $0.absoluteString) } } } label: { Image(systemName: "arrow.clockwise.circle") }.help(L10n.tr("继续本机下载"))
            }
            Button { localOperation { try await downloads.remove(itemID: record.itemID) } } label: { Image(systemName: "xmark.circle") }.help(L10n.tr("移除本机下载"))
        } else {
            Button { accountAction { await store.downloadEpisode(model.item ?? item, episode: episode) } } label: { Image(systemName: "arrow.down.circle") }.disabled(store.isOffline || episode.audioFile == nil).help(L10n.tr("下载单集到本机"))
        }
    }
    private func stateName(_ state: DownloadState) -> String {
        switch state { case .queued: L10n.tr("等待下载"); case .downloading: L10n.tr("正在下载到本机"); case .paused: L10n.tr("本机下载已暂停"); case .ready: L10n.tr("已下载"); case .failed: L10n.tr("下载失败") }
    }
    private func accountAction(_ action: @escaping @MainActor () async -> Void) {
        let partition = model.account.partition, client = model.account.client
        Task {
            guard partition != nil, store.partition == partition, store.client === client else { return }
            await action()
        }
    }
    private func localOperation(_ action: @escaping @MainActor () async throws -> Void) {
        accountAction {
            let partition = store.partition
            do { try await action() }
            catch { if store.partition == partition { model.error = L10n.error(error) } }
        }
    }
    private var feed: some View {
        VStack(spacing: 12) {
            HStack {
                TextField(L10n.tr("RSS 地址"), text: $model.rssURL).textFieldStyle(.shelfLeading)
                Button(L10n.tr("解析 RSS")) { Task { await model.parseFeed() } }.disabled(!canManage || model.isBusy || model.rssURL.isEmpty)
            }
            if let feed = model.feed {
                HStack { Text(feed.metadata.title).font(.headline); Text(L10n.format("%1$@ 集", String(describing: feed.numEpisodes))).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("全选")) { model.selectedEpisodes = Set(feed.episodes.map(\.id)) }; Button(L10n.tr("取消选择")) { model.selectedEpisodes = [] } }
                List(feed.episodes) { episode in
                    Toggle(isOn: Binding(get: { model.selectedEpisodes.contains(episode.id) }, set: { if $0 { model.selectedEpisodes.insert(episode.id) } else { model.selectedEpisodes.remove(episode.id) } })) {
                        VStack(alignment: .leading, spacing: 4) { Text(episode.title); if let date = episode.pubDate { Text(date).font(.caption).foregroundStyle(.secondary) } }
                    }.toggleStyle(.checkbox).padding(.vertical, 5)
                }
                HStack { Text(L10n.tr("所选单集由服务器下载后加入书库。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.format("下载所选 %1$@ 集到服务器", String(describing: model.selectedEpisodes.count))) { Task { await model.downloadSelected() } }.buttonStyle(.borderedProminent).disabled(!canManage || !canUpdate || model.isBusy || model.refreshFailed || model.selectedEpisodes.isEmpty) }
            } else { ContentUnavailableView(L10n.tr("从 RSS 选择单集"), systemImage: "dot.radiowaves.left.and.right", description: Text(L10n.tr("解析订阅源后，可选择尚未下载的单集。"))) }
        }
    }
    private var downloads: some View {
        VStack(spacing: 12) {
            HStack {
                PodcastCountPicker(title: L10n.tr("每次检查下载数量"), value: $model.checkLimit, valid: $checkCountValid)
                Button(L10n.tr("检查新单集")) { Task { await model.checkNew() } }.disabled(!canManage || !checkCountValid || model.isBusy || model.refreshFailed)
                Spacer()
                Button(L10n.tr("清空等待队列"), role: .destructive) { confirmedClear = model.confirmation { await model.clearQueue() }; clearConfirmation = confirmedClear != nil }.disabled(!canManage || model.isBusy || model.refreshFailed || !model.hasWaitingDownloads)
            }
            Toggle(L10n.tr("指定检查起始日期"), isOn: $model.usesCheckDate).disabled(!canManage || !canUpdate || model.isBusy)
            if model.usesCheckDate {
                DatePicker(L10n.tr("查找此日期之后的新单集"), selection: $model.checkDate, displayedComponents: [.date, .hourAndMinute]).disabled(!canManage || !canUpdate || model.isBusy)
            }
            if model.queue.isEmpty { ContentUnavailableView(L10n.tr("暂无服务器下载"), systemImage: "checkmark.circle", description: Text(L10n.tr("检查新集，或从 RSS 选择要下载的单集。"))) }
            else { List(model.queue) { download in HStack { VStack(alignment: .leading) { Text(download.episodeDisplayTitle ?? L10n.tr("播客单集")); Text(download.failed ? L10n.tr("下载失败") : download.isFinished ? L10n.tr("已完成") : download.id == model.currentDownloadID ? L10n.tr("下载中") : L10n.tr("等待中")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: download.failed ? "exclamationmark.circle" : download.isFinished ? "checkmark.circle" : "arrow.down.circle") }.padding(.vertical, 6) } }
        }
    }
    private var settings: some View {
        Form {
            Toggle(L10n.tr("自动检查并下载新单集"), isOn: $model.autoDownload)
            CronSchedulePicker(title: L10n.tr("自动下载计划（Cron）"), selection: $model.schedule).disabled(!model.autoDownload)
            PodcastCountPicker(title: L10n.tr("保留最近单集数量"), value: $model.maxKeep, valid: $keepCountValid)
            PodcastCountPicker(title: L10n.tr("每次自动下载数量"), value: $model.maxNew, valid: $autoCountValid)
            Text(L10n.tr("减少保留数量可能使服务器在后续下载时自动删除旧单集。该设置会影响服务器上的原文件。")).font(.caption).foregroundStyle(.secondary)
            Button(L10n.tr("保存播客设置")) {
                let old = model.item?.media.maxEpisodesToKeep ?? 0
                if model.maxKeep > 0 && (old == 0 || model.maxKeep < old) { let update = model.settingsUpdate; confirmedSettings = model.confirmation(admin: false, requiring: [.updateContent]) { await model.saveSettings(update) }; settingsConfirmation = confirmedSettings != nil }
                else { Task { await model.saveSettings() } }
            }.buttonStyle(.borderedProminent).disabled(!keepCountValid || !autoCountValid)
        }.formStyle(.grouped).disabled(!canUpdate || model.isBusy)
    }
}


private struct PodcastCountPicker: View {
    let title: String
    @Binding var value: Int
    @Binding var valid: Bool
    @State private var text = ""
    @State private var custom = false
    private let presets = [0, 1, 3, 5, 10, 25, 50, 100]
    private var selection: Binding<Int> {
        Binding(get: { custom || !presets.contains(value) ? -1 : value }, set: {
            custom = $0 == -1
            if $0 >= 0 { value = $0; valid = true }
            else { text = String(value); valid = value >= 0 }
        })
    }
    var body: some View {
        HStack {
            Picker(title, selection: selection) {
                ForEach(presets, id: \.self) { count in
                    Text(count == 0 ? L10n.tr("不限") : String(count)).tag(count)
                }
                Text(L10n.tr("自定义")).tag(-1)
            }
            if selection.wrappedValue == -1 {
                TextField(L10n.tr("非负整数，0 表示不限"), text: $text)
                    .textFieldStyle(.shelfLeading).frame(width: 150)
            }
        }
        .onAppear { text = String(value); valid = value >= 0 }
        .onChange(of: text) { _, input in
            guard selection.wrappedValue == -1 else { return }
            if let parsed = Int(input), parsed >= 0 { value = parsed; valid = true }
            else { valid = false }
        }
        .onChange(of: value) { _, newValue in
            if valid { text = String(newValue) }
        }
    }
}
