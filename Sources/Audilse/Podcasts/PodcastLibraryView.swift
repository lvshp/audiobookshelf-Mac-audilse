import Foundation
import Observation
import SwiftUI
import AudilseCore

@MainActor @Observable private final class PodcastLibraryModel {
    let account = PodcastAccountSession()
    let libraryID: String
    var episodes: [RecentPodcastEpisode] = []
    var queue: [PodcastServerDownload] = []
    var currentDownload: PodcastServerDownload?
    var hasMore = false
    var isBusy = false
    var error: String?
    var selectedItem: AudilseCore.LibraryItem?
    private var page = 0
    init(libraryID: String) { self.libraryID = libraryID }
    @discardableResult private func perform<T: Sendable>(_ operation: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async -> Bool {
        guard !isBusy else { return false }
        let snapshot: (ABSClient, UUID)
        do { snapshot = try account.snapshot() }
        catch { self.error = L10n.error(error); return false }
        let (client, attempt) = snapshot
        isBusy = true; error = nil
        defer { if account.isCurrent(attempt) { isBusy = false } }
        do { let value = try await account.run(attempt) { try await operation(client) }; apply(value); return true }
        catch is CancellationError {} catch ABSError.sessionChanged {} catch let failure as URLError where failure.code == .cancelled {}
        catch { if account.isCurrent(attempt) { self.error = L10n.error(error) } }
        return false
    }
    @discardableResult func loadRecent(more: Bool = false) async -> Bool {
        let requestedPage = more ? page + 1 : 0
        return await perform({ [libraryID] in try await $0.recentPodcastEpisodes(libraryID: libraryID, page: requestedPage) }, apply: { result in
            if more {
                let ids = Set(self.episodes.map(\.id)); self.episodes += result.episodes.filter { !ids.contains($0.id) }
            } else { self.episodes = result.episodes }
            self.page = requestedPage; self.hasMore = result.hasMore
        })
    }
    func loadQueue() async {
        let restricted = account.store?.user.map { !$0.permissions.accessAllTags || !$0.permissions.accessExplicitContent } ?? true
        await perform({ [libraryID] client in
            let payload = try await client.podcastLibraryDownloadQueue(libraryID: libraryID)
            guard restricted else { return payload }
            // ABS's queue endpoint does not apply per-item tag/explicit filters.
            // Verify item access before showing metadata to a restricted account.
            var allowed = Set<String>()
            let ids = Set((payload.queue + [payload.currentDownload].compactMap { $0 }).compactMap(\.libraryItemId))
            for id in ids {
                try Task.checkCancellation()
                do { _ = try await client.item(id: id); allowed.insert(id) }
                catch ABSError.http(let status, _) where status == 403 || status == 404 { }
            }
            var filtered = payload
            filtered.queue = payload.queue.filter { $0.libraryItemId.map(allowed.contains) == true }
            if let current = payload.currentDownload, current.libraryItemId.map(allowed.contains) != true { filtered.currentDownload = nil }
            return filtered
        }, apply: { self.queue = $0.queue; self.currentDownload = $0.currentDownload })
    }
    func open(itemID: String) async {
        await perform({ try await $0.item(id: itemID) }, apply: { self.selectedItem = $0 })
    }
    func play(_ row: RecentPodcastEpisode, store: AppStore, enqueue: Bool) async {
        let snapshot: (ABSClient, UUID)
        do { snapshot = try account.snapshot() } catch { self.error = L10n.error(error); return }
        let (client, attempt) = snapshot
        do {
            let item = try await account.run(attempt) { try await client.item(id: row.libraryItemId) }
            guard let episode = item.media.episodes.first(where: { $0.id == row.id }) else { throw ABSError.invalidResponse }
            if enqueue { store.player?.enqueue(store.playbackMedia(item, episode: episode)) }
            else { await store.play(item, episode: episode) }
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch let failure as URLError where failure.code == .cancelled {}
        catch { if account.isCurrent(attempt) { self.error = L10n.error(error) } }
    }
    func finish(_ row: RecentPodcastEpisode, store: AppStore) async {
        guard let expectedPartition = account.partition else { return }
        let succeeded = await perform({ client in
            try await client.setPodcastEpisodeFinished(itemID: row.libraryItemId, episodeID: row.id, isFinished: true)
        }, apply: { _ in
            // The server filters completed episodes before applying its offset.
            // Restart pagination so removing one cannot skip the next unseen row.
            self.episodes = []; self.page = 0; self.hasMore = false
        })
        guard succeeded else { return }
        guard await loadRecent() else { return }
        await perform({ client in
            if let progress = try await client.progress(itemID: row.libraryItemId, episodeID: row.id) {
                try await store.applyConfirmedProgress(progress, expectedPartition: expectedPartition, expectedClient: client)
            }
        }, apply: { _ in })
    }
}

/// Root integrates this for a podcast library without changing the library route.
struct PodcastLibraryView: View {
    let store: AppStore
    let library: Library
    @State private var model: PodcastLibraryModel
    @State private var tab = 0
    @State private var finishConfirmation: RecentPodcastEpisode?
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, library: Library) {
        self.store = store; self.library = library; _model = State(initialValue: .init(libraryID: library.id))
    }
    var body: some View {
        VStack(spacing: 14) {
            HStack { VStack(alignment: .leading) { Text(library.name).font(.title2.bold()); Text(L10n.tr("最新未完成单集与服务器下载队列")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if model.isBusy { ProgressView().controlSize(.small) }; Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(.horizontal, 20).padding(.top, 20)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20) }
            TabView(selection: $tab) {
                VStack(spacing: 10) {
                    HStack { Text(L10n.tr("按发布日期排序，仅显示尚未听完的单集")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("刷新")) { Task { await model.loadRecent() } }.disabled(model.isBusy) }.padding(.horizontal, 14)
                    List(model.episodes) { row in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Button(row.podcast.metadata.title.isEmpty ? L10n.tr("播客") : row.podcast.metadata.title) { Task { await model.open(itemID: row.libraryItemId) } }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                Text(row.episode.title).font(.headline)
                                if let stamp = row.episode.publishedAt { Text(Date(timeIntervalSince1970: stamp / 1000), style: .date).font(.caption).foregroundStyle(.secondary) }
                                if let summary = row.episode.subtitle ?? row.episode.description { Text(summary.shelfPlainText).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                            Spacer()
                            Button { Task { await model.play(row, store: store, enqueue: false) } } label: { Image(systemName: "play.circle.fill").font(.title2) }.help(L10n.tr("播放单集"))
                            Button { Task { await model.play(row, store: store, enqueue: true) } } label: { Image(systemName: "text.badge.plus") }.help(L10n.tr("加入待播队列"))
                            Button { finishConfirmation = row } label: { Image(systemName: "checkmark.circle") }.help(L10n.tr("标记为已听完"))
                        }.buttonStyle(.borderless).padding(.vertical, 8).disabled(model.isBusy)
                    }.listStyle(.inset)
                    if model.hasMore { Button(L10n.tr("加载更多单集")) { Task { await model.loadRecent(more: true) } }.disabled(model.isBusy).padding(.bottom, 12) }
                }.tabItem { Label(L10n.tr("最新单集"), systemImage: "clock") }.tag(0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(L10n.tr("此书库的服务器下载，约每 5 秒刷新")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("刷新")) { Task { await model.loadQueue() } }.disabled(model.isBusy) }.padding(.horizontal, 14)
                    if model.currentDownload == nil, model.queue.isEmpty { ContentUnavailableView(L10n.tr("暂无服务器下载"), systemImage: "checkmark.circle") }
                    List {
                        if let current = model.currentDownload { Section(L10n.tr("正在下载")) { queueRow(current) } }
                        if !model.queue.isEmpty { Section(L10n.format("等待下载 · %1$@ 集", String(describing: model.queue.count))) { ForEach(model.queue) { queueRow($0) } } }
                    }.listStyle(.inset)
                }.tabItem { Label(L10n.tr("服务器队列"), systemImage: "arrow.down.circle") }.tag(1)
            }.padding(.horizontal, 14).padding(.bottom, 14)
        }.frame(width: 850, height: 650)
        .task { model.account.bind(store); await model.loadRecent() }
        .task(id: tab) {
            guard tab == 1 else { return }
            while !Task.isCancelled {
                await model.loadQueue()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onChange(of: store.partition) { _, _ in model.account.cancel(); dismiss() }
        .onDisappear { model.account.cancel() }
        .sheet(item: $model.selectedItem) { PodcastManagementView(store: store, item: $0) }
        .alert(L10n.tr("标记单集为已听完？"), isPresented: Binding(get: { finishConfirmation != nil }, set: { if !$0 { finishConfirmation = nil } })) {
            Button(L10n.tr("标记已听完")) { if let row = finishConfirmation { Task { await model.finish(row, store: store) }; finishConfirmation = nil } }
            Button(L10n.tr("取消"), role: .cancel) { finishConfirmation = nil }
        } message: { Text(L10n.tr("该单集会从最新未完成单集中移除，已有收听位置会保留。")) }
    }
    private func queueRow(_ download: PodcastServerDownload) -> some View {
        HStack { VStack(alignment: .leading, spacing: 5) { Text(download.episodeDisplayTitle ?? L10n.tr("播客单集")); Text(download.podcastTitle ?? "").font(.caption).foregroundStyle(.secondary) }; Spacer(); if let id = download.libraryItemId { Button(L10n.tr("查看节目")) { Task { await model.open(itemID: id) } }.disabled(model.isBusy) } }.padding(.vertical, 7)
    }
}
