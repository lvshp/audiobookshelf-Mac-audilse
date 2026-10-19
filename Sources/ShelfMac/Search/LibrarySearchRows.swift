import SwiftUI
import ShelfCore

enum LibrarySearchCategory: String, CaseIterable, Identifiable {
    case books, podcasts, episodes, authors, series, tags, genres, narrators
    var id: String { rawValue }
    var title: String {
        switch self {
        case .books: L10n.tr("书籍")
        case .podcasts: L10n.tr("节目")
        case .episodes: L10n.tr("单集")
        case .authors: L10n.tr("作者")
        case .series: L10n.tr("系列")
        case .tags: L10n.tr("标签")
        case .genres: L10n.tr("类型")
        case .narrators: L10n.tr("朗读者")
        }
    }
    func rows(in response: LibrarySearchResponse) -> [LibrarySearchRowValue] {
        switch self {
        case .books: response.books.map { .item($0.libraryItem) }
        case .podcasts: response.podcasts.map { .item($0.libraryItem) }
        case .episodes: response.episodes.map { .item($0.libraryItem) }
        case .authors: response.authors.map { .author($0) }
        case .series: response.series.map { .series($0) }
        case .tags: response.tags.map { .taxonomy($0.name, $0.numItems, .tag($0.name), "tag") }
        case .genres: response.genres.map { .taxonomy($0.name, $0.numItems, .genre($0.name), "square.grid.2x2") }
        case .narrators: response.narrators.map { .taxonomy($0.name, $0.numBooks, .narrator($0.name), "waveform") }
        }
    }
}

enum LibrarySearchRowValue: Identifiable {
    case item(LibraryBrowseEntry)
    case author(Author)
    case series(LibrarySearchSeriesMatch)
    case taxonomy(String, Int, LibraryBrowseFilter, String)
    var id: String {
        switch self {
        case .item(let entry): "item:" + entry.id
        case .author(let author): "author:" + author.id
        case .series(let match): "series:" + match.id
        case .taxonomy(let name, _, let filter, _): "taxonomy:" + (filter.queryValue ?? name)
        }
    }
}

struct LibrarySearchResultRow: View {
    @Bindable var store: AppStore
    let value: LibrarySearchRowValue
    let library: Library
    let model: LibrarySearchModel
    let actions: LibrarySearchActions
    let source: LibrarySearchActionSource

    var body: some View {
        HStack(spacing: 14) {
            artwork
            Button { invoke(primaryCommand) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let progressLabel { Text(progressLabel).font(.caption2).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityHint(primaryHint)
            if canPlay, case .item(let entry) = value {
                Button { invoke(.play(entry)) } label: { Image(systemName: "play.circle.fill").font(.system(size: 25)).foregroundStyle(ShelfTheme.accent) }
                    .buttonStyle(.plain).help(L10n.tr("播放"))
                    .accessibilityLabel(L10n.format("播放 %1$@", title))
                Button { invoke(.enqueue(entry)) } label: { Image(systemName: "text.badge.plus").font(.system(size: 16)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help(L10n.tr("加入待播队列"))
                    .accessibilityLabel(L10n.format("加入待播队列：%1$@", title))
                    .disabled(store.player == nil)
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }.padding(.vertical, 10).padding(.horizontal, 12)
            .background(ShelfTheme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
            .disabled(!source.isCurrent(store, model: model))
            .accessibilityIdentifier("search.result." + library.id + "." + value.id)
    }
    @ViewBuilder private var artwork: some View {
        if case .item(let entry) = value {
            let cover = source.isCurrent(store, model: model) ? source.request.coverSource.request(item: entry.item, store: store) : nil
            CoverView(item: entry.item, url: cover?.url, client: cover?.client,
                      accountKey: cover?.accountKey ?? "none", showTitle: false)
                .frame(width: 44, height: 54).accessibilityHidden(true)
        } else {
            Image(systemName: symbol).font(.system(size: 21, weight: .light)).foregroundStyle(ShelfTheme.accent)
                .frame(width: 44, height: 54).background(ShelfTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
        }
    }
    private var title: String {
        switch value {
        case .item(let entry): entry.recentEpisode?.title ?? entry.item.title
        case .author(let author): author.name
        case .series(let match): match.series.name
        case .taxonomy(let name, _, _, _): name
        }
    }
    private var subtitle: String {
        switch value {
        case .item(let entry):
            if let episode = entry.recentEpisode { return entry.item.title + " · " + (episode.duration ?? 0).shelfDuration }
            return entry.item.mediaType == "podcast" ? entry.item.authorName : entry.item.authorName + " · " + entry.item.media.duration.shelfDuration
        case .author(let author): return L10n.format("服务器目录计数：%1$@", String(author.numBooks))
        case .series(let match): return L10n.format("搜索预览 %1$@ 本 · 打开载入完整系列", String(match.books.count))
        case .taxonomy(_, let count, _, _): return L10n.format("服务器目录计数：%1$@", String(count))
        }
    }
    private var progressLabel: String? {
        guard case .item(let entry) = value else { return nil }
        let key = entry.recentEpisode.map { entry.item.id + ":" + $0.id } ?? entry.item.id
        guard let progress = store.progressByItem[key] else { return nil }
        if progress.isFinished { return L10n.tr("已完成") }
        return L10n.format("进度 %1$@%%", String(Int(LibraryProgressOrdering.fraction(for: progress) * 100)))
    }
    private var canPlay: Bool {
        guard case .item(let entry) = value, !entry.item.isMissing, !entry.item.isInvalid else { return false }
        if let episode = entry.recentEpisode { return HomeActions.isPlayable(episode) }
        return entry.item.mediaType == "book" && HomeActions.hasAudio(entry)
    }
    private var symbol: String {
        switch value { case .author: "person"; case .series: "books.vertical"; case .taxonomy(_, _, _, let symbol): symbol; case .item: "book" }
    }
    private var primaryHint: String {
        switch value {
        case .item: L10n.tr("查看详情")
        case .author: L10n.tr("查看作者的完整书籍列表")
        case .series: L10n.tr("查看系列的完整书籍列表")
        case .taxonomy: L10n.tr("在来源书库中浏览此筛选")
        }
    }
    private var primaryCommand: LibrarySearchCommand {
        switch value {
        case .item(let entry): .open(entry)
        case .author(let author): .author(author)
        case .series(let match): .series(match)
        case .taxonomy(_, _, let filter, _): .browse(filter)
        }
    }
    private func invoke(_ command: LibrarySearchCommand) {
        actions.start(command, libraryID: library.id, store: store, model: model, source: source)
    }
}
