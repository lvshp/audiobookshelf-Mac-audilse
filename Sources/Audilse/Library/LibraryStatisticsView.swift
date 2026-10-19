import SwiftUI
import AudilseCore

struct LibraryStatisticsView: View {
    let store: AppStore
    let library: Library
    var origin: LibraryStatisticsSource? = nil
    var onNavigate: () -> Void = {}
    @State private var model = LibraryStatisticsModel()
    @State private var authorTarget: LibraryStatisticsAuthorTarget?
    @Environment(\.dismiss) private var dismiss
    private var source: LibraryStatisticsSource? {
        guard let current = LibraryStatisticsSource(store: store, library: library) else { return nil }
        if let origin {
            guard current.partition == origin.partition, current.baseURL == origin.baseURL,
                  current.client === origin.client, current.library.id == origin.library.id,
                  current.library.mediaType == origin.library.mediaType else { return nil }
        }
        return current
    }

    var body: some View {
        let request = source
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("书库统计")).font(.title2.bold())
                    Text(library.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isBound(to: store, library: library), model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.load(store: store, library: library, expected: request) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(request == nil || model.isLoading)
                    .help(L10n.tr("刷新书库统计")).accessibilityLabel(L10n.tr("刷新书库统计"))
                SheetCloseButton(identifier: "library-statistics.close") { model.cancel(); dismiss() }
            }.padding(20)
            Divider()
            if request == nil {
                ContentUnavailableView(L10n.tr("书库统计暂不可用"), systemImage: "chart.bar.xaxis",
                                       description: Text(L10n.tr("请在线连接并使用有权访问此书库的管理员账户。")))
            } else if model.isBound(to: store, library: library) {
                if let error = model.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button(L10n.tr("重试")) { Task { await model.load(store: store, library: library, expected: request) } }.disabled(model.isLoading)
                    }.font(.callout).padding(16)
                }
                if let statistics = model.statistics {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            metrics(statistics)
                            HStack(alignment: .firstTextBaseline) {
                                Text(L10n.tr("服务器报告的当前书库馆藏；不是个人收听统计。")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let date = model.updatedAt { Text(date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            if let error = model.itemError { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                            if model.isOpeningItem { ProgressView(L10n.tr("正在读取详情…")).controlSize(.small) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), alignment: .top)], alignment: .leading, spacing: 20) {
                                genres(statistics, renderedSource: request)
                                if library.mediaType == "book" { authors(statistics, renderedSource: request) }
                                longest(statistics, renderedSource: request)
                                largest(statistics, renderedSource: request)
                            }
                        }.padding(24)
                    }
                } else if model.isLoading { ProgressView(L10n.tr("正在加载书库统计…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if model.error == nil { ContentUnavailableView(L10n.tr("尚未加载书库统计"), systemImage: "chart.bar.xaxis") }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(minWidth: 820, idealWidth: 1080, minHeight: 640, idealHeight: 780)
        .task(id: request) { await model.load(store: store, library: library, expected: request) }
        .onChange(of: request) { _, _ in authorTarget = nil }
        .onDisappear { model.cancel() }
        .sheet(item: $authorTarget) { target in
            if target.source.isCurrent(store), model.isBound(to: store, library: library) {
                FeatureGroupDetailView(store: store, kind: .authors, initial: .init(id: target.author.id, title: target.author.name, summary: "", count: target.author.count, libraryID: library.id))
            }
        }
        .sheet(item: Binding(get: { model.isBound(to: store, library: library) ? model.openedItem : nil }, set: { model.openedItem = $0 })) { item in
            ItemDetailView(store: store, item: item)
        }
    }

    private func metrics(_ statistics: LibraryStatistics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
            metric(L10n.tr("馆藏条目"), value: number(statistics.totalItems), symbol: "books.vertical")
            metric(L10n.tr("书库总时长"), value: duration(statistics.totalDuration), symbol: "clock")
            if library.mediaType == "book" { metric(L10n.tr("作者"), value: statistics.totalAuthors.map(number) ?? "—", symbol: "person.2") }
            metric(L10n.tr("类型"), value: number(statistics.totalGenres), symbol: "tag")
            metric(L10n.tr("书库总大小"), value: bytes(statistics.totalSize), symbol: "externaldrive")
            metric(library.mediaType == "podcast" ? L10n.tr("剧集记录") : L10n.tr("音轨数"), value: number(statistics.numAudioTracks), symbol: "waveform")
        }
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit().lineLimit(2).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, minHeight: 78, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
    }
    private func genres(_ statistics: LibraryStatistics, renderedSource: LibraryStatisticsSource?) -> some View {
        ranking(title: L10n.tr("前 5 个类型"), empty: statistics.genresWithCount.isEmpty) {
            ForEach(Array(statistics.genresWithCount.prefix(5).enumerated()), id: \.offset) { _, entry in
                Button {
                    guard let renderedSource, renderedSource.isCurrent(store), model.isBound(to: store, library: library), model.source == renderedSource else { return }
                    store.browse(libraryID: library.id, filter: .genre(entry.genre))
                    model.cancel(); onNavigate(); dismiss()
                } label: {
                    rankRow(title: entry.genre, value: L10n.format("%1$@ 条 · %2$@", number(entry.count), percent(entry.count, total: statistics.totalItems)), fraction: fraction(Double(entry.count), total: Double(statistics.totalItems)))
                }.buttonStyle(.plain).accessibilityLabel(L10n.format("浏览类型 %1$@", entry.genre))
            }
        }
    }
    private func authors(_ statistics: LibraryStatistics, renderedSource: LibraryStatisticsSource?) -> some View {
        let entries = statistics.authorsWithCount ?? []
        return ranking(title: L10n.tr("前 10 位作者"), empty: entries.isEmpty) {
            ForEach(Array(entries.prefix(10).enumerated()), id: \.offset) { index, author in
                Button {
                    guard let renderedSource, renderedSource.isCurrent(store), model.isBound(to: store, library: library), model.source == renderedSource else { return }
                    authorTarget = .init(source: renderedSource, author: author)
                } label: {
                    rankRow(title: "\(index + 1). " + author.name, value: L10n.format("%1$@ 条", number(author.count)), fraction: fraction(Double(author.count), total: Double(entries.map(\.count).max() ?? 0)))
                }.buttonStyle(.plain).accessibilityLabel(L10n.format("查看作者 %1$@", author.name))
            }
        }
    }
    private func longest(_ statistics: LibraryStatistics, renderedSource: LibraryStatisticsSource?) -> some View {
        ranking(title: L10n.tr("时长最长的 10 个条目"), empty: statistics.longestItems.isEmpty) {
            ForEach(Array(statistics.longestItems.prefix(10).enumerated()), id: \.offset) { index, entry in
                Button {
                    guard let renderedSource, renderedSource.isCurrent(store), model.isBound(to: store, library: library), model.source == renderedSource else { return }
                    model.openItem(id: entry.id, store: store, library: library)
                } label: {
                    rankRow(title: "\(index + 1). " + entry.title, value: entry.duration.map(duration) ?? "—", fraction: fraction(entry.duration ?? 0, total: statistics.longestItems.compactMap(\.duration).max() ?? 0))
                }.buttonStyle(.plain).disabled(model.isOpeningItem).accessibilityLabel(L10n.format("查看 %1$@", entry.title))
            }
        }
    }
    private func largest(_ statistics: LibraryStatistics, renderedSource: LibraryStatisticsSource?) -> some View {
        ranking(title: L10n.tr("体积最大的 10 个条目"), empty: statistics.largestItems.isEmpty) {
            ForEach(Array(statistics.largestItems.prefix(10).enumerated()), id: \.offset) { index, entry in
                Button {
                    guard let renderedSource, renderedSource.isCurrent(store), model.isBound(to: store, library: library), model.source == renderedSource else { return }
                    model.openItem(id: entry.id, store: store, library: library)
                } label: {
                    rankRow(title: "\(index + 1). " + entry.title, value: bytes(entry.size), fraction: fraction(entry.size, total: statistics.largestItems.map(\.size).max() ?? 0))
                }.buttonStyle(.plain).disabled(model.isOpeningItem).accessibilityLabel(L10n.format("查看 %1$@", entry.title))
            }
        }
    }
    private func ranking<Content: View>(title: String, empty: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if empty { Text(L10n.tr("暂无统计条目")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12) }
            else { content() }
        }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
    private func rankRow(title: String, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) { Text(title).font(.callout).lineLimit(2).multilineTextAlignment(.leading); Spacer(minLength: 12); Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false) }
            ProgressView(value: fraction).tint(.accentColor).accessibilityHidden(true)
        }.padding(.vertical, 4).contentShape(Rectangle()).help(title).accessibilityElement(children: .combine)
    }
    private func fraction(_ value: Double, total: Double) -> Double { total.isFinite && total > 0 && value.isFinite ? min(1, max(0, value / total)) : 0 }
    private func number(_ value: Int) -> String { value.formatted(.number.locale(AppLanguageStore.shared.selection.locale)) }
    private func percent(_ value: Int, total: Int) -> String { fraction(Double(value), total: Double(total)).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguageStore.shared.selection.locale)) }
    private func duration(_ value: Double) -> String {
        let seconds = max(0, min(value.isFinite ? value : 0, Double(Int64.max / 2)))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
            .locale(AppLanguageStore.shared.selection.locale))
    }
    private func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max - 1024), max(0, value.isFinite ? value : 0))), countStyle: .file) }
}

private struct LibraryStatisticsAuthorTarget: Identifiable {
    let id = UUID()
    let source: LibraryStatisticsSource
    let author: LibraryStatisticsAuthor
}
