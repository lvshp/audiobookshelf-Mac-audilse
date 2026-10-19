import AppKit
import AudilseCore
import SwiftUI

struct ServerStatisticsView: View {
    let store: AppStore
    @State private var model = ServerStatisticsModel()
    @State private var yearRefresh = UUID()
    @State private var storageRefresh = UUID()

    private struct YearRequest: Hashable { let source: ServerStatisticsSource?; let year: Int; let refresh: UUID }
    private struct StorageRequest: Hashable { let source: ServerStatisticsSource?; let refresh: UUID }

    var body: some View {
        let source = ServerStatisticsSource(store: store)
        let yearRequest = YearRequest(source: source, year: model.selectedYear, refresh: yearRefresh)
        let storageRequest = StorageRequest(source: source, refresh: storageRefresh)
        Group {
            if source == nil {
                ContentUnavailableView(L10n.tr("服务器年度回顾"), systemImage: "chart.bar.xaxis", description: Text(L10n.tr("请使用管理员或根账户在线查看服务器统计。")))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if model.isBound(to: store) {
                            annual
                            storage
                        } else { ProgressView(L10n.tr("正在读取服务器统计…")).frame(maxWidth: .infinity, minHeight: 200) }
                    }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: yearRequest) { await model.loadYear(store: store, source: yearRequest.source, year: yearRequest.year) }
        .task(id: storageRequest) { await model.loadStorage(store: store, source: storageRequest.source) }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) { heading; Spacer(); controls }
            VStack(alignment: .leading, spacing: 12) { heading; controls }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("服务器年度回顾")).font(.title2.bold())
            Text(L10n.tr("馆藏总计由服务器提供，部分版本可能包含所选年份之后新增的内容。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            if !model.availableYears.isEmpty {
                Picker(L10n.tr("年份"), selection: $model.selectedYear) { ForEach(model.availableYears, id: \.self) { year in Text(String(year)).tag(year) } }
                    .pickerStyle(.menu).frame(width: 140).accessibilityIdentifier("server-statistics.year")
            }
            Button(L10n.tr("刷新"), systemImage: "arrow.clockwise") { yearRefresh = UUID(); storageRefresh = UUID() }
                .disabled(!model.isBound(to: store)).accessibilityIdentifier("server-statistics.refresh")
        }
    }
    private var annual: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.format("%1$@ 年度概览", String(model.selectedYear))).font(.title3.bold())
                Spacer()
                if model.isYearLoading { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在读取年度统计…")) }
            }
            if model.isYearBound(to: store) {
                if let error = model.yearError {
                    failure(error) { yearRefresh = UUID() }.accessibilityIdentifier("server-statistics.year-retry")
                }
                if let data = model.yearly {
                    metrics(data)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) { rankings(data) }
                        VStack(spacing: 14) { rankings(data) }
                    }
                    if let updated = model.yearUpdatedAt { updatedAt(updated) }
                    Divider().padding(.vertical, 4)
                    ServerStatisticsReviewView(store: store, year: model.selectedYear, statistics: data)
                } else if !model.isYearLoading && model.yearError == nil {
                    Text(L10n.tr("暂无记录")).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func metrics(_ data: AdminYearlyStatistics) -> some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 175), spacing: 14)], spacing: 14) {
            metric(L10n.tr("新增书籍"), value: String(data.numBooksAdded), symbol: "books.vertical")
            metric(L10n.tr("新增作者"), value: String(data.numAuthorsAdded), symbol: "person.badge.plus")
            metric(L10n.tr("收听会话"), value: String(data.numListeningSessions), symbol: "headphones")
            metric(L10n.tr("年度收听"), value: yearReviewHours(data.totalListeningTime), symbol: "clock")
            metric(L10n.tr("服务端馆藏总计"), value: String(data.numBooks), symbol: "building.columns")
            metric(L10n.tr("服务端馆藏大小"), value: serverStatisticsBytes(data.totalBooksSize), symbol: "externaldrive")
            metric(L10n.tr("本年新增容量"), value: serverStatisticsBytes(data.totalBooksAddedSize), symbol: "plus.circle")
            metric(L10n.tr("服务端馆藏时长"), value: yearReviewHours(data.totalBooksDuration), symbol: "waveform")
            metric(L10n.tr("本年新增时长"), value: yearReviewHours(data.totalBooksAddedDuration), symbol: "clock.badge.plus")
        }
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func rankings(_ data: AdminYearlyStatistics) -> some View {
        ServerStatisticsRanking(title: L10n.tr("最常听的作者"), ranks: data.topAuthors, genre: false)
        ServerStatisticsRanking(title: L10n.tr("最常听的旁白"), ranks: data.topNarrators, genre: false)
        ServerStatisticsRanking(title: L10n.tr("最常听的分类"), ranks: data.topGenres, genre: true)
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().padding(.vertical, 4)
            HStack {
                Text(L10n.tr("当前服务器存储")).font(.title3.bold())
                Spacer()
                if model.isStorageLoading { ProgressView().controlSize(.small).accessibilityLabel(L10n.tr("正在读取存储统计…")) }
            }
            if let error = model.storageError {
                failure(error) { storageRefresh = UUID() }.accessibilityIdentifier("server-statistics.storage-retry")
            }
            if let data = model.storage {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    GridRow { Text(L10n.tr("类型")); Text(L10n.tr("内容数量")); Text(L10n.tr("音频文件")); Text(L10n.tr("容量")) }.font(.caption).foregroundStyle(.secondary)
                    storageRow(L10n.tr("书籍"), group: data.books)
                    storageRow(L10n.tr("播客"), group: data.podcasts)
                    storageRow(L10n.tr("合计"), group: data.total)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                if let updated = model.storageUpdatedAt { updatedAt(updated) }
            }
        }
    }
    private func storageRow(_ title: String, group: ServerStorageStatistics.Group) -> some View {
        GridRow { Text(title).fontWeight(.medium); Text(String(group.numItems)).monospacedDigit(); Text(String(group.numAudioFiles)).monospacedDigit(); Text(serverStatisticsBytes(group.totalSize)).monospacedDigit() }
    }
    private func failure(_ error: String, retry: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("重试"), action: retry)
        }.padding(14).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
    private func updatedAt(_ date: Date) -> some View {
        Text(L10n.format("更新于 %1$@", date.formatted(.dateTime.year().month().day().hour().minute().locale(AppLanguageStore.shared.selection.locale))))
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct ServerStatisticsRanking: View {
    let title: String
    let ranks: [StatisticsRank]
    let genre: Bool
    private var maximum: Double { ranks.map(\.time).filter(\.isFinite).max() ?? 0 }
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 16) {
                if ranks.isEmpty { Text(L10n.tr("暂无记录")).font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(ranks.prefix(3).enumerated()), id: \.offset) { index, rank in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(index + 1)).foregroundStyle(.secondary).monospacedDigit()
                            Text((genre ? rank.genre : rank.name) ?? L10n.tr("未知")).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            Text(yearReviewHours(rank.time)).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        ProgressView(value: maximum > 0 && rank.time.isFinite ? max(0, min(1, rank.time / maximum)) : 0)
                            .accessibilityHidden(true)
                    }.accessibilityElement(children: .combine)
                }
            }.padding(8).frame(minWidth: 195, maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

func serverStatisticsBytes(_ value: Double) -> String {
    let positive = max(0, value.isFinite ? value : 0)
    let bytes = Int64(exactly: positive.rounded(.down)) ?? Int64.max
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
