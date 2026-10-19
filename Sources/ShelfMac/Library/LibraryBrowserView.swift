import SwiftUI
import ShelfCore

private struct LibraryBrowserContext: Hashable {
    var partition: AccountPartition?
    var client: ObjectIdentifier?
    var libraryID: String
    var offline: Bool
    var connecting: Bool
    var revision: UUID
    var version: String?
    var user: UserAccount?
}
private struct LibraryBrowserRequest: Hashable {
    var context: LibraryBrowserContext
    var options: LibraryBrowseOptions
    var search: String
    var retry: UUID
    var progressPercentage: Bool
}
private enum LibrarySortChoice: Hashable {
    case server(LibraryBrowseSort), percentage
    var title: String { switch self { case .server(let sort): sort.title; case .percentage: L10n.tr("进度百分比") } }
}
private struct LibraryMetadataRequest: Hashable {
    var context: LibraryBrowserContext
    var retry: UUID
}

struct LibraryBrowserView: View {
    @Bindable var store: AppStore
    let library: Library
    @State private var model = LibraryBrowserModel()
    @State private var preferences: LibraryBrowserPreferences
    @State private var page = 0
    @State private var pageInput = "1"
    @State private var showFilter = false
    @State private var showAppearance = false
    @State private var selectedSeries: FeatureGroup?
    @State private var retry = UUID()
    @State private var metadataRetry = UUID()
    @State private var temporaryPreferences: LibraryBrowserPreferences?
    @State private var appliedNavigationID: UUID?
    private let account: AccountPartition?
    init(store: AppStore, library: Library) {
        self.store = store; self.library = library; account = store.partition
        var saved = LibraryBrowserPreferencesStore().load(partition: store.partition, library: library, fallback: store.playbackPreferences)
        saved.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
        _preferences = State(initialValue: saved)
        let navigation = store.browseNavigation.flatMap { $0.isCurrent(in: store, libraryID: library.id) ? $0 : nil }
        _temporaryPreferences = State(initialValue: navigation.map { saved.applying(temporaryFilter: $0.filter, library: library, user: store.user, version: store.profile?.serverVersion) })
        _appliedNavigationID = State(initialValue: navigation?.id)
    }
    private var effectivePreferences: LibraryBrowserPreferences {
        temporaryPreferences ?? preferences
    }
    private var hasPendingNavigation: Bool {
        guard let navigation = store.browseNavigation, navigation.isCurrent(in: store, libraryID: library.id) else { return false }
        return navigation.id != appliedNavigationID
    }
    private var searching: Bool { !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var context: LibraryBrowserContext {
        .init(partition: store.partition, client: store.client.map(ObjectIdentifier.init), libraryID: library.id,
              offline: store.isOffline, connecting: store.isConnecting, revision: store.libraryRevision, version: store.profile?.serverVersion, user: store.user)
    }
    private var request: LibraryBrowserRequest {
        var options = effectivePreferences.options; options.page = page
        return .init(context: context, options: options, search: store.search, retry: retry, progressPercentage: effectivePreferences.sortByProgressPercentage)
    }
    private var sorts: [LibraryBrowseSort] {
        let available = LibraryBrowseSort.available(mediaType: library.mediaType, filter: effectivePreferences.options.filter, serverVersion: store.profile?.serverVersion)
        // The server's collapsed-subseries path does not join progress or randomize.
        if case .series = effectivePreferences.options.filter, effectivePreferences.options.collapseSeries {
            return available.filter { ![.progress, .progressStarted, .progressFinished, .random].contains($0) }
        }
        return available
    }
    var body: some View {
        let pendingNavigationID = store.browseNavigation?.id
        VStack(spacing: 0) {
            controls.padding(.horizontal, 28).padding(.vertical, 16)
            if searching {
                Label(L10n.tr("搜索结果由服务器返回；排序、筛选和系列折叠在退出搜索后生效。"), systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 12)
            }
            if store.isOffline {
                Label(model.usesLegacyCache ? L10n.tr("离线显示已缓存的内容；重新连接可获取完整书库。") : L10n.tr("离线仅显示已缓存的页面；搜索范围为已缓存内容。"), systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 12)
            }
            Divider().opacity(0.4)
            if let error = model.error {
                HStack { Text(error).font(.callout).foregroundStyle(.orange); Spacer(); Button(L10n.tr("重试")) { retry = UUID() } }.padding(.horizontal, 28).padding(.vertical, 12)
            }
            if model.isLoading || hasPendingNavigation {
                VStack(spacing: 12) { ProgressView(); Text(searching ? L10n.tr("正在搜索…") : L10n.tr("正在整理书架…")).font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("library.loading")
            } else if model.entries.isEmpty {
                QuietEmptyState(symbol: searching ? "magnifyingglass" : "books.vertical", title: L10n.tr("没有符合条件的内容"), message: store.isOffline ? L10n.tr("此条件下还没有缓存。可按标题浏览已缓存内容，或重新连接服务器。") : L10n.tr("试试其他搜索词，或清除筛选条件。"))
            } else if preferences.display == .grid { grid }
            else { rows }
            Divider().opacity(0.4)
            pagination.padding(.horizontal, 28).padding(.vertical, 12)
        }
        .task(id: request) { await model.load(store: store, library: library, options: request.options, search: request.search, progressPercentage: request.progressPercentage) }
        .task(id: pendingNavigationID) {
            guard !Task.isCancelled, account == store.partition,
                  let navigation = store.browseNavigation, navigation.id == pendingNavigationID,
                  navigation.isCurrent(in: store, libraryID: library.id) else { return }
            temporaryPreferences = preferences.applying(temporaryFilter: navigation.filter, library: library, user: store.user, version: store.profile?.serverVersion)
            appliedNavigationID = navigation.id; page = 0
            store.consumeBrowseNavigation(id: navigation.id, libraryID: library.id)
        }
        .task(id: LibraryMetadataRequest(context: context, retry: metadataRetry)) { await model.loadMetadata(store: store, library: library) }
        .onDisappear { model.cancel() }
        .onChange(of: store.search) { _, _ in page = 0 }
        .onChange(of: preferences.options) { _, _ in
            preferences.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
            page = 0; persist()
        }
        .onChange(of: preferences.display) { _, _ in persist() }
        .onChange(of: preferences.sortByProgressPercentage) { _, _ in
            preferences.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
            page = 0; persist()
        }
        .onChange(of: preferences.coverSize) { _, _ in persist() }
        .onChange(of: preferences.showSubtitles) { _, _ in persist() }
        .onChange(of: page) { _, value in pageInput = String(value + 1) }
        .onChange(of: store.profile?.serverVersion) { _, _ in
            preferences.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
            temporaryPreferences?.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
        }
        .sheet(isPresented: $showFilter) {
            LibraryFilterView(library: library, user: store.user, metadata: model.metadata, loading: model.metadataLoading,
                              error: model.metadataError, selected: effectivePreferences.options.filter,
                              retry: { metadataRetry = UUID() }, choose: { value in
                guard account == store.partition else { return }; temporaryPreferences = nil; preferences.options.filter = value; page = 0
            })
        }
        .sheet(item: $selectedSeries) { group in FeatureGroupDetailView(store: store, kind: .series, initial: group) }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            Picker(L10n.tr("排序"), selection: Binding(get: { effectivePreferences.sortByProgressPercentage ? LibrarySortChoice.percentage : .server(effectivePreferences.options.sort) }, set: { choice in
                updateBrowsingPreferences { value in
                    switch choice {
                    case .percentage: value.sortByProgressPercentage = true; value.options.sort = .title; value.options.collapseSeries = false; value.options.descending = false
                    case .server(let sort): value.sortByProgressPercentage = false; value.options.sort = sort; value.options.descending = !sort.defaultsToAscending
                    }
                }
            })) {
                ForEach(sorts, id: \.self) { Text($0.title).tag(LibrarySortChoice.server($0)) }
                if library.mediaType == "book" { Text(L10n.tr("进度百分比")).tag(LibrarySortChoice.percentage) }
            }
                .pickerStyle(.menu).labelsHidden().fixedSize().disabled(searching).accessibilityIdentifier("library.sort")
            Button { updateBrowsingPreferences { $0.options.descending.toggle() } } label: { Image(systemName: effectivePreferences.options.descending ? "arrow.down" : "arrow.up") }
                .buttonStyle(.borderless).help(effectivePreferences.options.descending ? L10n.tr("降序，点击改为升序") : L10n.tr("升序，点击改为降序"))
                .disabled(searching || (!effectivePreferences.sortByProgressPercentage && effectivePreferences.options.sort == .random)).accessibilityIdentifier("library.direction")
            Divider().frame(height: 18)
            Button { showFilter = true } label: { Label(effectivePreferences.options.filter.title(metadata: model.metadata), systemImage: "line.3.horizontal.decrease.circle") }
                .buttonStyle(.borderless).lineLimit(1).disabled(searching).accessibilityIdentifier("library.filter")
            if effectivePreferences.options.filter != .all {
                Button { temporaryPreferences = nil; preferences.options.filter = .all; page = 0 } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help(L10n.tr("清除筛选")).disabled(searching).accessibilityIdentifier("library.clear-filter")
            }
            if library.mediaType == "book" {
                Toggle(L10n.tr("折叠系列"), isOn: Binding(get: { effectivePreferences.options.collapseSeries }, set: { newValue in updateBrowsingPreferences { $0.options.collapseSeries = newValue } })).toggleStyle(.checkbox).disabled(searching || effectivePreferences.sortByProgressPercentage)
                    .font(.caption).accessibilityIdentifier("library.collapse-series")
                    .help(effectivePreferences.sortByProgressPercentage ? L10n.tr("百分比排序逐本显示进度") : L10n.tr("将同系列书籍折叠显示"))
            }
            Spacer(minLength: 4)
            Picker(L10n.tr("显示方式"), selection: $preferences.display) {
                Image(systemName: "square.grid.2x2").tag(LibraryDisplayMode.grid)
                Image(systemName: "list.bullet").tag(LibraryDisplayMode.list)
            }.pickerStyle(.segmented).frame(width: 74).labelsHidden().accessibilityIdentifier("library.display")
            Button { showAppearance.toggle() } label: { Image(systemName: "textformat.size") }.buttonStyle(.borderless).help(L10n.tr("书架外观"))
                .popover(isPresented: $showAppearance) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.tr("书架外观")).font(.headline)
                        Text(L10n.tr("封面大小")).font(.caption).foregroundStyle(.secondary)
                        Slider(value: $preferences.coverSize, in: 120...240, step: 10).disabled(preferences.display == .list)
                        Toggle(L10n.tr("显示副标题"), isOn: $preferences.showSubtitles)
                    }.padding(20).frame(width: 240)
                }
        }.font(.system(size: 12))
    }
    private var grid: some View {
        let capturedSource = model.coverSource
        let entries = model.entries
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: preferences.coverSize, maximum: preferences.coverSize + 30), spacing: 24, alignment: .top)], alignment: .leading, spacing: 25) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { open(entry, source: capturedSource) } label: { cover(entry, source: capturedSource).aspectRatio(0.82, contentMode: .fit).shadow(color: .black.opacity(0.08), radius: 6, y: 3) }.buttonStyle(.plain)
                        Text(entry.collapsedSeries?.name ?? entry.item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if preferences.showSubtitles, let subtitle = entry.item.media.metadata.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(entry.item.authorName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        entrySummary(entry)
                    }.contextMenu { entryActions(entry, source: capturedSource) }.accessibilityIdentifier("library.entry." + entry.id)
                }
            }.padding(28)
        }.id(page).scrollContentBackground(.hidden)
    }
    private var rows: some View {
        let capturedSource = model.coverSource
        let entries = model.entries
        return List {
            ForEach(entries) { entry in
                Button { open(entry, source: capturedSource) } label: {
                    HStack(spacing: 14) {
                        cover(entry, source: capturedSource).frame(width: 46, height: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.collapsedSeries?.name ?? entry.item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if preferences.showSubtitles, let subtitle = entry.item.media.metadata.subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            Text(entry.item.authorName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        entrySummary(entry)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).contextMenu { entryActions(entry, source: capturedSource) }.accessibilityIdentifier("library.entry." + entry.id)
            }
        }.listStyle(.inset).id(page)
    }
    private func cover(_ entry: LibraryBrowseEntry, source: CoverSource?) -> some View {
        let cover = source?.request(item: entry.item, store: store)
        return CoverView(item: entry.item, url: cover?.url, client: cover?.client, accountKey: cover?.accountKey ?? "none")
            .overlay(alignment: .bottomTrailing) {
                if let series = entry.collapsedSeries {
                    Text(L10n.format("%1$@ 本", String(describing: series.numBooks))).font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 5).background(.ultraThinMaterial, in: Capsule()).padding(6)
                }
            }
    }
    @ViewBuilder private func entrySummary(_ entry: LibraryBrowseEntry) -> some View {
        HStack(spacing: 6) {
            if let series = entry.collapsedSeries {
                Label(series.seriesSequenceList ?? L10n.format("%1$@ 本书", String(describing: series.numBooks)), systemImage: "books.vertical")
            } else if entry.item.mediaType == "podcast" {
                Label(L10n.format("%1$@ 集", String(describing: entry.mediaSummary?.numEpisodes ?? entry.item.media.numTracks ?? entry.item.media.episodes.count)), systemImage: "mic")
                if let remaining = entry.numEpisodesIncomplete { Text(L10n.format("%1$@ 未完成", String(describing: remaining))) }
            } else if store.progressByItem[entry.item.id]?.isFinished == true {
                Label(L10n.tr("已完成"), systemImage: "checkmark.circle")
            } else if let progress = store.progressByItem[entry.item.id], LibraryProgressOrdering.fraction(for: progress) > 0 {
                Text("\(progress.progress == 0 && (progress.ebookProgress ?? 0) > 0 ? L10n.tr("已读") : L10n.tr("已听")) \(Int(LibraryProgressOrdering.fraction(for: progress) * 100))%")
            } else if effectivePreferences.sortByProgressPercentage {
                Text("0%")
            } else {
                Label(entry.item.media.duration > 0 ? entry.item.media.duration.shelfDuration : L10n.tr("电子书"), systemImage: entry.item.media.duration > 0 ? "headphones" : "book")
            }
            if entry.rssFeed != nil { Image(systemName: "dot.radiowaves.left.and.right").help(L10n.tr("已开启 RSS")) }
            if entry.mediaItemShare != nil { Image(systemName: "square.and.arrow.up").help(L10n.tr("已开启分享")) }
        }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
    }
    @ViewBuilder private func entryActions(_ entry: LibraryBrowseEntry, source: CoverSource?) -> some View {
        Button(entry.collapsedSeries == nil ? L10n.tr("查看详情") : L10n.tr("查看系列")) { open(entry, source: source) }
        if entry.collapsedSeries == nil && entry.item.mediaType == "book" {
            if (entry.item.media.numTracks ?? entry.item.media.tracks.count) > 0 {
                Button(L10n.tr("播放"), systemImage: "play.fill") { Task { guard source?.isCurrent(store) == true, model.isBound(to: store, libraryID: library.id) else { return }; await store.play(entry.item) } }
            }
            if !store.isOffline && (store.user?.permissions.download == true || store.user?.isAdmin == true) {
                Button(L10n.tr("下载"), systemImage: "arrow.down.circle") { Task { guard source?.isCurrent(store) == true, model.isBound(to: store, libraryID: library.id) else { return }; await store.download(entry.item) } }
            }
        }
    }
    private var pagination: some View {
        HStack(spacing: 12) {
            Text(countLabel).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button(L10n.tr("上一页"), systemImage: "chevron.left") { page -= 1 }.disabled(page == 0 || model.isLoading).accessibilityIdentifier("library.previous")
            HStack(spacing: 4) {
                Text(L10n.tr("第"))
                TextField(L10n.tr("页码"), text: $pageInput).textFieldStyle(.shelfLeading).frame(width: 46).multilineTextAlignment(.center)
                    .onSubmit { jump() }.disabled(model.isLoading || model.total == nil).accessibilityIdentifier("library.page")
                Text(L10n.tr("页"))
            }.font(.caption)
            Button(L10n.tr("下一页"), systemImage: "chevron.right") { page += 1 }.disabled(!model.hasMore || model.isLoading).accessibilityIdentifier("library.next")
        }
    }
    private var countLabel: String {
        if model.isLoading { return L10n.tr("正在加载…") }
        let start = page * preferences.options.limit + 1
        let end = page * preferences.options.limit + model.entries.count
        if let total = model.total { return model.entries.isEmpty ? L10n.format("共 %1$@ 项", String(describing: total)) : L10n.format("%1$@–%2$@ · 共 %3$@ 项", String(describing: start), String(describing: end), String(describing: total)) }
        return model.entries.isEmpty ? L10n.tr("0 项") : L10n.format("%1$@–%2$@ 项", String(describing: start), String(describing: end))
    }
    private func jump() {
        guard let entered = Int(pageInput), let total = model.total else { pageInput = String(page + 1); return }
        page = min(max(0, (max(1, total) - 1) / preferences.options.limit), max(0, entered - 1)); pageInput = String(page + 1)
    }
    private func persist() {
        guard let account, account == store.partition else { return }
        do { try LibraryBrowserPreferencesStore().save(preferences, partition: account, libraryID: library.id) }
        catch { store.errorMessage = L10n.error(error) }
    }
    private func updateBrowsingPreferences(_ update: (inout LibraryBrowserPreferences) -> Void) {
        guard account == store.partition else { return }
        if var temporary = temporaryPreferences {
            update(&temporary)
            temporary.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
            temporaryPreferences = temporary
        } else {
            update(&preferences)
            preferences.normalize(library: library, user: store.user, version: store.profile?.serverVersion)
        }
        page = 0
    }
    private func open(_ entry: LibraryBrowseEntry, source: CoverSource?) {
        guard source?.isCurrent(store) == true, model.isBound(to: store, libraryID: library.id) else { return }
        if let series = entry.collapsedSeries {
            selectedSeries = .init(id: series.id, title: series.name, summary: series.seriesSequenceList ?? "", count: series.numBooks, libraryID: library.id)
        } else {
            Task { guard source?.isCurrent(store) == true, model.isBound(to: store, libraryID: library.id) else { return }; await store.open(entry.item) }
        }
    }
}
