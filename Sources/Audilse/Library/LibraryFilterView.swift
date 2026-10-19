import SwiftUI
import AudilseCore

private enum LibraryFilterCategory: String, CaseIterable, Identifiable {
    case general, genre, tag, series, author, narrator, publisher, decade, language, progress, missing, tracks, ebooks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: L10n.tr("常用")
        case .genre: L10n.tr("类型")
        case .tag: L10n.tr("标签")
        case .series: L10n.tr("系列")
        case .author: L10n.tr("作者")
        case .narrator: L10n.tr("演播者")
        case .publisher: L10n.tr("出版社")
        case .decade: L10n.tr("出版年代")
        case .language: L10n.tr("语言")
        case .progress: L10n.tr("进度")
        case .missing: L10n.tr("缺少元数据")
        case .tracks: L10n.tr("音轨")
        case .ebooks: L10n.tr("电子书")
        }
    }
}
private struct LibraryFilterChoice: Identifiable {
    var title: String
    var filter: LibraryBrowseFilter
    var id: String { filter.queryValue ?? "all" }
}

struct LibraryFilterView: View {
    let library: Library
    let user: UserAccount?
    let metadata: LibraryFilterMetadata?
    let loading: Bool
    let error: String?
    let selected: LibraryBrowseFilter
    let retry: () -> Void
    let choose: (LibraryBrowseFilter) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = LibraryFilterCategory.general
    @State private var query = ""
    @State private var page = 0
    private let pageSize = 100
    private var categories: [LibraryFilterCategory] {
        library.mediaType == "podcast" ? [.general, .genre, .tag, .language] : LibraryFilterCategory.allCases
    }
    private var choices: [LibraryFilterChoice] {
        let meta = metadata ?? .init()
        func rows(_ values: [String], _ filter: (String) -> LibraryBrowseFilter) -> [LibraryFilterChoice] {
            values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { .init(title: $0, filter: filter($0)) }
        }
        let all: [LibraryFilterChoice]
        switch category {
        case .general:
            let values: [LibraryBrowseFilter] = [.all, .abridged, .issues, .feedOpen, .explicit, .shareOpen, .recent]
            all = values.filter { $0.isAvailable(mediaType: library.mediaType, user: user) }.map { .init(title: $0.title(metadata: meta), filter: $0) }
        case .genre: all = rows(meta.genres, LibraryBrowseFilter.genre)
        case .tag: all = rows(meta.tags, LibraryBrowseFilter.tag)
        case .series: all = [.init(title: L10n.tr("无系列"), filter: .noSeries)] + meta.series.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { .init(title: $0.name, filter: .series($0.id)) }
        case .author: all = meta.authors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { .init(title: $0.name, filter: .author($0.id)) }
        case .narrator: all = rows(meta.narrators, LibraryBrowseFilter.narrator)
        case .publisher: all = rows(meta.publishers, LibraryBrowseFilter.publisher)
        case .decade: all = rows(meta.publishedDecades, LibraryBrowseFilter.publishedDecade)
        case .language: all = rows(meta.languages, LibraryBrowseFilter.language)
        case .progress: all = LibraryProgressFilter.allCases.map { .init(title: $0.title, filter: .progress($0)) }
        case .missing: all = LibraryMissingField.allCases.map { .init(title: L10n.format("缺少%1$@", String(describing: $0.title)), filter: .missing($0)) }
        case .tracks: all = LibraryTrackFilter.allCases.map { .init(title: $0.title, filter: .tracks($0)) }
        case .ebooks: all = LibraryEbookFilter.allCases.map { .init(title: $0.title, filter: .ebooks($0)) }
        }
        return query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("筛选书库")).font(.title2.bold())
                Spacer()
                SheetCloseButton(identifier: "library-filter.close") { dismiss() }
            }
            Picker(L10n.tr("筛选条件"), selection: $category) { ForEach(categories) { Text($0.title).tag($0) } }
            TextField(L10n.tr("搜索筛选项"), text: $query).textFieldStyle(.shelfLeading)
            if loading { HStack { ProgressView().controlSize(.small); Text(L10n.tr("正在加载筛选项…")).foregroundStyle(.secondary) } }
            if let error {
                HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button(L10n.tr("重试"), action: retry) }
            }
            let matching = choices
            List {
                ForEach(Array(matching.dropFirst(page * pageSize).prefix(pageSize))) { choice in
                    Button {
                        choose(choice.filter); dismiss()
                    } label: {
                        HStack {
                            Text(choice.title).lineLimit(2)
                            Spacer()
                            if selected == choice.filter { Image(systemName: "checkmark").foregroundStyle(ShelfTheme.accent) }
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("library-filter." + choice.id)
                }
            }.overlay { if matching.isEmpty && !loading { Text(L10n.tr("没有符合条件的筛选项")).foregroundStyle(.secondary) } }
            HStack {
                Text(L10n.format("%1$@ 项", String(describing: matching.count))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("上一页")) { page -= 1 }.disabled(page == 0)
                Text(L10n.format("第 %1$@ 页", String(describing: page + 1))).font(.caption).monospacedDigit()
                Button(L10n.tr("下一页")) { page += 1 }.disabled((page + 1) * pageSize >= matching.count)
            }
        }.padding(24).frame(width: 480, height: 540)
        .onChange(of: category) { _, _ in page = 0; query = "" }
        .onChange(of: query) { _, _ in page = 0 }
        .onChange(of: metadata) { _, _ in page = 0 }
    }
}
