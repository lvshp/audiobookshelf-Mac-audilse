import SwiftUI
import Observation
import Charts
import AudilseCore

struct FeatureBrowserView: View {
    @Bindable var store: AppStore
    let kind: FeatureKind
    @State private var model = FeatureBrowserModel()
    @State private var selectedGroup: FeatureGroup?
    @State private var showEditor = false
    @State private var groupName = ""
    @State private var groupDescription = ""
    @State private var isSaving = false
    private var visibleGroups: [FeatureGroup] { model.groups.filter { store.search.isEmpty || $0.title.localizedCaseInsensitiveContains(store.search) } }
    private var canCreate: Bool { !store.isOffline && !store.isDemo && store.user?.isActive == true && store.client != nil && ( (kind == .collections && (store.user?.permissions.update == true || store.user?.isAdmin == true)) || kind == .playlists) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: kind.title, subtitle: subtitle, actionTitle: canCreate ? L10n.tr("新建") : nil, action: { groupName = ""; groupDescription = ""; showEditor = true })
                if [.authors, .series, .collections, .playlists].contains(kind) {
                    Picker(L10n.tr("书库"), selection: Binding(get: { store.currentLibrary?.id ?? "" }, set: { store.browsingLibraryID = $0 })) {
                        ForEach(store.libraries.filter { kind == .playlists || $0.mediaType == "book" }) { library in Text(library.name).tag(library.id) }
                    }.frame(maxWidth: 360).disabled(model.isLoading && store.search.isEmpty)
                }
                if store.isOffline { Text(L10n.tr("离线时仅搜索本机缓存的内容")).font(.caption).foregroundStyle(.secondary) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                if kind == .statistics { statistics }
                else if kind == .history { history }
                else if !visibleGroups.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205, maximum: 290), spacing: 20)], spacing: 22) {
                        ForEach(visibleGroups) { group in
                            Button { selectedGroup = group } label: {
                                VStack(alignment: .leading, spacing: 15) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12).fill(ShelfTheme.accent.opacity(0.065))
                                        if let book = group.books.first { CoverView(item: book, url: store.coverURL(book), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo").padding(16) }
                                        else { Image(systemName: kind.symbol).font(.system(size: 44, weight: .ultraLight)).foregroundStyle(ShelfTheme.accent.opacity(0.6)) }
                                    }.frame(height: 160)
                                    Text(group.title).font(.headline).lineLimit(1)
                                    Text("\(group.count) \(kind == .playlists ? L10n.tr("条内容") : L10n.tr("本书"))").font(.caption).foregroundStyle(.secondary)
                                }.padding(15).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 15))
                            }.buttonStyle(.plain)
                        }
                    }
                } else if !model.isLoading { QuietEmptyState(symbol: kind.symbol, title: L10n.format("还没有%1$@", String(describing: kind.title)), message: L10n.format("服务器中的%1$@会显示在这里。", String(describing: kind.title))) }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                if model.hasMore { Button(L10n.tr("载入更多")) { Task { await model.load(store: store, kind: kind, more: true) } }.frame(maxWidth: .infinity).disabled(model.isLoading) }
            }.padding(32)
        }
        .task(id: loadIdentity) { await model.load(store: store, kind: kind) }
        .sheet(item: $selectedGroup, onDismiss: { Task { await model.load(store: store, kind: kind) } }) { group in FeatureGroupDetailView(store: store, kind: kind, initial: group) }
        .sheet(isPresented: $showEditor) { groupEditor }
    }
    private var loadIdentity: String { (store.partition?.directoryName ?? "") + (store.client.map { String(describing: ObjectIdentifier($0)) } ?? "") + (store.currentLibrary?.id ?? "") + kind.rawValue + store.search + String(store.isOffline) + String(store.isConnecting) + (store.user?.id ?? "") + String(store.user?.isActive == true) }
    private var subtitle: String { switch kind { case .authors: L10n.tr("沿着喜爱的文字，发现更多故事"); case .series: L10n.tr("让故事接着讲下去"); case .collections: L10n.tr("将喜欢的书整理在一起"); case .playlists: L10n.tr("为下一段旅程准备好声音"); case .history: L10n.tr("你与故事度过的每一段时光"); case .statistics: L10n.tr("看见自己的收听习惯") } }
    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.format("新建%1$@", String(describing: kind.title))).font(.title3.bold())
            TextField(L10n.tr("名称"), text: $groupName).textFieldStyle(.shelfLeading)
            VStack(alignment: .leading, spacing: 6) { Text(L10n.tr("描述")).font(.caption).foregroundStyle(.secondary); LeadingTextEditor(text: $groupDescription).frame(height: 96).accessibilityLabel(L10n.tr("描述")) }
            HStack { Spacer(); Button(L10n.tr("取消")) { showEditor = false }; Button(L10n.tr("创建")) { Task { await createGroup() } }.buttonStyle(.borderedProminent).disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving) }
        }.padding(25).frame(width: 420)
    }
    private var history: some View {
        LazyVStack(spacing: 0) {
            if model.history.isEmpty && !model.isLoading { QuietEmptyState(symbol: kind.symbol, title: L10n.tr("尚无收听记录"), message: L10n.tr("开始播放后，记录会在这里保留。")) }
            ForEach(model.history.filter { store.search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(store.search) }) { entry in
                Button {
                    Task { if let id = entry.libraryItemId, let client = store.client, let partition = store.partition { do { let item = try await client.item(id: id); guard store.partition == partition else { return }; await store.open(item) } catch { if store.partition == partition { store.errorMessage = L10n.error(error) } } } }
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: entry.mediaType == "podcast" ? "mic" : "headphones").font(.title3).foregroundStyle(ShelfTheme.accent).frame(width: 42, height: 42).background(ShelfTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 6) { Text(entry.displayTitle).font(.callout.weight(.medium)); Text(entry.displayAuthor).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) { Text(L10n.tr("收听 ") + entry.timeListening.shelfDuration).font(.caption); Text(entry.date ?? "").font(.caption2).foregroundStyle(.secondary) }
                    }.padding(.vertical, 14).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().opacity(0.4)
            }
        }
    }
    private var statistics: some View {
        VStack(alignment: .leading, spacing: 25) {
            if let error = model.statisticsError { Label(L10n.tr("累计统计：") + error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            if let statistics = model.statistics {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 18) {
                    statistic(L10n.tr("累计收听"), value: listeningHours(statistics.totalTime), symbol: "headphones")
                    statistic(L10n.tr("今天"), value: listeningHours(statistics.today), symbol: "sun.max")
                    statistic(L10n.tr("收听天数"), value: L10n.format("%1$@ 天", String(describing: statistics.days.count)), symbol: "calendar")
                    statistic(L10n.tr("已完成内容"), value: L10n.format("%1$@ 条", String(describing: store.progressByItem.values.filter(\.isFinished).count)), symbol: "checkmark.circle")
                }
                weeklyStatistics(statistics)
                listeningDays(statistics)
                if !statistics.recentSessions.isEmpty {
                    Text(L10n.tr("最近的收听时光")).font(.headline)
                    ForEach(statistics.recentSessions) { entry in
                        HStack(spacing: 14) {
                            Image(systemName: entry.mediaType == "podcast" ? "mic" : "headphones").foregroundStyle(ShelfTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.displayTitle.isEmpty ? entry.mediaMetadata?.title ?? L10n.tr("内容") : entry.displayTitle).font(.callout)
                                Text(entry.date ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Text(entry.timeListening.shelfDuration).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !model.isLoading && model.statisticsError == nil {
                QuietEmptyState(symbol: "chart.bar", title: L10n.tr("还没有统计数据"), message: L10n.tr("连接服务器后即可查看收听统计。"))
            }
            Divider()
            HStack {
                Text(L10n.tr("年度回顾")).font(.title3.bold())
                Spacer()
                Picker(L10n.tr("年份"), selection: Binding(get: { model.selectedYear }, set: { year in
                    model.selectedYear = year
                    Task { await model.loadYear(store: store, year: year) }
                })) {
                    ForEach(model.availableYears, id: \.self) { year in Text(String(year)).tag(year) }
                }.frame(width: 155).disabled(store.isOffline)
                if model.isYearLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.loadYear(store: store, year: model.selectedYear) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.tr("刷新年度回顾")).disabled(store.isOffline || model.isYearLoading)
            }
            if let error = model.yearlyError { Label(L10n.tr("年度统计：") + error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
            if let yearly = model.currentYearly(store: store) {
                annualStatistics(yearly)
                PersonalYearReviewView(store: store, year: model.selectedYear, statistics: yearly)
                    .id((store.partition?.directoryName ?? "") + (store.client.map { String(describing: ObjectIdentifier($0)) } ?? "") + String(model.selectedYear))
            }
        }
    }
    private func weeklyStatistics(_ statistics: ListeningStatistics) -> some View {
        let days = recentListeningDays(statistics)
        let total = days.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("最近七天")).font(.headline)
            Chart(days, id: \.date) { day in
                BarMark(x: .value(L10n.tr("日期"), day.date, unit: .day), y: .value(L10n.tr("分钟"), day.seconds / 60))
                    .foregroundStyle(ShelfTheme.accent.gradient).cornerRadius(4)
            }.frame(height: 200).chartYAxisLabel(L10n.tr("分钟"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                statistic(L10n.tr("七天收听"), value: listeningHours(total), symbol: "clock")
                statistic(L10n.tr("日均收听"), value: listeningHours(total / 7), symbol: "divide.circle")
                statistic(L10n.tr("七天内最多的一天"), value: listeningHours(days.map(\.seconds).max() ?? 0), symbol: "star")
                statistic(L10n.tr("连续收听"), value: L10n.format("%1$@ 天", String(describing: listeningStreak(statistics))), symbol: "flame")
            }
        }.padding(20).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
    private func listeningDays(_ statistics: ListeningStatistics) -> some View {
        DisclosureGroup(L10n.format("全部收听日期 · %1$@ 天", String(describing: statistics.days.count))) {
            LazyVStack(spacing: 10) {
                ForEach(statistics.days.keys.sorted(by: >), id: \.self) { date in
                    HStack { Text(date); Spacer(); Text(listeningHours(statistics.days[date] ?? 0)).foregroundStyle(.secondary) }.font(.callout)
                }
            }.padding(.top, 14)
        }
    }
    private func annualStatistics(_ yearly: YearlyStatistics) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 18)], spacing: 18) {
                statistic(L10n.tr("年度收听"), value: listeningHours(yearly.totalListeningTime), symbol: "headphones")
                statistic(L10n.tr("有声书收听"), value: listeningHours(yearly.totalBookListeningTime), symbol: "book")
                statistic(L10n.tr("播客收听"), value: listeningHours(yearly.totalPodcastListeningTime), symbol: "mic")
                statistic(L10n.tr("收听次数"), value: L10n.format("%1$@ 次", String(describing: yearly.totalListeningSessions)), symbol: "play.circle")
                statistic(L10n.tr("听完书籍"), value: L10n.format("%1$@ 本", String(describing: yearly.numBooksFinished)), symbol: "checkmark.circle")
                statistic(L10n.tr("听过书籍"), value: L10n.format("%1$@ 本", String(describing: yearly.numBooksListened)), symbol: "books.vertical")
            }
            if yearly.totalListeningSessions == 0 && yearly.numBooksFinished == 0 {
                Text(L10n.tr("这一年还没有收听记录。")).font(.callout).foregroundStyle(.secondary)
            }
            if !yearly.topAuthors.isEmpty { annualRanking(L10n.tr("最常听的作者"), rows: yearly.topAuthors, genre: false) }
            if !yearly.topGenres.isEmpty { annualRanking(L10n.tr("最常听的分类"), rows: yearly.topGenres, genre: true) }
            if let narrator = yearly.mostListenedNarrator {
                annualHighlight(L10n.tr("最常听的旁白"), title: narrator.name ?? L10n.tr("未知旁白"), detail: listeningHours(narrator.time), symbol: "waveform")
            }
            if let month = yearly.mostListenedMonth, (0..<12).contains(month.month) {
                // ABS returns JavaScript's zero-based month index.
                annualHighlight(L10n.tr("收听最多的月份"), title: L10n.format("%1$@ 月", String(describing: month.month + 1)), detail: listeningHours(month.time), symbol: "calendar")
            }
            if let longest = yearly.longestAudiobookFinished {
                annualHighlight(L10n.tr("听完的最长有声书"), title: longest.title, detail: longest.duration.shelfDuration, symbol: "book.closed")
            }
        }
    }
    private func annualRanking(_ title: String, rows: [StatisticsRank], genre: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text("\(index + 1)").foregroundStyle(.tertiary).frame(width: 24)
                    Text((genre ? row.genre : row.name) ?? L10n.tr("未知"))
                    Spacer(); Text(listeningHours(row.time)).foregroundStyle(.secondary)
                }.font(.callout)
            }
        }.padding(20).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
    private func annualHighlight(_ label: String, title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(ShelfTheme.accent)
            VStack(alignment: .leading, spacing: 5) { Text(label).font(.caption).foregroundStyle(.secondary); Text(title).font(.headline) }
            Spacer(); Text(detail).font(.callout).foregroundStyle(.secondary)
        }.padding(20).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
    private func listeningHours(_ seconds: Double) -> String {
        let hours = max(0, seconds.isFinite ? seconds / 3_600 : 0)
        return hours.formatted(.number.precision(.fractionLength(1))) + L10n.tr(" 小时")
    }
    private func recentListeningDays(_ statistics: ListeningStatistics) -> [(date: Date, seconds: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return (date, statistics.days[listeningDateKey(date)] ?? 0)
        }
    }
    private func listeningStreak(_ statistics: ListeningStatistics) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var count = (statistics.days[listeningDateKey(today)] ?? 0) > 0 ? 1 : 0
        for offset in 1...10_000 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today), (statistics.days[listeningDateKey(date)] ?? 0) > 0 else { break }
            count += 1
        }
        return count
    }
    private func listeningDateKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func statistic(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) { Image(systemName: symbol).font(.title2.weight(.light)).foregroundStyle(ShelfTheme.accent); Text(value).font(.title2.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }
    private func createGroup() async {
        guard !isSaving, canCreate, let client = store.client, let library = store.currentLibrary, let partition = store.partition else { return }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines), description = groupDescription
        guard !name.isEmpty else { return }
        isSaving = true; defer { isSaving = false }
        do {
            if kind == .collections { _ = try await client.createCollection(.init(libraryId: library.id, name: name, description: description, books: [])) }
            else { _ = try await client.createPlaylist(.init(libraryId: library.id, name: name, description: description)) }
            guard store.partition == partition, store.client === client, store.currentLibrary?.id == library.id, !Task.isCancelled else { return }
            showEditor = false; await model.load(store: store, kind: kind)
        } catch { if store.partition == partition, store.client === client { store.errorMessage = L10n.error(error) } }
    }
}

private struct AuthorManagementTarget: Identifiable {
    let id = UUID()
    let authorID: String
    let source: LibraryPersonalSource
}

struct FeatureGroupDetailView: View {
    @Bindable var store: AppStore
    let kind: FeatureKind
    let initial: FeatureGroup
    private let library: Library?
    @Environment(\.dismiss) private var dismiss
    @State private var scope: PersonalAccountScope
    @State private var group: FeatureGroup?
    @State private var needsReload = true
    @State private var selectedBook: AudilseCore.LibraryItem?
    @State private var showAdd = false
    @State private var confirmDelete = false
    @State private var editName = ""
    @State private var editDescription = ""
    @State private var showEdit = false
    @State private var showRSS = false
    @State private var authorTarget: AuthorManagementTarget?
    @State private var authorChange: AuthorManagementChange?
    @State private var oldAuthorInvalidated = false
    init(store: AppStore, kind: FeatureKind, initial: FeatureGroup) {
        self.store = store; self.kind = kind; self.initial = initial
        library = store.libraries.first { $0.id == initial.libraryID } ?? store.currentLibrary
        _scope = State(initialValue: PersonalAccountScope(store: store))
    }
    private var current: FeatureGroup { group ?? initial }
    private var busy: Bool { scope.isWorking }
    private var editable: Bool { !needsReload && scope.context() != nil && (kind == .playlists || (kind == .collections && (store.user?.permissions.update == true || store.user?.isAdmin == true))) }
    private var canManageAuthor: Bool {
        guard kind == .authors, !needsReload, let library, library.mediaType == "book", let user = store.user else { return false }
        return LibraryPersonalSource(store: store, libraryID: library.id).isCurrent(store) &&
            (AdminPolicy.allows(.updateContent, user: user) || AdminPolicy.allows(.deleteContent, user: user))
    }
    private var entries: [PlaylistEntry] { kind == .playlists ? current.entries : current.books.map { .init(libraryItemId: $0.id, libraryItem: $0) } }
    private var existing: Set<PlaylistItemReference> { Set(entries.map { .init(libraryItemId: $0.libraryItemId, episodeId: $0.episodeId) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text(current.title).font(.title.bold()); Text(current.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                Spacer()
                if canManageAuthor, let library {
                    Button(L10n.tr("作者管理…"), systemImage: "person.crop.circle.badge.gearshape") {
                        let source = LibraryPersonalSource(store: store, libraryID: library.id)
                        guard source.isCurrent(store) else { return }
                        authorChange = nil; oldAuthorInvalidated = false
                        authorTarget = .init(authorID: current.id, source: source)
                    }.buttonStyle(.borderless).disabled(busy)
                }
                if store.canPublish, kind == .series || kind == .collections {
                    Button(L10n.tr("RSS 订阅…"), systemImage: "dot.radiowaves.left.and.right") { showRSS = true }.buttonStyle(.borderless).disabled(busy)
                }
                if editable {
                    Menu {
                        Button(L10n.tr("添加内容"), systemImage: "plus") { showAdd = true }
                        Button(L10n.tr("编辑名称与描述"), systemImage: "pencil") { editName = current.title; editDescription = current.summary; showEdit = true }
                        if kind == .collections { Button(L10n.tr("创建播放列表"), systemImage: "music.note.list") { Task { await convertToPlaylist() } } }
                        Divider(); Button(L10n.format("删除%1$@", String(describing: kind.title)), role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis.circle") }.menuIndicator(.hidden).disabled(busy)
                }
                SheetCloseButton(identifier: "feature-group.close") { dismiss() }
            }
            HStack {
                Button(L10n.tr("播放全部"), systemImage: "play.fill") { let snapshot = entries; Task { guard scope.canUseBoundAccount else { return }; await store.playGroup(entries: snapshot) } }.buttonStyle(.borderedProminent).disabled(busy || entries.isEmpty)
                Text(L10n.format("%1$@ 条内容", String(describing: current.count))).font(.caption).foregroundStyle(.secondary)
                Spacer(); if busy { ProgressView().controlSize(.small) }
            }
            if let error = scope.error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            if needsReload && !busy && !store.isOffline { Button(L10n.tr("重新载入")) { Task { await reload() } } }
            List {
                ForEach(entries) { entry in itemRow(entry) }
                    .onMove { offsets, destination in Task { await move(offsets, destination: destination) } }
                    .moveDisabled(!editable || busy)
            }.listStyle(.inset).disabled(busy)
            if editable { Text(L10n.tr("拖动调整顺序，右键移除内容。服务器中的原书籍会保留。")).font(.caption).foregroundStyle(.tertiary) }
        }.padding(24).frame(width: 740, height: 620)
        .task(id: initial.id) { await reload() }
        .sheet(item: $authorTarget, onDismiss: finishAuthorManagement) { target in
            if target.source.isCurrent(store) {
                AuthorManagementView(store: store, authorID: target.authorID, libraryID: target.source.libraryID) { change in
                    guard change.isCurrent(store), change.source == target.source else { return }
                    authorChange = change
                    if change.kind != .updated || change.author?.id != initial.id { oldAuthorInvalidated = true }
                    if let author = change.author, !oldAuthorInvalidated {
                        var updated = current
                        // Mutation responses are not expanded and omit numBooks.
                        updated.title = author.name; updated.summary = author.description ?? ""
                        group = updated
                    }
                }
            }
        }
        .sheet(item: $selectedBook) { item in ItemDetailView(store: store, item: item) }
        .sheet(isPresented: $showRSS) { RSSManagementView(store: store, target: .init(entity: kind == .series ? .series : .collection, id: current.id, title: current.title)) }
        .sheet(isPresented: $showAdd) {
            if let library {
                CatalogSelectionView(store: store, library: library, existing: existing, onAdd: add)
            }
        }
        .sheet(isPresented: $showEdit) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.format("编辑%1$@", String(describing: kind.title))).font(.headline)
                TextField(L10n.tr("名称"), text: $editName)
                VStack(alignment: .leading, spacing: 6) { Text(L10n.tr("描述")).font(.caption).foregroundStyle(.secondary); LeadingTextEditor(text: $editDescription).frame(height: 96).accessibilityLabel(L10n.tr("描述")) }
                if let error = scope.error { Text(error).foregroundStyle(.orange).font(.caption) }
                HStack { Spacer(); Button(L10n.tr("取消")) { showEdit = false }.disabled(busy); Button(L10n.tr("保存")) { Task { await saveEdit() } }.buttonStyle(.borderedProminent).disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy) }
            }.textFieldStyle(.shelfLeading).padding(25).frame(width: 420)
        }
        .alert(L10n.format("删除%1$@？", String(describing: kind.title)), isPresented: $confirmDelete) { Button(L10n.tr("取消"), role: .cancel) { }; Button(L10n.tr("删除"), role: .destructive) { Task { await deleteGroup() } } } message: { Text(L10n.tr("书籍文件和收听记录会保留。")) }
        .onChange(of: scope.identity) { _, _ in authorTarget = nil; scope.cancel(); dismiss() }
        .onChange(of: store.currentLibrary?.id) { _, _ in authorTarget = nil; scope.cancel(); dismiss() }
        .onDisappear { scope.cancel() }
    }
    private func finishAuthorManagement() {
        guard let change = authorChange, change.isCurrent(store) else { authorChange = nil; return }
        authorChange = nil
        store.libraryRevision = UUID()
        if oldAuthorInvalidated { scope.cancel(); dismiss() }
        else { needsReload = true; Task { await reload() } }
    }
    private func itemRow(_ entry: PlaylistEntry) -> some View {
        let item = entry.libraryItem
        let reference = PlaylistItemReference(libraryItemId: entry.libraryItemId, episodeId: entry.episodeId)
        return HStack(spacing: 13) {
            if let item { CoverView(item: item, url: store.coverURL(item), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo").frame(width: 38, height: 46) }
            Button(entry.episode?.title ?? item?.title ?? L10n.tr("内容")) { Task { await open(entry) } }.buttonStyle(.plain)
            Spacer()
            Button { Task { await play(reference, enqueue: false) } } label: { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(ShelfTheme.accent) }.buttonStyle(.plain).help(L10n.tr("播放"))
                .disabled(item?.mediaType == "book" && item?.media.duration == 0)
        }.padding(.vertical, 6).contextMenu {
            Button(L10n.tr("加入待播队列"), systemImage: "text.badge.plus") { Task { await play(reference, enqueue: true) } }.disabled(busy || store.isOffline)
            if editable { Button(L10n.format("从%1$@移除", String(describing: kind.title)), role: .destructive) { Task { _ = await remove(reference) } }.disabled(busy) }
        }
    }
    private func reload() async {
        guard let context = scope.context(), let library else { return }
        let id = initial.id, kind = kind
        await scope.run(context, operation: { try await fetchFeatureGroup(client: $0, kind: kind, id: id, libraryID: library.id) }, apply: { group = $0; needsReload = false })
    }
    private func open(_ entry: PlaylistEntry) async {
        guard scope.canUseBoundAccount else { return }
        if store.isOffline { selectedBook = entry.libraryItem; return }
        guard let context = scope.context() else { return }
        await scope.run(context, operation: { try await $0.item(id: entry.libraryItemId) }, apply: { selectedBook = $0 })
    }
    private func play(_ reference: PlaylistItemReference, enqueue: Bool) async {
        guard scope.canUseBoundAccount else { return }
        if store.isOffline {
            guard let entry = entries.first(where: { $0.id == reference.id }), let item = entry.libraryItem else { scope.error = L10n.tr("本机没有缓存此内容"); return }
            let episode = entry.episode ?? item.media.episodes.first { $0.id == reference.episodeId }
            guard item.mediaType != "podcast" || episode?.audioFile != nil else { scope.error = L10n.tr("本机没有缓存此播客单集"); return }
            await store.play(item, episode: episode)
            return
        }
        guard let context = scope.context() else { return }
        var item: AudilseCore.LibraryItem?
        let loaded = await scope.run(context, operation: { try await $0.item(id: reference.libraryItemId) }, apply: { item = $0 })
        guard loaded, scope.isCurrent(context), let item else { return }
        let episode = item.media.episodes.first { $0.id == reference.episodeId }
        guard item.mediaType != "podcast" || episode?.audioFile != nil else { scope.error = L10n.tr("此播客单集尚不可播放"); return }
        if enqueue { store.player?.enqueue(store.playbackMedia(item, episode: episode)) }
        else { await store.play(item, episode: episode) }
    }
    /// Mutation and its authoritative refresh share one busy interval and one account snapshot.
    private func mutate(_ action: @escaping @Sendable (ABSClient, String) async throws -> Void) async -> Bool {
        guard editable, !busy, let context = scope.context(), let library else { return false }
        let id = current.id, kind = kind
        needsReload = true
        return await scope.run(context, operation: { client in
            try await action(client, id)
            return try await fetchFeatureGroup(client: client, kind: kind, id: id, libraryID: library.id)
        }, apply: { group = $0; needsReload = false })
    }
    private func add(_ references: [PlaylistItemReference]) async -> Bool {
        let kind = kind
        return await mutate { client, id in
            if kind == .collections { _ = try await client.addCollectionBooks(id: id, itemIDs: references.map(\.libraryItemId)) }
            else { _ = try await client.addPlaylistItems(id: id, items: references) }
        }
    }
    private func remove(_ reference: PlaylistItemReference) async -> Bool {
        let kind = kind
        return await mutate { client, id in
            if kind == .collections { _ = try await client.removeCollectionBooks(id: id, itemIDs: [reference.libraryItemId]) }
            else { _ = try await client.removePlaylistItems(id: id, items: [reference]) }
        }
    }
    private func move(_ offsets: IndexSet, destination: Int) async {
        guard editable, !busy else { return }
        let kind = kind
        var references = entries.map { PlaylistItemReference(libraryItemId: $0.libraryItemId, episodeId: $0.episodeId) }
        references.move(fromOffsets: offsets, toOffset: destination)
        let ordered = references
        _ = await mutate { client, id in
            if kind == .collections { _ = try await client.updateCollection(id: id, update: .init(books: ordered.map(\.libraryItemId))) }
            else { _ = try await client.updatePlaylist(id: id, update: .init(items: ordered)) }
        }
    }
    private func saveEdit() async {
        let kind = kind, name = editName.trimmingCharacters(in: .whitespacesAndNewlines), description = editDescription
        guard !name.isEmpty else { return }
        let saved = await mutate { client, id in
            if kind == .collections { _ = try await client.updateCollection(id: id, update: .init(name: name, description: description)) }
            else { _ = try await client.updatePlaylist(id: id, update: .init(name: name, description: description)) }
        }
        if saved { showEdit = false }
    }
    private func deleteGroup() async {
        guard editable, let context = scope.context() else { return }
        let kind = kind, id = current.id
        await scope.run(context, operation: { client in if kind == .collections { try await client.deleteCollection(id: id) } else { try await client.deletePlaylist(id: id) } }, apply: { dismiss() })
    }
    private func convertToPlaylist() async {
        let saved = await mutate { client, id in _ = try await client.createPlaylist(collectionID: id) }
        if saved { store.notice = L10n.tr("已从集合创建播放列表") }
    }
}
