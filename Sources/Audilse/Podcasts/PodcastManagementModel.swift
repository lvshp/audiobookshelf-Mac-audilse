import Foundation
import Observation
import AudilseCore

@MainActor @Observable final class PodcastManagementModel {
    var item: AudilseCore.LibraryItem?
    var queue: [PodcastServerDownload] = []
    private(set) var currentDownloadID: String?
    var hasWaitingDownloads: Bool { queue.contains { $0.id != currentDownloadID } }
    var feed: PodcastFeed?
    var rssURL = ""
    var selectedEpisodes: Set<String> = []
    var refreshFailed = false
    @ObservationIgnored private var refreshRequiresAdmin = false
    @ObservationIgnored private var refreshActions: [AdminAction] = []
    var usesCheckDate = false
    var checkDate = Date()
    var checkLimit = 3
    var autoDownload = false
    var schedule = "0 * * * *"
    var maxKeep = 0
    var maxNew = 3
    var isBusy = false
    var error: String?
    var notice: String?
    @ObservationIgnored let account = PodcastAccountSession()
    @ObservationIgnored private var operationID: UUID?
    func bind(_ store: AppStore) { account.bind(store); operationID = store.accountOperationID }
    private var contextIsCurrent: Bool {
        guard let store = account.store else { return false }
        return operationID == store.accountOperationID
    }
    private func snapshot(admin: Bool = false, requiring actions: [AdminAction] = []) throws -> (ABSClient, UUID) {
        guard contextIsCurrent, let store = account.store, !store.isConnecting, !store.recoveryBusy, store.serverRecovery == nil else { throw ABSError.sessionChanged }
        return try account.snapshot(admin: admin, requiring: actions)
    }
    private func isCurrent(_ attempt: UUID) -> Bool { contextIsCurrent && account.isCurrent(attempt) }

    func open(store: AppStore, item: AudilseCore.LibraryItem) async {
        self.item = item
        bind(store)
        isBusy = false; error = nil; notice = nil
        feed = nil; queue = []; currentDownloadID = nil; selectedEpisodes = []; rssURL = ""
        usesCheckDate = false
        checkDate = Date(timeIntervalSince1970: (item.media.lastEpisodeCheck ?? Date().timeIntervalSince1970 * 1000) / 1000)
        refreshFailed = false; refreshRequiresAdmin = false; refreshActions = []
        applySettings(item)
        await reload()
    }
    func cancel() { account.cancel(); operationID = nil; isBusy = false }
    private func applySettings(_ full: AudilseCore.LibraryItem) {
        item = full
        rssURL = full.media.metadata.feedUrl ?? rssURL
        autoDownload = full.media.autoDownloadEpisodes ?? false
        schedule = full.media.autoDownloadSchedule ?? "0 * * * *"
        maxKeep = full.media.maxEpisodesToKeep ?? 0
        maxNew = full.media.maxNewEpisodesToDownload ?? 3
    }
    private func perform<T: Sendable>(confirmedWrite: Bool = false, admin: Bool = true, requiring actions: [AdminAction] = [], operation: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async {
        guard !isBusy else { return }
        let source: (ABSClient, UUID)
        do { source = try snapshot(admin: admin, requiring: actions) }
        catch { self.error = L10n.error(error); return }
        let (client, attempt) = source
        isBusy = true; error = nil; notice = nil
        defer { if isCurrent(attempt) { isBusy = false } }
        do {
            let result = try await account.run(attempt) { try await operation(client) }
            try account.validate(attempt)
            guard isCurrent(attempt) else { return }
            if !confirmedWrite { _ = try snapshot(admin: admin, requiring: actions) }
            apply(result)
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch { if isCurrent(attempt) { self.error = L10n.error(error) } }
    }
    // A confirmed mutation is retained independently of its optional readback.
    // Retrying this path never invokes the original mutation.
    func reload() async {
        guard !isBusy, let id = item?.id else { return }
        let source: (ABSClient, UUID)
        do { source = try snapshot(admin: refreshRequiresAdmin, requiring: refreshActions) }
        catch { self.error = L10n.error(error); refreshFailed = true; return }
        let (client, attempt) = source
        isBusy = true; error = nil
        defer { if isCurrent(attempt) { isBusy = false } }
        do {
            let full = try await account.run(attempt) { try await client.item(id: id) }
            _ = try snapshot(admin: refreshRequiresAdmin, requiring: refreshActions)
            // The item endpoint contains waiting downloads only. The library
            // snapshot includes the active download; scope both parts to this show.
            let downloads = try await account.run(attempt) { try await client.podcastLibraryDownloadQueue(libraryID: full.libraryId) }
            _ = try snapshot(admin: refreshRequiresAdmin, requiring: refreshActions)
            let current = downloads.currentDownload.flatMap { $0.libraryItemId == id ? $0 : nil }
            var seen = Set<String>()
            let queue = ([current].compactMap { $0 } + downloads.queue).filter {
                $0.libraryItemId == id && seen.insert($0.id).inserted
            }
            // Readback must not discard an unsaved settings draft.
            let old = item
            if autoDownload == (old?.media.autoDownloadEpisodes ?? false) { autoDownload = full.media.autoDownloadEpisodes ?? false }
            if schedule == (old?.media.autoDownloadSchedule ?? "0 * * * *") { schedule = full.media.autoDownloadSchedule ?? "0 * * * *" }
            if maxKeep == (old?.media.maxEpisodesToKeep ?? 0) { maxKeep = full.media.maxEpisodesToKeep ?? 0 }
            if maxNew == (old?.media.maxNewEpisodesToDownload ?? 3) { maxNew = full.media.maxNewEpisodesToDownload ?? 3 }
            item = full; self.queue = queue; currentDownloadID = current?.id; refreshFailed = false
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch {
            if isCurrent(attempt) { self.error = L10n.error(error); refreshFailed = true }
        }
    }
    private func mutate<T: Sendable>(requiring actions: [AdminAction] = [], operation: @escaping @Sendable (ABSClient) async throws -> T, confirmed: (T) -> Void) async {
        guard !isBusy, !refreshFailed else { return }
        let source: (ABSClient, UUID)
        do { source = try snapshot(admin: true, requiring: actions) }
        catch { self.error = L10n.error(error); return }
        let (client, attempt) = source
        isBusy = true; error = nil; notice = nil
        do {
            let result = try await account.run(attempt) { try await operation(client) }
            guard isCurrent(attempt) else { return }
            // A successful response remains confirmed if permissions changed while
            // it was in flight. The next read independently rechecks permission.
            confirmed(result)
            refreshRequiresAdmin = true; refreshActions = actions
            isBusy = false
            await reload()
        } catch is CancellationError {} catch ABSError.sessionChanged {} catch {
            if isCurrent(attempt) { self.error = L10n.error(error) }
        }
        if isCurrent(attempt) { isBusy = false }
    }
    func parseFeed() async {
        let url = rssURL.trimmingCharacters(in: .whitespacesAndNewlines)
        await perform(operation: { try await $0.podcastFeed(url: url) }, apply: { self.feed = $0; self.selectedEpisodes = [] })
    }
    func downloadSelected() async {
        guard let item, let feed else { return }
        let episodes = feed.episodes.filter { selectedEpisodes.contains($0.id) }
        guard !episodes.isEmpty else { return }
        await mutate(requiring: [.updateContent], operation: { client in try await client.downloadPodcastEpisodes(itemID: item.id, episodes: episodes) }, confirmed: { self.notice = L10n.tr("已将所选单集加入服务器下载队列。"); self.selectedEpisodes = [] })
    }
    func checkNew() async {
        guard !refreshFailed, let id = item?.id else { return }
        do { _ = try snapshot(admin: true, requiring: usesCheckDate ? [.updateContent] : []) }
        catch { self.error = L10n.error(error); return }
        let originalClient = account.client, originalPartition = account.partition
        var savedDate = false
        guard checkLimit >= 0 else { return }
        let limit = checkLimit
        if usesCheckDate {
            let timestamp = (checkDate.timeIntervalSince1970 * 1000).rounded(.towardZero)
            guard timestamp.isFinite else { return }
            if item?.media.lastEpisodeCheck != timestamp {
                var confirmed = false
                await perform(confirmedWrite: true, admin: false, requiring: [.updateContent], operation: {
                    try await $0.updatePodcastSettings(itemID: id, update: .init(lastEpisodeCheck: timestamp))
                }, apply: {
                    self.item = $0
                    self.notice = L10n.tr("检查起始日期已保存。")
                    confirmed = true
                })
                guard confirmed else { return }
                savedDate = true
            }
        }
        await mutate(operation: { try await $0.checkNewPodcastEpisodes(itemID: id, limit: limit) }, confirmed: {
            self.notice = L10n.format("已检查新单集，服务器返回 %1$@ 集。", String(describing: $0.count))
            self.usesCheckDate = false
        })
        if savedDate, notice == nil, error != nil, item?.id == id, account.client === originalClient, account.partition == originalPartition { notice = L10n.tr("检查起始日期已保存。") }
    }
    func clearQueue() async {
        guard let id = item?.id else { return }
        await mutate(operation: { try await $0.clearPodcastDownloadQueue(itemID: id) }, confirmed: {
            self.notice = L10n.tr("服务器等待队列已清空。")
        })
    }
    func confirmation(admin: Bool = true, requiring actions: [AdminAction] = [], action: @escaping @MainActor () async -> Void) -> (@MainActor () async -> Void)? {
        guard let id = item?.id else { return nil }
        do {
            let (_, attempt) = try snapshot(admin: admin, requiring: actions)
            return { [weak self] in
                guard let self, self.item?.id == id else { return }
                do {
                    try self.account.validate(attempt)
                    _ = try self.snapshot(admin: admin, requiring: actions)
                    await action()
                } catch { if self.isCurrent(attempt) { self.error = L10n.error(error) } }
            }
        } catch { self.error = L10n.error(error); return nil }
    }
    var settingsUpdate: PodcastSettingsUpdate {
        .init(autoDownloadEpisodes: autoDownload, autoDownloadSchedule: schedule, maxEpisodesToKeep: maxKeep, maxNewEpisodesToDownload: maxNew)
    }
    func saveSettings(_ draft: PodcastSettingsUpdate? = nil) async {
        guard let id = item?.id else { return }
        let update = draft ?? settingsUpdate
        guard (update.maxEpisodesToKeep ?? 0) >= 0, (update.maxNewEpisodesToDownload ?? 0) >= 0 else { return }
        await perform(confirmedWrite: true, admin: false, requiring: [.updateContent], operation: { try await $0.updatePodcastSettings(itemID: id, update: update) }, apply: { self.applySettings($0); self.notice = L10n.tr("播客设置已保存。") })
    }
    func saveEpisode(_ episode: PodcastEpisode, title: String, subtitle: String, description: String) async {
        guard let id = item?.id else { return }
        let update = PodcastEpisodeUpdate(title: title, subtitle: subtitle, description: description)
        await perform(confirmedWrite: true, admin: false, requiring: [.updateContent], operation: { try await $0.updatePodcastEpisode(itemID: id, episodeID: episode.id, update: update) }, apply: { self.item = $0; self.notice = L10n.tr("单集信息已保存。") })
    }
    func deleteEpisode(_ episode: PodcastEpisode, deleteFile: Bool) async {
        guard let id = item?.id else { return }
        await perform(confirmedWrite: true, admin: false, requiring: [.deleteContent], operation: { try await $0.deletePodcastEpisode(itemID: id, episodeID: episode.id, deleteFile: deleteFile) }, apply: { self.item = $0; self.notice = deleteFile ? L10n.tr("单集及服务器原文件已删除。") : L10n.tr("已移除单集，保留服务器原文件。") })
    }
    func matchEpisodes(overrideDetails: Bool = false) async {
        guard let id = item?.id else { return }
        await mutate(requiring: [.updateContent], operation: { try await $0.matchPodcastEpisodes(itemID: id, overrideDetails: overrideDetails) }, confirmed: { count in self.notice = L10n.format("已匹配 %1$@ 集的信息。", String(describing: count)) })
    }
}
