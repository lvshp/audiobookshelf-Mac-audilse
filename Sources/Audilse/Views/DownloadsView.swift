import SwiftUI
import AudilseCore

struct DownloadsView: View {
    @Bindable var store: AppStore
    @State private var removing: DownloadRecord?
    @State private var removingPartition: AccountPartition?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: L10n.tr("故事，随身带走"), subtitle: L10n.tr("下载完整音频，在没有网络的时候继续收听"))
                if let manager = store.downloads, !manager.records.isEmpty {
                    ForEach(manager.records) { record in row(record) }
                    Text(L10n.tr("下载按服务器和账户分别保存。删除本地文件不会删除服务器内容。")).font(.caption).foregroundStyle(.tertiary)
                } else {
                    QuietEmptyState(symbol: "arrow.down.circle", title: L10n.tr("还没有下载的故事"), message: L10n.tr("在书籍详情中选择“下载到 Mac”，音频和章节会一起保存在这里。"))
                }
            }.padding(32)
        }
        .alert(L10n.tr("删除本地下载？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.tr("取消"), role: .cancel) { removing = nil }
            Button(L10n.tr("删除下载"), role: .destructive) {
                guard let record = removing, let partition = removingPartition,
                      store.partition == partition, let manager = store.downloads else { removing = nil; return }
                removing = nil
                Task {
                    guard store.partition == partition, store.downloads === manager, manager.partition == partition else { return }
                    do { try await manager.remove(itemID: record.itemID) }
                    catch { if store.partition == partition, store.downloads === manager { store.errorMessage = L10n.error(error) } }
                }
            }
        } message: { Text(removing?.title ?? "") }
        .onChange(of: store.partition) { _, _ in removing = nil; removingPartition = nil }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(ShelfTheme.accent.opacity(0.08)).frame(width: 60, height: 72)
                Image(systemName: record.state == .ready ? "headphones" : "arrow.down").font(.system(size: 24, weight: .light)).foregroundStyle(ShelfTheme.accent)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(record.title).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(stateTitle(record.state))
                    Text(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file) + (record.expectedBytes > 0 ? " / " + ByteCountFormatter.string(fromByteCount: record.expectedBytes, countStyle: .file) : ""))
                    Text(L10n.format("%1$@/%2$@ 个文件", String(describing: record.files.filter(\.completed).count), String(describing: record.files.count)))
                }.font(.caption).foregroundStyle(.secondary)
                if record.state != .ready { ProgressView(value: record.progress).tint(ShelfTheme.accent) }
                if let error = record.errorDiagnostic.map(L10n.diagnostic) ?? record.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if record.state == .ready {
                Button(L10n.tr("播放"), systemImage: "play.fill") {
                    guard let partition = store.partition, let database = store.database else { return }
                    Task {
                        guard store.partition == partition else { return }
                        let identity = PodcastDownloadIdentity(key: record.itemID)
                        let itemID = identity?.itemID ?? record.itemID
                        let item: AudilseCore.LibraryItem?
                        if let visible = store.items.first(where: { $0.id == itemID }), identity == nil { item = visible }
                        else { item = try? await database.load(AudilseCore.LibraryItem.self, key: "item.\(itemID)", partition: partition) }
                        guard store.partition == partition, let item else { return }
                        if let identity {
                            guard let episode = item.media.episodes.first(where: { $0.id == identity.episodeID }) else {
                                store.errorMessage = L10n.tr("无法找到已下载单集的信息。连接服务器刷新节目后重试。"); return
                            }
                            await store.play(item, episode: episode)
                        } else { await store.play(item) }
                    }
                }.buttonStyle(.bordered)
            } else {
                Button(record.state == .downloading || record.state == .queued ? L10n.tr("暂停") : L10n.tr("继续"), systemImage: record.state == .downloading || record.state == .queued ? "pause" : "arrow.clockwise") {
                    guard let partition = store.partition, let manager = store.downloads else { return }
                    let client = store.client
                    Task {
                        guard store.partition == partition, store.downloads === manager, manager.partition == partition else { return }
                        do {
                            if record.state == .downloading || record.state == .queued { try await manager.pause(itemID: record.itemID) }
                            else if let client { try await manager.resume(itemID: record.itemID) { url in try await client.authorizedRequest(path: url.absoluteString) } }
                        } catch { if store.partition == partition, store.downloads === manager { store.errorMessage = L10n.error(error) } }
                    }
                }.buttonStyle(.bordered).disabled(store.isOffline && record.state != .downloading)
            }
            Button { removingPartition = store.partition; removing = record } label: { Image(systemName: "trash").foregroundStyle(.secondary) }.buttonStyle(.plain).help(L10n.tr("删除本地下载"))
        }.padding(18).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
    private func stateTitle(_ state: DownloadState) -> String {
        switch state { case .queued: L10n.tr("等待下载"); case .downloading: L10n.tr("正在下载"); case .paused: L10n.tr("已暂停"); case .ready: L10n.tr("可离线播放"); case .failed: L10n.tr("下载失败") }
    }
}

struct SyncConflictView: View {
    @Bindable var store: AppStore
    let conflict: SyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 30, weight: .light)).foregroundStyle(ShelfTheme.accent)
            Text(L10n.tr("从哪一段继续？")).font(.title2.bold())
            Text(L10n.tr("这本书在其他设备上有新的收听进度。选择要继续的位置，收听记录会一并保留。")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                position(L10n.tr("这台 Mac"), time: conflict.local.currentTime, choice: .local)
                position(L10n.tr("服务器"), time: conflict.remote.currentTime, choice: .remote)
            }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button(L10n.tr("稍后处理")) { dismiss() }.disabled(busy) }
        }.padding(30).frame(width: 480)
    }
    private func position(_ title: String, time: Double, choice: SyncPositionChoice) -> some View {
        Button {
            busy = true
            Task { await store.resolve(conflict, choice: choice); busy = false }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(time.shelfTime).font(.title2.monospacedDigit().weight(.medium))
                Text(L10n.tr("从这里继续")).font(.caption).foregroundStyle(ShelfTheme.accent)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(ShelfTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(busy)
    }
}

struct ReadingConflictView: View {
    @Bindable var store: AppStore
    let conflict: ReadingConflict
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "book").font(.system(size: 30, weight: .light)).foregroundStyle(ShelfTheme.accent)
            Text(L10n.tr("从哪一页继续？")).font(.title2.bold())
            Text(L10n.tr("这本书在其他设备上有新的阅读位置。选择要继续的位置，音频收听进度会保留。")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                position(L10n.tr("这台 Mac"), value: conflict.local.progress, useLocal: true)
                position(L10n.tr("服务器"), value: conflict.remote.ebookProgress ?? 0, useLocal: false)
            }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button(L10n.tr("稍后处理")) { dismiss() }.disabled(busy) }
        }.padding(30).frame(width: 480)
    }
    private func position(_ title: String, value: Double, useLocal: Bool) -> some View {
        Button { busy = true; Task { await store.resolveReading(conflict, useLocal: useLocal); busy = false } } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text("\(Int(value * 100))%").font(.title2.monospacedDigit().weight(.medium))
                Text(L10n.tr("从这里继续")).font(.caption).foregroundStyle(ShelfTheme.accent)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(ShelfTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(busy)
    }
}
