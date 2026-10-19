import SwiftUI
import Observation
import AudilseCore

@MainActor @Observable private final class CatalogSelectionModel {
    var items: [AudilseCore.LibraryItem] = []
    var total = 0
    var hasMore = false
    var isLoading = false
    var error: String?
    private var generation = UUID()

    func load(store: AppStore, library: Library, page: Int, search: String) async {
        let operation = UUID(); generation = operation
        items = []; total = 0; hasMore = false; isLoading = true; error = nil
        defer { if generation == operation { isLoading = false } }
        guard let client = store.client, let partition = store.partition, !store.isOffline else { return }
        func isCurrent() -> Bool { generation == operation && store.client === client && store.partition == partition && !store.isOffline && !Task.isCancelled }
        do {
            if !search.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            let result = try await client.libraryItems(libraryID: library.id, page: page, limit: 60, search: search)
            guard isCurrent() else { return }
            items = result.results; total = result.total; hasMore = result.hasMore
        } catch is CancellationError {} catch ABSError.sessionChanged {}
        catch let failure as URLError where failure.code == .cancelled {}
        catch { if isCurrent() { self.error = L10n.error(error) } }
    }
}

/// Selection retains the user's order across catalog pages and searches.
struct CatalogSelectionView: View {
    let store: AppStore
    let library: Library
    let existing: Set<PlaylistItemReference>
    let onAdd: @MainActor ([PlaylistItemReference]) async -> Bool
    @State private var model = CatalogSelectionModel()
    @State private var selection: [PlaylistItemReference] = []
    @State private var search = ""
    @State private var page = 0
    @State private var episodePodcast: AudilseCore.LibraryItem?
    @State private var isAdding = false
    @Environment(\.dismiss) private var dismiss
    private var identity: String { (store.partition?.directoryName ?? "") + (store.client.map { String(describing: ObjectIdentifier($0)) } ?? "") }
    private var loadIdentity: String { identity + library.id + ":\(page):" + search }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(L10n.tr("添加内容")).font(.title2.bold()); Text(library.name + L10n.tr(" · 可搜索或翻页浏览完整书库")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if model.isLoading { ProgressView().controlSize(.small) } }
            TextField(L10n.tr("搜索书名、节目或作者"), text: $search).textFieldStyle(.shelfLeading).disabled(isAdding)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange) }
            List(model.items) { item in
                if library.mediaType == "podcast" {
                    Button { episodePodcast = item } label: { HStack { Text(item.title); Spacer(); Text(L10n.tr("选择单集")).foregroundStyle(.secondary); Image(systemName: "chevron.right") } }.buttonStyle(.plain).padding(.vertical, 7)
                } else {
                    let reference = PlaylistItemReference(libraryItemId: item.id)
                    Toggle(isOn: binding(reference)) { VStack(alignment: .leading, spacing: 4) { Text(item.title); Text(existing.contains(reference) ? L10n.tr("已在列表中") : item.authorName).font(.caption).foregroundStyle(.secondary) } }
                        .toggleStyle(.checkbox).disabled(existing.contains(reference)).padding(.vertical, 7)
                }
            }.listStyle(.inset).disabled(isAdding || model.isLoading)
            HStack { Button(L10n.tr("上一页")) { page -= 1 }.disabled(page == 0 || model.isLoading || isAdding); Text(L10n.format("第 %1$@ 页 · %2$@ 条内容", String(describing: page + 1), String(describing: model.total))).font(.caption).foregroundStyle(.secondary); Button(L10n.tr("下一页")) { page += 1 }.disabled(!model.hasMore || model.isLoading || isAdding); Spacer() }
            HStack { Text(L10n.format("已选 %1$@ 条，按选择顺序添加", String(describing: selection.count))).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("取消")) { dismiss() }.disabled(isAdding); Button(L10n.format("添加 %1$@ 条", String(describing: selection.count))) { Task { isAdding = true; let saved = await onAdd(selection); isAdding = false; if saved { dismiss() } } }.buttonStyle(.borderedProminent).disabled(selection.isEmpty || isAdding || store.isOffline) }
        }.padding(24).frame(width: 620, height: 580)
        .task(id: loadIdentity) { await model.load(store: store, library: library, page: page, search: search.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .onChange(of: search) { _, _ in page = 0 }
        .onChange(of: identity) { _, _ in dismiss() }
        .onChange(of: store.isOffline) { _, offline in if offline { dismiss() } }
        .sheet(item: $episodePodcast) { item in CatalogEpisodeSelectionView(store: store, item: item, existing: existing, selection: $selection) }
    }
    private func binding(_ reference: PlaylistItemReference) -> Binding<Bool> {
        Binding(get: { selection.contains(reference) }, set: { selected in if selected { if !selection.contains(reference) { selection.append(reference) } } else { selection.removeAll { $0 == reference } } })
    }
}

private struct CatalogEpisodeSelectionView: View {
    let store: AppStore
    let item: AudilseCore.LibraryItem
    let existing: Set<PlaylistItemReference>
    @Binding var selection: [PlaylistItemReference]
    @State private var episodes: [PodcastEpisode] = []
    @State private var page = 0
    @State private var loading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var pageCount: Int { max(1, (episodes.count + 79) / 80) }
    private var visible: ArraySlice<PodcastEpisode> { episodes.dropFirst(page * 80).prefix(80) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading) { Text(item.title).font(.title3.bold()); Text(L10n.tr("仅显示服务器已下载的单集")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
            if loading { ProgressView(L10n.tr("正在载入单集…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { Text(error).foregroundStyle(.orange); Spacer() }
            else {
                ScrollView { VStack(alignment: .leading, spacing: 0) { ForEach(visible) { episode in
                    let reference = PlaylistItemReference(libraryItemId: item.id, episodeId: episode.id)
                    Toggle(isOn: Binding(get: { selection.contains(reference) }, set: { selected in if selected { if !selection.contains(reference) { selection.append(reference) } } else { selection.removeAll { $0 == reference } } })) {
                        HStack { Text(episode.title); Spacer(); if existing.contains(reference) { Text(L10n.tr("已添加")).foregroundStyle(.secondary) } }
                    }.toggleStyle(.checkbox).disabled(existing.contains(reference)).padding(.vertical, 11)
                    Divider()
                } } }
                if episodes.isEmpty { Text(L10n.tr("暂无可添加的已下载单集")).foregroundStyle(.secondary) }
                HStack { Button(L10n.tr("上一页")) { page -= 1 }.disabled(page == 0); Text(L10n.format("第 %1$@ / %2$@ 页 · %3$@ 集", String(describing: page + 1), String(describing: pageCount), String(describing: episodes.count))).font(.caption); Button(L10n.tr("下一页")) { page += 1 }.disabled(page + 1 >= pageCount); Spacer() }
            }
        }.padding(24).frame(width: 620, height: 580)
        .task {
            guard let client = store.client, let partition = store.partition else { loading = false; return }
            do {
                let full = try await client.item(id: item.id)
                guard store.client === client, store.partition == partition, !Task.isCancelled else { return }
                episodes = full.media.episodes.filter { $0.audioFile != nil }; loading = false
            } catch is CancellationError {} catch { if store.client === client, store.partition == partition { self.error = L10n.error(error); loading = false } }
        }
    }
}
