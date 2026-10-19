import AppKit
import ShelfCore
import SwiftUI

struct PersonalYearReviewView: View {
    let store: AppStore
    let year: Int
    let statistics: YearlyStatistics
    @State private var covers = YearReviewCoverModel()
    @State private var loadedCoverRequest: CoverRequest?
    private struct CoverRequest: Hashable { let account: String; let year: Int; let ids: [String] }

    private var coverIDs: [String] { statistics.finishedBooksWithCovers + statistics.booksWithCovers }
    private var accountKey: String { (store.partition?.directoryName ?? "") + (store.client.map { String(describing: ObjectIdentifier($0)) } ?? "") + "|\(store.isOffline)|\(store.isConnecting)|\(store.user?.isActive == true)" }
    private var styles: [YearReviewStyle] {
        [
            .init(id: 0, title: L10n.tr("收听亮点"), size: .init(width: 800, height: 800)),
            .init(id: 1, title: L10n.tr("听完的书"), size: .init(width: 800, height: 800)),
            .init(id: 2, title: L10n.tr("作者与分类"), size: .init(width: 800, height: 800)),
            .init(id: 3, title: L10n.tr("简版横幅"), size: .init(width: 600, height: 200))
        ]
    }
    var body: some View {
        let account = accountKey
        let request = CoverRequest(account: account, year: year, ids: coverIDs)
        VStack(alignment: .leading, spacing: 12) {
            if covers.isLoading { ProgressView(L10n.tr("正在读取回顾封面…")).controlSize(.small) }
            else if covers.unavailableCount > 0 { Text(L10n.tr("部分封面无法读取，回顾数值不受影响。")).font(.caption).foregroundStyle(.secondary) }
            YearReviewGallery(title: L10n.tr("分享我的年度回顾"), filename: "Audisle-\(year)", styles: styles,
                              revision: accountKey + "|\(year)|\(statistics.hashValue)|\(covers.revision)", isPreparing: covers.isLoading || loadedCoverRequest != request) { style in
                PersonalYearReviewPoster(year: year, statistics: statistics, style: style, covers: covers.images)
            }
        }
        .task(id: request) {
            guard !Task.isCancelled, account == accountKey else { return }
            loadedCoverRequest = nil
            await covers.load(store: store, ids: coverIDs)
            guard !Task.isCancelled, account == accountKey else { return }
            loadedCoverRequest = request
        }
    }
}

/// Fixed-size SwiftUI content has no asynchronous children: bitmap and preview are identical.
struct PersonalYearReviewPoster: View {
    let year: Int
    let statistics: YearlyStatistics
    let style: Int
    let covers: [String: NSImage]
    private var backgroundCovers: [NSImage] {
        var seen = Set<String>()
        return (statistics.finishedBooksWithCovers + statistics.booksWithCovers).filter { seen.insert($0).inserted }.compactMap { covers[$0] }
    }
    var body: some View {
        if style == 3 {
            YearReviewCanvas(title: L10n.format("%1$@ 年度回顾", String(year)), covers: backgroundCovers, compact: true) {
                HStack(spacing: 14) {
                    YearReviewMetric(label: L10n.tr("听完书籍"), value: String(statistics.numBooksFinished), symbol: "checkmark.seal", compact: true)
                    YearReviewMetric(label: L10n.tr("听过书籍"), value: String(statistics.numBooksListened), symbol: "books.vertical", compact: true)
                }
            }
        } else {
            YearReviewCanvas(title: L10n.format("%1$@ 年度回顾", String(year)), covers: backgroundCovers) {
                VStack(spacing: 20) {
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
                        YearReviewMetric(label: L10n.tr("听完书籍"), value: String(statistics.numBooksFinished), symbol: "checkmark.seal")
                        YearReviewMetric(label: L10n.tr("年度收听"), value: yearReviewHours(statistics.totalListeningTime), symbol: "clock")
                        YearReviewMetric(label: L10n.tr("收听次数"), value: String(statistics.totalListeningSessions), symbol: "headphones")
                        YearReviewMetric(label: L10n.tr("听过书籍"), value: String(statistics.numBooksListened), symbol: "books.vertical")
                    }
                    if style == 1 { finishedBooks }
                    else if style == 2 {
                        HStack(alignment: .top, spacing: 24) {
                            YearReviewRanking(title: L10n.tr("最常听的作者"), names: statistics.topAuthors.prefix(3).map { $0.name ?? L10n.tr("未知") })
                            YearReviewRanking(title: L10n.tr("最常听的分类"), names: statistics.topGenres.prefix(3).map { $0.genre ?? L10n.tr("未知") })
                        }.frame(maxHeight: .infinity, alignment: .top)
                    } else { highlights }
                }
            }
        }
    }
    private var highlights: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 22) {
            YearReviewHighlight(label: L10n.tr("最常听的旁白"), name: statistics.mostListenedNarrator?.name, detail: statistics.mostListenedNarrator.map { yearReviewHours($0.time) })
            YearReviewHighlight(label: L10n.tr("最常听的分类"), name: statistics.topGenres.first?.genre, detail: statistics.topGenres.first.map { yearReviewHours($0.time) })
            YearReviewHighlight(label: L10n.tr("最常听的作者"), name: statistics.topAuthors.first?.name, detail: statistics.topAuthors.first.map { yearReviewHours($0.time) })
            YearReviewHighlight(label: L10n.tr("收听最多的月份"), name: monthName, detail: statistics.mostListenedMonth.map { yearReviewHours($0.time) })
        }.frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
    }
    private var monthName: String? {
        guard let month = statistics.mostListenedMonth, month.time > 0, (0..<12).contains(month.month) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLanguageStore.shared.selection.locale
        guard let date = calendar.date(from: DateComponents(year: year, month: month.month + 1, day: 1)) else { return nil }
        return date.formatted(.dateTime.month(.wide).locale(AppLanguageStore.shared.selection.locale))
    }
    private var finishedBooks: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.tr("这一年听完的书籍")).font(.system(size: 26, weight: .semibold))
            YearReviewCoverStrip(ids: statistics.finishedBooksWithCovers, covers: covers)
            if statistics.numBooksFinished == 0 { Text(L10n.tr("这一年还没有听完的书籍。")).font(.system(size: 22)).foregroundStyle(.white.opacity(0.75)) }
            else if statistics.finishedBooksWithCovers.isEmpty { Text(L10n.tr("听完的书籍没有可用封面。")).font(.system(size: 22)).foregroundStyle(.white.opacity(0.75)) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 18)
    }
}

struct YearReviewCanvas<Content: View>: View {
    let title: String
    let covers: [NSImage]
    var compact = false
    @ViewBuilder let content: () -> Content
    private let blue = Color(red: 0.13, green: 0.22, blue: 0.39)
    var body: some View {
        ZStack {
            LinearGradient(colors: [blue, Color(red: 0.24, green: 0.34, blue: 0.51)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if !covers.isEmpty {
                GeometryReader { geometry in
                    let side = geometry.size.width / 4
                    VStack(spacing: 7) {
                        ForEach(0..<5, id: \.self) { row in
                            HStack(spacing: 7) {
                                ForEach(0..<5, id: \.self) { column in
                                    Image(nsImage: covers[(row * 5 + column) % covers.count]).resizable().scaledToFill().frame(width: side, height: side).clipped()
                                }
                            }
                        }
                    }.rotationEffect(.degrees(-18)).offset(x: -side / 2, y: -side / 2).opacity(0.18)
                }.clipped()
            }
            LinearGradient(colors: [.black.opacity(0.2), blue.opacity(0.3)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: compact ? 12 : 30) {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill").font(.system(size: compact ? 22 : 34))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Audisle").font(.system(size: compact ? 18 : 28, weight: .bold, design: .rounded))
                        Text(title).font(.system(size: compact ? 13 : 19, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    Text("AUDIOBOOKSHELF").font(.system(size: compact ? 9 : 12, weight: .medium)).tracking(compact ? 1 : 2).foregroundStyle(.white.opacity(0.6))
                }
                content()
                if !compact { Spacer(minLength: 0); Text(L10n.tr("把时间，交给好故事。")).font(.system(size: 17)).foregroundStyle(.white.opacity(0.65)) }
            }.padding(compact ? 18 : 40)
        }.foregroundStyle(.white).clipped()
    }
}

struct YearReviewMetric: View {
    let label: String
    let value: String
    let symbol: String
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 12 : 18) {
            Image(systemName: symbol).font(.system(size: compact ? 27 : 34, weight: .light)).frame(width: compact ? 34 : 44).foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: compact ? 4 : 9) {
                Text(value).font(.system(size: compact ? 30 : 38, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.55)
                Text(label).font(.system(size: compact ? 15 : 20, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(compact ? 12 : 20).frame(maxWidth: .infinity, minHeight: compact ? 82 : 136, alignment: .leading)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: compact ? 12 : 18))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 18).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

struct YearReviewHighlight: View {
    let label: String
    let name: String?
    let detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            Text(name ?? L10n.tr("暂无记录")).font(.system(size: 27, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.75)
            Text(name == nil ? "—" : detail ?? "—").font(.system(size: 19)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }.frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
    }
}

struct YearReviewRanking: View {
    let title: String
    let names: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            if names.isEmpty { Text(L10n.tr("暂无记录")).font(.system(size: 24)).foregroundStyle(.white.opacity(0.7)) }
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(index + 1)).foregroundStyle(.white.opacity(0.55)).frame(width: 22)
                    Text(name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).minimumScaleFactor(0.7)
                }.font(.system(size: 25, weight: .semibold))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 15)
    }
}

struct YearReviewCoverStrip: View {
    let ids: [String]
    let covers: [String: NSImage]
    private var uniqueIDs: [String] { var seen = Set<String>(); return Array(ids.filter { seen.insert($0).inserted }.prefix(5)) }
    var body: some View {
        HStack(spacing: 12) {
            ForEach(uniqueIDs, id: \.self) { id in
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
                    if let image = covers[id] { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "book.closed").font(.system(size: 32, weight: .light)).foregroundStyle(.white.opacity(0.5)) }
                }.frame(width: 132, height: 150).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

func yearReviewHours(_ seconds: Double) -> String {
    let hours = max(0, seconds.isFinite ? seconds / 3_600 : 0)
    return hours.formatted(.number.precision(.fractionLength(1)).locale(AppLanguageStore.shared.selection.locale)) + L10n.tr(" 小时")
}
