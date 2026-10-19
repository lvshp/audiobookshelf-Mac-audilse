import AppKit
import AudilseCore
import SwiftUI

struct ServerStatisticsReviewView: View {
    let store: AppStore
    let year: Int
    let statistics: AdminYearlyStatistics
    @State private var covers = YearReviewCoverModel()
    @State private var loadedCoverRequest: CoverRequest?

    private struct CoverRequest: Hashable {
        let source: ServerStatisticsSource?
        let year: Int
        let ids: [String]
    }
    private var styles: [YearReviewStyle] {
        [
            .init(id: 0, title: L10n.tr("新增书籍"), size: .init(width: 800, height: 800)),
            .init(id: 1, title: L10n.tr("作者与旁白"), size: .init(width: 800, height: 800)),
            .init(id: 2, title: L10n.tr("作者与分类"), size: .init(width: 800, height: 800))
        ]
    }
    var body: some View {
        let request = CoverRequest(source: ServerStatisticsSource(store: store), year: year, ids: statistics.booksAddedWithCovers)
        let isPreparing = covers.isLoading || loadedCoverRequest != request
        VStack(alignment: .leading, spacing: 12) {
            if request.source != nil {
                if isPreparing { ProgressView(L10n.tr("正在读取回顾封面…")).controlSize(.small) }
                else if covers.unavailableCount > 0 { Text(L10n.tr("部分封面无法读取，回顾数值不受影响。")).font(.caption).foregroundStyle(.secondary) }
                YearReviewGallery(title: L10n.tr("分享服务器年度回顾"), filename: "Audilse-server-\(year)", styles: styles,
                                  revision: "\(request.source?.hashValue ?? 0)|\(year)|\(statistics.hashValue)|\(covers.revision)", isPreparing: isPreparing) { style in
                    ServerStatisticsReviewPoster(year: year, statistics: statistics, style: style, covers: covers.images)
                }
            }
        }
        .task(id: request) {
            guard !Task.isCancelled, request.source?.isCurrent(store: store) == true else { return }
            loadedCoverRequest = nil
            await covers.load(store: store, ids: request.ids)
            guard !Task.isCancelled, request.source?.isCurrent(store: store) == true else { return }
            loadedCoverRequest = request
        }
    }
}

/// A synchronous fixed-size poster; preview and exports share this exact content.
struct ServerStatisticsReviewPoster: View {
    let year: Int
    let statistics: AdminYearlyStatistics
    let style: Int
    let covers: [String: NSImage]
    private var backgroundCovers: [NSImage] {
        var seen = Set<String>()
        return statistics.booksAddedWithCovers.filter { seen.insert($0).inserted }.prefix(25).compactMap { covers[$0] }
    }
    var body: some View {
        YearReviewCanvas(title: L10n.format("%1$@ 服务器年度回顾", String(year)), covers: backgroundCovers) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    YearReviewMetric(label: L10n.tr("新增书籍"), value: String(statistics.numBooksAdded), symbol: "books.vertical", compact: true)
                    YearReviewMetric(label: L10n.tr("新增作者"), value: String(statistics.numAuthorsAdded), symbol: "person.badge.plus", compact: true)
                    YearReviewMetric(label: L10n.tr("收听会话"), value: String(statistics.numListeningSessions), symbol: "headphones", compact: true)
                }
                HStack(spacing: 20) {
                    summary(L10n.tr("服务端馆藏总计"), value: String(statistics.numBooks))
                    summary(L10n.tr("年度收听"), value: yearReviewHours(statistics.totalListeningTime))
                }
                HStack(alignment: .top, spacing: 16) {
                    growth(totalLabel: L10n.tr("服务端馆藏大小"), total: serverStatisticsBytes(statistics.totalBooksSize), addedLabel: L10n.tr("本年新增容量"), added: serverStatisticsBytes(statistics.totalBooksAddedSize))
                    growth(totalLabel: L10n.tr("服务端馆藏时长"), total: yearReviewHours(statistics.totalBooksDuration), addedLabel: L10n.tr("本年新增时长"), added: yearReviewHours(statistics.totalBooksAddedDuration))
                }
                if style == 0 {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.tr("这一年新增的书籍")).font(.system(size: 22, weight: .semibold))
                        YearReviewCoverStrip(ids: statistics.booksAddedWithCovers, covers: covers)
                        if statistics.numBooksAdded == 0 { Text(L10n.tr("这一年还没有新增书籍。")).font(.system(size: 20)).foregroundStyle(.white.opacity(0.75)) }
                        else if statistics.booksAddedWithCovers.isEmpty { Text(L10n.tr("新增书籍没有可用封面。")).font(.system(size: 20)).foregroundStyle(.white.opacity(0.75)) }
                    }.frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).padding(.top, 10)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        YearReviewRanking(title: L10n.tr("最常听的作者"), names: statistics.topAuthors.prefix(3).map { $0.name ?? L10n.tr("未知") })
                        if style == 1 {
                            YearReviewRanking(title: L10n.tr("最常听的旁白"), names: statistics.topNarrators.prefix(3).map { $0.name ?? L10n.tr("未知") })
                        } else {
                            YearReviewRanking(title: L10n.tr("最常听的分类"), names: statistics.topGenres.prefix(3).map { $0.genre ?? L10n.tr("未知") })
                        }
                    }.frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                }
                Text(L10n.tr("馆藏总计由服务器提供，部分版本可能包含所选年份之后新增的内容。"))
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func summary(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func growth(totalLabel: String, total: String, addedLabel: String, added: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(totalLabel).font(.system(size: 15)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            Text(total).font(.system(size: 29, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(addedLabel + " · +" + added).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
