import SwiftUI
import AudilseCore
import AudilsePlayback

struct ItemDetailView: View {
    @Bindable var store: AppStore
    var item: AudilseCore.LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "chapters"
    @State private var podcastTab = "episodes"
    @State private var bookmarks: [Bookmark] = []
    @State private var bookmarkTitle = ""
    @State private var editingBookmark: Bookmark?
    @State private var showBookmarkEditor = false
    @State private var busy = false
    @State private var showReader = false
    @State private var selectedReader: SelectedReaderTarget?
    @State private var fileActionSource: ItemFileActionSource?
    @State private var showPodcastManagement = false
    @State private var showContentManagement = false
    @State private var showPersonalActions = false
    @State private var refreshedItem: AudilseCore.LibraryItem?
    @State private var preparedRows: DetailPreparedRows?
    @State private var preparedKey: DetailPreparationKey?
    @State private var preparationRevision = UUID()
    @State private var detailPage = 0
    private let pageSize = 80

    init(store: AppStore, item: AudilseCore.LibraryItem) {
        self.store = store; self.item = item
        _fileActionSource = State(initialValue: ItemFileActionSource(store: store, item: item))
    }

    private var current: AudilseCore.LibraryItem { refreshedItem ?? (store.selectedItem?.id == item.id ? store.selectedItem! : item) }
    private var progress: MediaProgress? { store.progressByItem[item.id] }
    private var downloaded: Bool { store.downloads?.records.first { $0.itemID == item.id }?.state == .ready }
    private var fileActionSourceIsCurrent: Bool { fileActionSource?.isCurrent(store, item: current) == true }
    private var isEbookOnly: Bool {
        store.detailLoadingItemID != item.id && current.mediaType != "podcast" &&
        current.media.ebookFile != nil && current.media.audioFiles.isEmpty &&
        current.media.tracks.isEmpty && (current.media.numTracks ?? 0) == 0 && current.media.duration == 0
    }
    private var activeTab: String { current.mediaType == "podcast" ? podcastTab : (isEbookOnly ? "files" : tab) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(current.mediaType == "podcast" ? L10n.tr("节目详情") : L10n.tr("书籍详情")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                SheetCloseButton(label: L10n.tr("关闭详情"), identifier: "detail.close") { dismiss() }
            }.padding(20)
            ScrollViewReader { scrollProxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 28) {
                        CoverView(item: current, url: store.coverURL(current), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo").frame(width: 172, height: 210)
                            .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(current.title).font(.system(size: 27, weight: .bold)).textSelection(.enabled)
                            Text(current.authorName).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                            if !isEbookOnly, !current.narratorName.isEmpty { Label(current.narratorName, systemImage: "waveform").font(.callout).foregroundStyle(.secondary) }
                            HStack(spacing: 12) {
                                if isEbookOnly, let file = current.media.ebookFile {
                                    Text(URL(fileURLWithPath: file.metadata.filename).pathExtension.uppercased())
                                    if let size = file.metadata.size {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    }
                                } else {
                                    Label(current.media.duration.shelfDuration, systemImage: "clock")
                                }
                                if let year = current.media.metadata.publishedYear { Text(year) }
                                if !isEbookOnly, downloaded { Label(L10n.tr("已下载"), systemImage: "checkmark.circle.fill").foregroundStyle(ShelfTheme.accent) }
                            }.font(.caption).foregroundStyle(.secondary)
                            if !isEbookOnly, let progress, progress.currentTime > 0 {
                                ProgressView(value: min(1, max(0, progress.progress))).tint(ShelfTheme.accent)
                                Text(progress.isFinished ? L10n.tr("已听完") : L10n.format("已听 %1$@%% · %2$@", String(describing: Int(progress.progress * 100)), String(describing: progress.currentTime.shelfTime)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 10) {
                                if current.media.ebookFile != nil {
                                    Button(L10n.tr("阅读"), systemImage: "book") { showReader = true }.buttonStyle(.borderedProminent)
                                }
                                if current.mediaType != "podcast", !isEbookOnly {
                                    Button { Task { await store.play(current) } } label: { Label((progress?.currentTime ?? 0) > 0 ? L10n.tr("继续收听") : L10n.tr("开始收听"), systemImage: "play.fill") }
                                        .buttonStyle(.borderedProminent).disabled(current.media.audioFiles.isEmpty && current.media.tracks.isEmpty && !store.isDemo)
                                }
                                Menu {
                                    if !store.isDemo, !store.isOffline, let user = store.user, user.isActive,
                                       PersonalCapabilities(user: user, version: store.profile?.serverVersion).isSupported {
                                        Button(L10n.tr("分享、RSS 与发送电子书…"), systemImage: "square.and.arrow.up") { showPersonalActions = true }
                                    }
                                    if !store.isOffline, let user = store.user,
                                       AdminPolicy.allows(.updateContent, user: user) || AdminPolicy.allows(.deleteContent, user: user) {
                                        Button(L10n.tr("管理内容…"), systemImage: "slider.horizontal.3") { showContentManagement = true }
                                    }
                                    if current.mediaType == "podcast" {
                                        Button(L10n.tr("管理节目与单集"), systemImage: "slider.horizontal.3") { showPodcastManagement = true }
                                    }
                                    if current.mediaType != "podcast", !isEbookOnly {
                                        Button(L10n.tr("加入待播列表"), systemImage: "text.badge.plus") { store.player?.enqueue(store.playbackMedia(current)) }
                                        if store.canDownload { Button(L10n.tr("下载到 Mac"), systemImage: "arrow.down.circle") { Task { await store.download(current) } } }
                                    }
                                    Button(progress?.isFinished == true ? L10n.tr("标记为未完成") : L10n.tr("标记为已完成"), systemImage: "checkmark.circle") { Task { await store.setFinished(current, finished: progress?.isFinished != true) } }
                                } label: { Image(systemName: "ellipsis").frame(width: 24) }.menuIndicator(.hidden)
                            }.controlSize(.large).padding(.top, 3)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let description = current.media.metadata.description, !description.isEmpty {
                        Text(description.shelfPlainText).font(.callout).lineSpacing(6).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !current.media.metadata.genres.isEmpty {
                        Text(current.media.metadata.genres.joined(separator: "  ·  ")).font(.caption).foregroundStyle(ShelfTheme.accent)
                    }
                    Divider()
                    Color.clear.frame(height: 1).id("detail.rows.start").accessibilityHidden(true)
                    if current.mediaType == "podcast" {
                        Picker(L10n.tr("详情内容"), selection: $podcastTab) {
                            Text(L10n.tr("全部单集")).tag("episodes")
                            Text(L10n.tr("文件")).tag("files")
                        }.pickerStyle(.segmented)
                        if podcastTab == "episodes" { episodes }
                        else { preparedFileContent }
                    } else if isEbookOnly {
                        Text(L10n.tr("文件")).font(.headline)
                        preparedFileContent
                    } else {
                        Picker(L10n.tr("详情内容"), selection: $tab) {
                            Text(L10n.format("章节 · %1$@", String(describing: current.media.chapters.count))).tag("chapters")
                            Text(L10n.format("书签 · %1$@", String(describing: bookmarks.count))).tag("bookmarks")
                            Text(L10n.tr("文件")).tag("files")
                        }.pickerStyle(.segmented)
                        if tab == "bookmarks" { bookmarkList }
                        else if store.detailLoadingItemID == item.id || preparedKey != preparationKey {
                            rowsLoading
                        } else if tab == "chapters" { chapters }
                        else { files }
                    }
                }.padding(.horizontal, 30).padding(.bottom, 30)
              }
              .onChange(of: detailPage) { _, _ in
                  scrollProxy.scrollTo("detail.rows.start", anchor: .top)
              }
            }
        }.frame(width: 740, height: 680).background(ShelfTheme.canvas)
        .task(id: item.id) { await loadBookmarks() }
        .task(id: preparationKey) { await prepareRows() }
        .onChange(of: preparationKey) { _, _ in detailPage = 0 }
        .onChange(of: store.partition) { _, _ in dismiss() }
        .onChange(of: fileActionSourceIsCurrent) { _, isCurrent in if !isCurrent { selectedReader = nil } }
        .sheet(isPresented: $showReader) { ReaderView(store: store, item: current) }
        .sheet(item: $selectedReader) { target in SelectedReaderSheet(store: store, target: target) }
        .sheet(isPresented: $showPersonalActions) { ItemPersonalActionsView(store: store, item: current) }
        .sheet(isPresented: $showPodcastManagement, onDismiss: { Task { await reloadAfterManagement() } }) { PodcastManagementView(store: store, item: current) }
        .sheet(isPresented: $showContentManagement, onDismiss: { Task { await reloadAfterManagement() } }) { ContentManagementView(store: store, item: current) }
        .sheet(isPresented: $showBookmarkEditor) {
            VStack(alignment: .leading, spacing: 18) {
                Text(editingBookmark == nil ? L10n.tr("添加书签") : L10n.tr("编辑书签")).font(.title3.bold())
                TextField(L10n.tr("书签名称"), text: $bookmarkTitle).textFieldStyle(.shelfLeading)
                Text((editingBookmark?.time ?? store.player?.position ?? progress?.currentTime ?? 0).shelfTime).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button(L10n.tr("取消")) { showBookmarkEditor = false }; Button(L10n.tr("保存")) { Task { await saveBookmark() } }.buttonStyle(.borderedProminent).disabled(busy || bookmarkTitle.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(25).frame(width: 380)
        }
    }

    private var rowsLoading: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(store.detailLoadingItemID == item.id ? L10n.tr("正在读取详情…") : (activeTab == "files" ? L10n.tr("正在准备文件列表…") : L10n.tr("正在准备章节…")))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 140)
    }

    @ViewBuilder private var preparedFileContent: some View {
        if store.detailLoadingItemID == item.id || preparedKey != preparationKey { rowsLoading }
        else { files }
    }

    private var chapters: some View {
        VStack(spacing: 0) {
            DetailRowsPagination(count: chapterRows.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("章"))
            if chapterRows.isEmpty { Text(L10n.tr("音频中没有章节信息")).foregroundStyle(.secondary).padding(30) }
            ForEach(chapterRows[pageRange(count: chapterRows.count)]) { row in
                VStack(spacing: 0) {
                    Button { Task { await seek(to: row.chapter.start) } } label: {
                        HStack(spacing: 14) {
                            Text(String(row.id + 1)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 24)
                            Text(row.chapter.title).font(.callout).lineLimit(1)
                            Spacer()
                            Text(row.startTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: "play.circle").foregroundStyle(ShelfTheme.accent)
                        }.padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider().opacity(0.4)
                }
            }
            DetailRowsPagination(count: chapterRows.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("章"))
        }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: L10n.tr("全部单集"), subtitle: L10n.format("%1$@ 集", String(describing: current.media.episodes.count)))
            DetailRowsPagination(count: current.media.episodes.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("集"))
            ForEach(episodeRows) { row in
                let episode = row.episode
              VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button { Task { await store.play(current, episode: episode) } } label: { Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundStyle(ShelfTheme.accent) }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(episode.title).font(.callout.weight(.medium))
                        if let description = episode.description { Text(description.shelfPlainText).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Text((episode.duration ?? episode.audioFile?.duration ?? 0).shelfDuration).font(.caption).foregroundStyle(.secondary)
                    if store.canDownload {
                        Button { Task { await store.downloadEpisode(current, episode: episode) } } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.plain).help(L10n.tr("下载单集到 Mac"))
                    }
                    Button { store.player?.enqueue(store.playbackMedia(current, episode: episode)) } label: { Image(systemName: "text.badge.plus") }.buttonStyle(.plain).help(L10n.tr("加入待播列表"))
                }.padding(.vertical, 12)
                Divider().opacity(0.4)
              }
            }
            DetailRowsPagination(count: current.media.episodes.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("集"))
        }
    }

    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Spacer(); Button(L10n.tr("添加书签"), systemImage: "bookmark.badge.plus") { editingBookmark = nil; bookmarkTitle = ""; showBookmarkEditor = true }.disabled(store.isOffline || store.isDemo) }
            if bookmarks.isEmpty { Text(L10n.tr("在喜欢的段落留个书签，下次轻松找到。")).foregroundStyle(.secondary).padding(25) }
            ForEach(bookmarks) { bookmark in
                HStack {
                    Button { Task { await seek(to: bookmark.time) } } label: {
                        HStack { Image(systemName: "bookmark.fill").foregroundStyle(ShelfTheme.accent); Text(bookmark.title); Spacer(); Text(bookmark.time.shelfTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                    Menu {
                        Button(L10n.tr("编辑")) { editingBookmark = bookmark; bookmarkTitle = bookmark.title; showBookmarkEditor = true }
                        Button(L10n.tr("删除"), role: .destructive) { Task { await deleteBookmark(bookmark) } }
                    } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).frame(width: 32)
                }.padding(.vertical, 10)
                Divider().opacity(0.4)
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 13) {
            DetailRowsPagination(count: fileRows.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("个文件"))
            if fileRows.isEmpty { Text(L10n.tr("没有文件")).foregroundStyle(.secondary).padding(30) }
            ForEach(fileRows[pageRange(count: fileRows.count)]) { row in
                HStack {
                    Image(systemName: row.icon).foregroundStyle(ShelfTheme.accent)
                    Text(row.filename).font(.callout).lineLimit(1)
                    Spacer()
                    Text(row.size).font(.caption).foregroundStyle(.secondary)
                    if fileActionSourceIsCurrent, !row.file.ino.isEmpty {
                        if row.canRead {
                            Button(L10n.tr("阅读"), systemImage: "book") {
                                selectedReader = SelectedReaderTarget(store: store, item: current, file: row.file, source: fileActionSource)
                            }.buttonStyle(.borderless)
                        }
                        if store.canDownload {
                            FileExportButton(store: store, itemID: current.id, file: row.file).id(row.file)
                        }
                    }
                }.padding(.vertical, 5)
            }
            DetailRowsPagination(count: fileRows.count, pageSize: pageSize, page: $detailPage, unit: L10n.tr("个文件"))
        }.padding(.vertical, 10)
    }

    // Keep the rendered view tree bounded. SwiftUI's lazy-layout accessibility
    // scroll action traps on macOS 27 when resolving this long ForEach list.
    private func pageRange(count: Int) -> Range<Int> {
        let page = min(max(0, detailPage), max(0, (count - 1) / pageSize))
        let start = min(count, page * pageSize)
        return start..<min(count, start + pageSize)
    }

    private var chapterRows: [DetailChapterRow] {
        if case .chapters(let rows) = preparedRows { return rows }
        return []
    }
    private var fileRows: [DetailFileRow] {
        if case .files(let rows) = preparedRows { return rows }
        return []
    }
    private var episodeRows: [DetailEpisodeRow] {
        let episodes = current.media.episodes
        return pageRange(count: episodes.count).map { .init(id: $0, episode: episodes[$0]) }
    }
    private var preparationKey: DetailPreparationKey {
        .init(itemID: item.id, partition: store.partition, revision: preparationRevision, tab: activeTab, updatedAt: current.updatedAt,
              chapterCount: current.media.chapters.count, files: ItemFileCatalog.rawFiles(in: current), episodeCount: current.media.episodes.count,
              loading: store.detailLoadingItemID == item.id)
    }
    private func prepareRows() async {
        let key = preparationKey
        guard key.tab == "chapters" || key.tab == "files", !key.loading else { return }
        let sourceChapters = current.media.chapters, sourceFiles = key.files
        let worker = Task.detached(priority: .userInitiated) { () throws -> DetailPreparedRows in
            if key.tab == "chapters" {
                return .chapters(try sourceChapters.enumerated().map { index, chapter in
                    try Task.checkCancellation()
                    return DetailChapterRow(id: index, chapter: chapter, startTime: chapter.start.shelfTime)
                })
            }
            return .files(try ItemFileCatalog.deduplicated(sourceFiles).enumerated().map { index, file in
                try Task.checkCancellation()
                return DetailFileRow(id: index, file: file, filename: file.metadata.filename,
                                     size: ByteCountFormatter.string(fromByteCount: file.metadata.size ?? 0, countStyle: .file),
                                     icon: ItemFileCatalog.icon(file), canRead: ItemFileCatalog.canRead(file))
            })
        }
        do {
            let rows = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard preparationKey == key else { return }
            preparedRows = rows; preparedKey = key
        } catch { /* Cancelled tab preparation must not replace the current tab. */ }
    }

    private func loadBookmarks() async {
        guard !store.isDemo, !store.isOffline, let client = store.client else { return }
        do {
            let loaded = try await client.bookmarks(itemID: item.id).sorted { $0.time < $1.time }
            guard store.client === client, !Task.isCancelled else { return }
            bookmarks = loaded
        } catch { if store.client === client, store.selectedItem?.id == item.id, !Task.isCancelled { store.errorMessage = L10n.error(error) } }
    }
    private func saveBookmark() async {
        guard let client = store.client else { return }
        busy = true; defer { busy = false }
        do {
            if let editingBookmark { _ = try await client.updateBookmark(itemID: item.id, time: editingBookmark.time, title: bookmarkTitle) }
            else { _ = try await client.createBookmark(itemID: item.id, time: store.player?.currentMedia?.itemID == item.id ? store.player?.position ?? 0 : progress?.currentTime ?? 0, title: bookmarkTitle) }
            guard store.client === client else { return }
            showBookmarkEditor = false; await loadBookmarks()
        } catch { if store.client === client { store.errorMessage = L10n.error(error) } }
    }
    private func deleteBookmark(_ bookmark: Bookmark) async {
        guard let client = store.client else { return }
        do {
            try await client.deleteBookmark(itemID: item.id, time: bookmark.time)
            guard store.client === client else { return }
            bookmarks.removeAll { $0.id == bookmark.id }
        } catch { if store.client === client { store.errorMessage = L10n.error(error) } }
    }
    private func seek(to time: Double) async {
        let partition = store.partition
        if store.player?.currentMedia?.itemID != current.id { await store.play(current) }
        guard store.partition == partition, store.player?.currentMedia?.itemID == current.id,
              store.player?.currentMedia?.episodeID == nil else { return }
        await store.player?.seek(to: time)
    }
    private func reloadAfterManagement() async {
        guard let client = store.client, let partition = store.partition else { return }
        do {
            let fresh = try await client.item(id: item.id)
            guard store.client === client, store.partition == partition else { return }
            refreshedItem = fresh
            preparationRevision = UUID()
            if let index = store.items.firstIndex(where: { $0.id == fresh.id }) { store.items[index] = fresh }
            if store.selectedItem?.id == fresh.id { store.selectedItem = fresh }
            // Browse cards own paginated summaries, separate from store.items.
            store.libraryRevision = UUID()
            try await store.database?.save(fresh, key: "item.\(fresh.id)", partition: partition)
        } catch ABSError.http(status: 404, message: _) {
            guard store.client === client, store.partition == partition else { return }
            store.items.removeAll { $0.id == item.id }
            if store.selectedItem?.id == item.id { store.selectedItem = nil }
            store.libraryRevision = UUID()
            dismiss()
        } catch { if store.client === client, store.partition == partition { store.errorMessage = L10n.error(error) } }
    }
}

private struct DetailRowsPagination: View {
    let count: Int
    let pageSize: Int
    @Binding var page: Int
    let unit: String
    private var pageCount: Int { max(1, (count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(max(0, page), pageCount - 1) }

    var body: some View {
        if count > pageSize {
            HStack(spacing: 12) {
                Text(L10n.format("%1$@–%2$@ / 共 %3$@ %4$@", String(describing: currentPage * pageSize + 1), String(describing: min(count, (currentPage + 1) * pageSize)), String(describing: count), String(describing: unit)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { page = currentPage - 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0).help(L10n.tr("上一页")).accessibilityLabel(L10n.tr("上一页"))
                Picker(L10n.tr("页码"), selection: $page) {
                    ForEach(0..<pageCount, id: \.self) { index in Text(L10n.format("第 %1$@ / %2$@ 页", String(describing: index + 1), String(describing: pageCount))).tag(index) }
                }.labelsHidden().frame(width: 120).accessibilityLabel(L10n.tr("页码"))
                Button { page = currentPage + 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage == pageCount - 1).help(L10n.tr("下一页")).accessibilityLabel(L10n.tr("下一页"))
            }.controlSize(.small).padding(.vertical, 10)
        }
    }
}

private struct DetailPreparationKey: Equatable, Sendable {
    let itemID: String
    let partition: AccountPartition?
    let revision: UUID
    let tab: String
    let updatedAt: Double?
    let chapterCount: Int
    let files: [MediaFile]
    let episodeCount: Int
    let loading: Bool
}
private struct DetailChapterRow: Identifiable, Sendable {
    let id: Int
    let chapter: AudilseCore.Chapter
    let startTime: String
}
private struct DetailEpisodeRow: Identifiable {
    let id: Int
    let episode: PodcastEpisode
}
private struct DetailFileRow: Identifiable, Sendable {
    let id: Int
    let file: MediaFile
    let filename: String
    let size: String
    let icon: String
    let canRead: Bool
}
private enum DetailPreparedRows: Sendable {
    case chapters([DetailChapterRow])
    case files([DetailFileRow])
}

extension String {
    var shelfPlainText: String {
        replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
