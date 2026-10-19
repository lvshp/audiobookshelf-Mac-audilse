import SwiftUI
import AudilseCore

private struct LibrarySearchRequest: Hashable { let source: LibrarySearchSource; let retry: UUID }

struct LibrarySearchView: View {
    @Bindable var store: AppStore
    @State private var model = LibrarySearchModel()
    @State private var actions = LibrarySearchActions()
    @State private var retry = UUID()

    var body: some View {
        let request = LibrarySearchSource(store: store, scope: model.scope, limit: model.limit)
        let identity = LibrarySearchActionSource(store: store, request: request)
        let bound = model.isBound(to: store, source: request)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(request: request)
                if bound, let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                }
                if request.connecting {
                    status(L10n.tr("正在连接服务器，连接完成后将开始搜索。"), loading: true)
                } else if !request.active || request.partition == nil {
                    QuietEmptyState(symbol: "person.crop.circle.badge.exclamationmark", title: L10n.tr("暂时无法搜索"), message: L10n.tr("请先连接有效账户。"))
                } else if !bound {
                    status(L10n.tr("正在准备搜索…"), loading: true)
                } else if model.sections.isEmpty && model.error == nil {
                    QuietEmptyState(symbol: "magnifyingglass", title: L10n.tr("没有可搜索的书库"), message: L10n.tr("选择其他书库或连接服务器后重试。"))
                } else {
                    ForEach(model.sections) { section in
                        LibrarySearchLibraryView(store: store, section: section, model: model, actions: actions, source: identity)
                            .id(LibrarySearchSectionIdentity(source: request, libraryID: section.library.id))
                    }
                }
            }.padding(.horizontal, 30).padding(.vertical, 28)
        }.scrollContentBackground(.hidden).accessibilityIdentifier("search.content")
        .task(id: LibrarySearchRequest(source: request, retry: retry)) {
            guard !Task.isCancelled else { return }
            actions.bind(identity)
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, request.isCurrent(store) else { return }
            await model.load(store: store, source: request)
        }
        // Model.load owns request cancellation. Cancelling it here could race
        // the new .task and erase its already-published winning sections.
        .onChange(of: identity) { _, new in actions.bind(new) }
        .onDisappear { actions.cancel(); model.cancel() }
        .sheet(item: $actions.destination) { destination in
            FeatureGroupDetailView(store: store, kind: destination.kind, initial: destination.group)
        }
        .alert(L10n.tr("暂时无法完成"), isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
            Button(L10n.tr("知道了"), role: .cancel) { actions.error = nil }
        } message: { Text(actions.error ?? "") }
    }

    private func header(request: LibrarySearchSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("搜索你的书库")).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(request.query).font(.title3).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if model.isLoading || actions.isWorking { ProgressView().controlSize(.small) }
                Button { actions.cancel(); retry = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(request.connecting || !request.active)
                    .help(L10n.tr("重新搜索")).accessibilityLabel(L10n.tr("重新搜索"))
            }
            HStack(spacing: 20) {
                Picker(L10n.tr("搜索范围"), selection: $model.scope) {
                    Text(L10n.tr("当前书库")).tag(LibrarySearchScope.currentLibrary)
                    Text(L10n.tr("全部书库")).tag(LibrarySearchScope.allLibraries)
                }.pickerStyle(.menu).frame(maxWidth: 250).accessibilityIdentifier("search.scope")
                Picker(L10n.tr("每分类上限"), selection: $model.limit) {
                    ForEach([12, 24, 60, 120, 250, 500], id: \.self) { limit in
                        Text(String(limit)).tag(limit)
                    }
                }.pickerStyle(.menu).frame(maxWidth: 180).accessibilityIdentifier("search.limit")
                Spacer(minLength: 0)
            }
            Text(L10n.tr("每类返回限定数量的结果。增大上限会重新搜索前缀；服务器不提供搜索总量或稳定分页。"))
                .font(.caption).foregroundStyle(.secondary)
            if request.offline {
                Label(L10n.tr("离线仅显示相同查询、书库和上限的已缓存结果，不代表完整离线索引。"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func status(_ message: String, loading: Bool) -> some View {
        HStack(spacing: 12) { if loading { ProgressView().controlSize(.small) }; Text(message).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.vertical, 65)
    }
}

private struct LibrarySearchSectionIdentity: Hashable { let source: LibrarySearchSource; let libraryID: String }

private struct LibrarySearchLibraryView: View {
    @Bindable var store: AppStore
    let section: LibrarySearchSection
    let model: LibrarySearchModel
    let actions: LibrarySearchActions
    let source: LibrarySearchActionSource
    @State private var selectedCategory: LibrarySearchCategory?
    @State private var page = 0
    private let pageSize = 6

    private var category: LibrarySearchCategory {
        selectedCategory ?? LibrarySearchCategory.allCases.first(where: { kind in
            section.response.map { !kind.rows(in: $0).isEmpty } ?? false
        }) ?? (section.library.mediaType == "podcast" ? .podcasts : .books)
    }
    private var rows: [LibrarySearchRowValue] { section.response.map { category.rows(in: $0) } ?? [] }
    private var pageCount: Int { max(1, (rows.count + pageSize - 1) / pageSize) }
    private var safePage: Int { min(max(0, page), pageCount - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(section.library.name, systemImage: section.library.mediaType == "podcast" ? "mic" : "books.vertical")
                    .font(.title3.weight(.semibold))
                Spacer()
                if section.state == .loading || section.state == .pending { ProgressView().controlSize(.small) }
                if section.usesCache { Label(L10n.tr("缓存结果"), systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            }
            if let error = section.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
            if let error = section.cacheError { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let response = section.response {
                HStack {
                    Picker(L10n.tr("结果分类"), selection: Binding(get: { category }, set: { selectedCategory = $0; page = 0 })) {
                        ForEach(LibrarySearchCategory.allCases) { kind in
                            Text(L10n.format("%1$@ · %2$@", kind.title, String(kind.rows(in: response).count))).tag(kind)
                        }
                    }.pickerStyle(.menu).frame(maxWidth: 240).accessibilityIdentifier("search.category." + section.library.id)
                    Spacer()
                    Text(L10n.format("本次返回 %1$@ 条", String(rows.count))).font(.caption).foregroundStyle(.secondary)
                }
                if rows.isEmpty {
                    Text(section.usesCache ? L10n.tr("此缓存分类没有匹配结果。") : L10n.tr("此次搜索在此分类中没有匹配结果。"))
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                } else {
                    // Only one bounded page exists in the native accessibility
                    // hierarchy. Increasing the API limit does not create 500 rows.
                    VStack(spacing: 8) {
                        ForEach(Array(rows.enumerated().dropFirst(safePage * pageSize).prefix(pageSize)), id: \.offset) { _, value in
                            LibrarySearchResultRow(store: store, value: value, library: section.library,
                                                   model: model, actions: actions, source: source)
                        }
                    }
                    if pageCount > 1 {
                        HStack(spacing: 12) {
                            Text(L10n.tr("仅对已返回的结果分页显示")).font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Button { page = safePage - 1 } label: { Image(systemName: "chevron.left") }
                                .disabled(safePage == 0).accessibilityLabel(L10n.tr("上一页"))
                            Text(L10n.format("第 %1$@ / %2$@ 页", String(safePage + 1), String(pageCount))).font(.caption).monospacedDigit()
                            Button { page = safePage + 1 } label: { Image(systemName: "chevron.right") }
                                .disabled(safePage + 1 >= pageCount).accessibilityLabel(L10n.tr("下一页"))
                        }.buttonStyle(.borderless)
                    }
                }
            } else if section.state == .missingCache {
                Text(L10n.tr("本机没有此查询和上限的缓存。请联网搜索后再试。"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
            } else if section.state == .pending || section.state == .loading {
                Text(L10n.tr("正在搜索此书库…")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
            }
            if let date = section.updatedAt {
                HStack(spacing: 4) { Text(L10n.tr("结果更新于")); Text(date, style: .date); Text(date, style: .time) }
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(18).background(ShelfTheme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 15))
            .onChange(of: rows.count) { _, _ in page = safePage }
            .accessibilityIdentifier("search.library." + section.library.id)
    }
}
