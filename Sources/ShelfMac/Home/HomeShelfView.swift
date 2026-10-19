import SwiftUI
import ShelfCore

struct HomeShelfView: View {
    let store: AppStore
    let library: Library
    let shelf: PersonalizedLibraryShelf
    let model: HomeModel
    let actions: HomeActions
    let source: HomeSource
    let continuation: ContinueListeningModel?
    @State private var page = 0
    private let cardWidth: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol).font(.system(size: 21, weight: .semibold))
                Spacer()
                Text(L10n.format("显示 %1$@ 项 · 服务器总计 %2$@ 项", String(shelf.entities.count), String(shelf.total)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if shelf.kind == nil {
                Text(L10n.tr("这是服务器提供的其他书架，内容和顺序均按原样保留。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if shelf.entities.isEmpty { Text(L10n.tr("此书架暂时没有内容")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 20) }
            else {
                GeometryReader { geometry in
                    let columns = max(1, min(6, Int((geometry.size.width + 18) / (cardWidth + 18))))
                    let pages = max(1, (shelf.entities.count + columns - 1) / columns)
                    let visiblePage = min(page, pages - 1)
                    let start = visiblePage * columns
                    let end = min(shelf.entities.count, start + columns)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(start..<end, id: \.self) { index in
                                HomeEntityCard(store: store, shelf: shelf, entity: shelf.entities[index], model: model,
                                               actions: actions, source: source, continuation: continuation)
                                    .frame(width: cardWidth)
                                    .id(shelf.entityIdentifier(for: shelf.entities[index]) + ":" + String(index))
                            }
                            Spacer(minLength: 0)
                        }
                        if pages > 1 {
                            HStack(spacing: 13) {
                                Button { page = max(0, visiblePage - 1) } label: { Image(systemName: "chevron.left") }
                                    .help(L10n.tr("上一页")).accessibilityLabel(L10n.tr("上一页")).disabled(visiblePage == 0)
                                Text(L10n.format("第 %1$@ / %2$@ 页", String(visiblePage + 1), String(pages))).monospacedDigit()
                                Button { page = min(pages - 1, visiblePage + 1) } label: { Image(systemName: "chevron.right") }
                                    .help(L10n.tr("下一页")).accessibilityLabel(L10n.tr("下一页")).disabled(visiblePage + 1 >= pages)
                                Spacer()
                            }.font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless)
                        }
                    }
                    .onChange(of: columns) { _, _ in page = 0 }
                    .onChange(of: shelf.entities) { _, _ in page = 0 }
                }.frame(height: 375)
            }
        }
    }
    private var title: String {
        switch shelf.kind {
        case .continueListening: L10n.tr("继续收听")
        case .continueReading: L10n.tr("继续阅读")
        case .continueSeries: L10n.tr("继续系列")
        case .recentlyAdded: L10n.tr("最近添加")
        case .recentSeries: L10n.tr("最近添加的系列")
        case .discover: L10n.tr("发现好内容")
        case .listenAgain: L10n.tr("再次收听")
        case .readAgain: L10n.tr("再次阅读")
        case .newestAuthors: L10n.tr("最近添加的作者")
        case .newestEpisodes: L10n.tr("最新单集")
        case nil: shelf.label.isEmpty ? L10n.tr("其他书架") : shelf.label
        }
    }
    private var symbol: String {
        switch shelf.kind {
        case .continueListening, .listenAgain: "headphones"
        case .continueReading, .readAgain: "book"
        case .continueSeries, .recentSeries: "books.vertical"
        case .newestAuthors: "person.2"
        case .newestEpisodes: "dot.radiowaves.left.and.right"
        case .discover: "sparkles"
        default: "rectangle.stack"
        }
    }
}
