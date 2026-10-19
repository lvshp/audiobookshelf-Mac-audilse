import Foundation
import Observation
import AudilseCore

struct ContinueListeningChange {
    enum Target { case progress(id: String), series(id: String) }
    let target: Target
    let source: LibraryPersonalSource
    let client: ABSClient
    let user: UserAccount
    @MainActor func isCurrent(_ store: AppStore) -> Bool { source.isCurrent(store) && store.client === client && user.id == store.user?.id }
}

@MainActor @Observable final class ContinueListeningModel {
    let scope: LibraryPersonalScope
    private(set) var hiddenSeries: [BookSeries] = []
    private(set) var isLoaded = false
    @ObservationIgnored private let onChange: @MainActor (ContinueListeningChange) -> Void
    init(store: AppStore, libraryID: String, onChange: @escaping @MainActor (ContinueListeningChange) -> Void = { _ in }) {
        scope = .init(store: store, libraryID: libraryID); self.onChange = onChange
    }
    func load(expectedSource: LibraryPersonalSource? = nil) async {
        guard !Task.isCancelled, expectedSource == nil || expectedSource == scope.identity else { return }
        scope.bind(); hiddenSeries = []; isLoaded = false
        guard let (source, client, generation) = try? scope.context() else { return }
        await scope.run(source: source, generation: generation) {
            let user = try await client.currentUser(); try self.scope.check(source, generation)
            guard user.id == source.partition?.userID else { throw ABSError.invalidResponse }
            let hidden = Set(user.seriesHideFromContinueListening)
            var result: [BookSeries] = []; var page = 0
            if !hidden.isEmpty {
                while true {
                    let response = try await client.series(libraryID: source.libraryID, page: page, limit: 200)
                    try self.scope.check(source, generation)
                    result += response.results.filter { hidden.contains($0.id) && ($0.libraryId == nil || $0.libraryId == source.libraryID) }
                    guard response.hasMore, !response.results.isEmpty else { break }; page += 1
                }
            }
            return result
        } apply: { self.hiddenSeries = $0; self.isLoaded = true }
    }
    func restore(_ series: BookSeries) {
        guard hiddenSeries.contains(where: { $0.id == series.id }), let (source, client, generation) = try? scope.context() else { return }
        scope.confirm(.init(title: L10n.tr("恢复系列续听"), message: L10n.tr("将此系列重新加入当前账户的续听推荐。"), action: {
            await self.scope.run(source: source, generation: generation) {
                let user = try await client.setSeriesHiddenFromContinueListeningResult(id: series.id, hidden: false)
                try self.scope.check(source, generation)
                guard user.id == source.partition?.userID, !user.seriesHideFromContinueListening.contains(series.id) else { throw ABSError.invalidResponse }
                return user
            } apply: { user in
                self.hiddenSeries.removeAll { $0.id == series.id }
                self.onChange(.init(target: .series(id: series.id), source: source, client: client, user: user))
            }
        }))
    }
    /// Root can reuse this for a detail or a precise recentEpisode context menu.
    func hide(item: LibraryItem, episodeID: String? = nil) {
        guard item.libraryId == scope.libraryID, let (source, client, generation) = try? scope.context() else { return }
        scope.confirm(.init(title: L10n.tr("隐藏此项续听"), message: L10n.tr("仅从当前账户的续听书架隐藏；保留进度、下载和书库内容。再次收听并推进播放位置后会重新显示。"), action: {
            await self.scope.run(source: source, generation: generation) {
                let progress = try await client.progress(itemID: item.id, episodeID: episodeID)
                try self.scope.check(source, generation)
                guard progress?.libraryItemId == item.id, progress?.episodeId == episodeID,
                      let id = progress?.serverID, !id.isEmpty else { throw ContinuationError.missingProgress }
                let user = try await client.hideProgressFromContinueListening(progressID: id)
                try self.scope.check(source, generation)
                guard user.id == source.partition?.userID,
                      user.mediaProgress.contains(where: { $0.serverID == id && $0.hideFromContinueListening }) else { throw ABSError.invalidResponse }
                return (user, id)
            } apply: { user, id in
                self.onChange(.init(target: .progress(id: id), source: source, client: client, user: user))
            }
        }))
    }
    func hide(series: BookSeries) {
        guard series.libraryId == scope.libraryID, let (source, client, generation) = try? scope.context() else { return }
        scope.confirm(.init(title: L10n.tr("隐藏系列续听"), message: L10n.tr("仅隐藏当前账户的系列续听推荐；可在续听管理中恢复。"), action: {
            await self.scope.run(source: source, generation: generation) {
                let user = try await client.setSeriesHiddenFromContinueListeningResult(id: series.id, hidden: true)
                try self.scope.check(source, generation)
                guard user.id == source.partition?.userID, user.seriesHideFromContinueListening.contains(series.id) else { throw ABSError.invalidResponse }
                return user
            } apply: { self.onChange(.init(target: .series(id: series.id), source: source, client: client, user: $0)) }
        }))
    }
}

enum ContinuationError: Error, LocalizedError {
    case missingProgress
    var errorDescription: String? { L10n.tr("服务器没有此项的有效进度记录，无法隐藏。") }
}
