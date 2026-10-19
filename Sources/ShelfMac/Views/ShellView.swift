import SwiftUI
import ShelfCore
import ShelfPlayback

struct ShellView: View {
    @Bindable var store: AppStore
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showAccounts = false
    @State private var subscriptionLibrary: Library?
    @State private var podcastActivityLibrary: Library?
    @State private var showServerManagement = false
    @State private var serverManagementSection: ServerAdminSection = .users
    @State private var dismissedTaskResults: Set<String> = []
    @State private var showPersonalSettings = false
    @State private var showRSS = false
    @State private var managedLibrary: Library?
    @State private var showLibraryOrganization = false
    @State private var showRestoreArchives = false
    @State private var narratorLibrary: Library?
    @State private var narratorChange: NarratorDirectoryChange?
    @State private var allDevicesSignOutSource: AllDevicesSignOutSource?
    @State private var presentedShellSheets: Set<ShellSheetKind> = []

    private enum ShellSheetKind: Hashable {
        case connection, detail, podcastActivity, subscription, serverManagement, personalSettings
        case rss, restoreArchives, library, libraryOrganization, narrators, allDevicesSignOut, conflict
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 270)
        } detail: {
            VStack(spacing: 0) {
                topBar
                Divider().opacity(0.4)
                if let batch = store.serverRecovery { ServerRecoveryView(store: store, batch: batch) }
                else if store.route == .downloads { DownloadsView(store: store) }
                else if case let .feature(kind) = store.route { FeatureBrowserView(store: store, kind: kind) }
                else if usesClassifiedSearch { LibrarySearchView(store: store) }
                else if store.route == .home, !store.isDemo, let library = store.currentLibrary {
                    HomeView(store: store, library: library)
                }
                else if case .library = store.route, let library = store.currentLibrary, !store.isDemo {
                    LibraryBrowserView(store: store, library: library).id((store.partition?.directoryName ?? "none") + "." + library.id)
                }
                else { libraryContent }
                serverActivityNotice
                if let notice = store.notice {
                    HStack {
                        Image(systemName: store.isOffline ? "wifi.slash" : "checkmark.circle.fill").foregroundStyle(ShelfTheme.accent)
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.notice = nil } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain)
                    }.padding(.horizontal, 28).padding(.vertical, 9).background(ShelfTheme.accent.opacity(0.04))
                }
                PlayerBar(store: store)
            }.background(ShelfTheme.canvas)
        }
        .toolbar(removing: .sidebarToggle)
        .onChange(of: store.serverTaskActivity.source) { _, _ in dismissedTaskResults = [] }
        .sheet(isPresented: $store.showConnection, onDismiss: { didDismissShellSheet(.connection) }) {
            ConnectionView(store: store).onAppear { presentedShellSheets.insert(.connection) }
        }
        .sheet(item: $store.selectedItem, onDismiss: {
            if store.selectedItem == nil { store.cancelDetailLoading() }
            didDismissShellSheet(.detail)
        }) { item in ItemDetailView(store: store, item: item).onAppear { presentedShellSheets.insert(.detail) } }
        .sheet(item: $podcastActivityLibrary, onDismiss: { didDismissShellSheet(.podcastActivity) }) { library in
            PodcastLibraryView(store: store, library: library).onAppear { presentedShellSheets.insert(.podcastActivity) }
        }
        .sheet(item: $subscriptionLibrary, onDismiss: { didDismissShellSheet(.subscription) }) { library in
            PodcastSubscriptionView(store: store, library: library).onAppear { presentedShellSheets.insert(.subscription) }
        }
        .sheet(isPresented: $showServerManagement, onDismiss: { didDismissShellSheet(.serverManagement) }) {
            ServerManagementView(store: store, initialSection: serverManagementSection).onAppear { presentedShellSheets.insert(.serverManagement) }
        }
        .sheet(isPresented: $showPersonalSettings, onDismiss: { didDismissShellSheet(.personalSettings) }) {
            PersonalSettingsView(store: store).onAppear { presentedShellSheets.insert(.personalSettings) }
        }
        .sheet(isPresented: $showRSS, onDismiss: { didDismissShellSheet(.rss) }) {
            RSSManagementView(store: store).onAppear { presentedShellSheets.insert(.rss) }
        }
        .sheet(isPresented: $showRestoreArchives, onDismiss: { didDismissShellSheet(.restoreArchives) }) {
            ServerRestoreArchivesView(store: store).onAppear { presentedShellSheets.insert(.restoreArchives) }
        }
        .sheet(item: $managedLibrary, onDismiss: { didDismissShellSheet(.library) }) { library in
            LibraryManagementView(store: store, library: library).onAppear { presentedShellSheets.insert(.library) }
        }
        .sheet(isPresented: $showLibraryOrganization, onDismiss: { didDismissShellSheet(.libraryOrganization) }) {
            LibraryManagementView(store: store).onAppear { presentedShellSheets.insert(.libraryOrganization) }
        }
        .sheet(item: $narratorLibrary, onDismiss: {
            commitNarratorChanges()
            didDismissShellSheet(.narrators)
        }) { library in
            NarratorDirectoryView(store: store, library: library, onChange: { change in
                if change.isCurrent(store) { narratorChange = change }
            }).onAppear { presentedShellSheets.insert(.narrators) }
        }
        .sheet(item: $allDevicesSignOutSource, onDismiss: {
            presentedShellSheets.remove(.allDevicesSignOut)
            if store.accountReauthenticationRequired { presentAccountReauthenticationIfReady() }
            else if !hasPresentedShellSheet, store.client == nil, store.user == nil, store.serverRecovery == nil,
               !store.recoveryBusy, !store.isConnecting { store.showConnection = true }
        }) { source in AllDevicesSignOutView(store: store, source: source).onAppear { presentedShellSheets.insert(.allDevicesSignOut) } }
        .sheet(item: Binding(get: { pendingConflict }, set: { if $0 == nil { store.conflicts = []; store.readingConflicts = [] } }), onDismiss: { didDismissShellSheet(.conflict) }) { issue in
            Group {
                switch issue {
                case .audio(let conflict): SyncConflictView(store: store, conflict: conflict)
                case .reading(let conflict): ReadingConflictView(store: store, conflict: conflict)
                }
            }.onAppear { presentedShellSheets.insert(.conflict) }
        }
        .alert(L10n.tr("暂时无法完成"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(L10n.tr("知道了"), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.displayErrorMessage ?? "") }
        .task(id: store.search) {
            guard store.client != nil || store.isOffline else { return }
            if case .feature = store.route { return }
            // Native home/library searches own their classified requests. The
            // legacy item task is retained only for the demo path.
            if !store.isDemo {
                if case .library = store.route { return }
                if store.route == .home { return }
            }
            do { try await Task.sleep(for: .milliseconds(300)); await store.loadLibrary() } catch { }
        }
        .onChange(of: store.route) { _, route in
            store.search = ""
            switch route {
            case .home where store.isDemo: Task { await store.loadLibrary() }
            case .library where store.isDemo: Task { await store.loadLibrary() }
            default: break
            }
        }
        .onChange(of: store.activePlayer?.errorDiagnostic) { _, issue in
            if let issue { store.presentError(issue) }
        }
        .onChange(of: store.accountReauthenticationRequired) { _, required in
            if required { dismissForAccountReauthentication() }
        }
        .onChange(of: store.serverRecovery?.id) { _, id in
            guard id != nil else { return }
            showAccounts = false; showServerManagement = false; showPersonalSettings = false
            showRSS = false; managedLibrary = nil; showLibraryOrganization = false; subscriptionLibrary = nil; podcastActivityLibrary = nil
            showRestoreArchives = false
            narratorLibrary = nil; narratorChange = nil; allDevicesSignOutSource = nil
        }
    }

    @ViewBuilder private var serverActivityNotice: some View {
        let results = store.serverTaskResults.filter { !dismissedTaskResults.contains($0.id) }
        if let latest = results.first {
            let failures = results.filter(\.isFailed)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(failures.isEmpty ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("服务器活动：%1$@ 项结束，%2$@ 项失败", String(results.count), String(failures.count))).font(.caption.bold())
                    if let failed = failures.first {
                        Text(ServerTasksPresentation.title(failed) + " · " + ServerTasksPresentation.error(failed)).font(.caption)
                    } else {
                        Text(ServerTasksPresentation.title(latest) + " · " + ServerTasksPresentation.description(latest)).font(.caption)
                    }
                }
                Spacer()
                Button(L10n.tr("查看任务")) { serverManagementSection = .tasks; showServerManagement = true }
                    .disabled(hasPresentedShellSheet)
                Button {
                    // Retain only IDs still in the bounded session cache.
                    dismissedTaskResults = Set(store.serverTaskResults.map(\.id))
                } label: { Image(systemName: "xmark") }.help(L10n.tr("关闭"))
            }.padding(.horizontal, 28).padding(.vertical, 9).background(Color.orange.opacity(failures.isEmpty ? 0.025 : 0.07))
        }
    }

    private var hasPresentedShellSheet: Bool {
        !presentedShellSheets.isEmpty || store.showConnection || store.selectedItem != nil || podcastActivityLibrary != nil
            || subscriptionLibrary != nil || showServerManagement || showPersonalSettings
            || showRSS || showRestoreArchives || managedLibrary != nil || showLibraryOrganization || narratorLibrary != nil
            || allDevicesSignOutSource != nil || pendingConflict != nil
    }

    private func didDismissShellSheet(_ kind: ShellSheetKind) {
        presentedShellSheets.remove(kind)
        presentAccountReauthenticationIfReady()
    }

    private func dismissForAccountReauthentication() {
        // The actual sheet's onDismiss opens login after AppKit finishes dismissing
        // its presentation. Starting a second sheet here can create an empty modal.
        let waitsForDismissal = hasPresentedShellSheet
        showAccounts = false; store.showConnection = false; store.selectedItem = nil
        showServerManagement = false; showPersonalSettings = false; showRSS = false
        podcastActivityLibrary = nil; subscriptionLibrary = nil; showRestoreArchives = false
        managedLibrary = nil; showLibraryOrganization = false; narratorLibrary = nil; narratorChange = nil; allDevicesSignOutSource = nil
        store.conflicts = []; store.readingConflicts = []
        if !waitsForDismissal { presentAccountReauthenticationIfReady() }
    }

    private func presentAccountReauthenticationIfReady() {
        guard !hasPresentedShellSheet else { return }
        store.presentAccountReauthentication()
    }

    private func commitNarratorChanges() {
        defer { narratorChange = nil }
        guard let change = narratorChange, change.isCurrent(store) else { return }
        // Failed eviction blocks old metadata reads in the database. Always
        // discard visible rows after a confirmed write, then retry eviction once.
        store.items = []; store.totalItems = 0
        store.libraryRevision = UUID()
        if !change.cacheInvalidated {
            let epoch = store.accountOperationID
            Task {
                do {
                    try await change.source.database.retryFailedCacheInvalidation(partition: change.source.partition)
                    guard store.accountOperationID == epoch, store.partition == change.source.partition else { return }
                    store.libraryRevision = UUID()
                } catch {
                    guard store.accountOperationID == epoch, store.partition == change.source.partition else { return }
                    store.notice = L10n.tr("服务器修改已确认。本机缓存清理失败，暂不使用旧缓存；请稍后重新打开朗读者页面重试。")
                }
            }
        }
    }

    private var usesClassifiedSearch: Bool {
        guard !store.isDemo, !store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .library = store.route { return true }
        return store.route == .home
    }

    private var canOrganizeLibraries: Bool {
        guard store.client != nil, let partition = store.partition, let profile = store.profile, let user = store.user,
              partition.serverID == profile.id, user.id == partition.userID, user.isActive, !store.isOffline, !store.isConnecting,
              store.serverRecovery == nil, !store.recoveryBusy else { return false }
        return AdminPolicy.allows(.manageLibraries, user: user)
    }

    private var pendingConflict: PendingSyncConflict? {
        if let conflict = store.conflicts.first { return .audio(conflict) }
        if let conflict = store.readingConflicts.first { return .reading(conflict) }
        return nil
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "books.vertical.fill").font(.system(size: 23)).foregroundStyle(ShelfTheme.accent)
                Text("Audisle").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 42).padding(.bottom, 29)
            List(selection: Binding<ShelfRoute?>(get: { store.route }, set: { if let route = $0 { store.route = route } })) {
                Section(L10n.tr("你的书房")) {
                    Label(L10n.tr("现在收听"), systemImage: "headphones").tag(ShelfRoute.home)
                    Label(L10n.tr("下载"), systemImage: "arrow.down.circle").tag(ShelfRoute.downloads)
                }
                if !store.libraries.isEmpty {
                    Section(L10n.tr("资料库")) {
                        ForEach(store.libraries) { library in
                            Label(library.name, systemImage: library.mediaType == "podcast" ? "mic" : "books.vertical")
                                .tag(ShelfRoute.library(library.id))
                        }
                    }
                    Section(L10n.tr("发现与整理")) {
                        ForEach(FeatureKind.allCases) { kind in Label(kind.title, systemImage: kind.symbol).tag(ShelfRoute.feature(kind)) }
                    }
                }
            }.listStyle(.sidebar).font(.system(size: 13))
            Spacer(minLength: 0)
            if store.isDemo {
                HStack { Image(systemName: "sparkles"); Text(L10n.tr("演示书库")); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
            }
            Divider().padding(.horizontal, 17).padding(.top, 16)
            Button { showAccounts.toggle() } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(ShelfTheme.accent.opacity(0.12)).frame(width: 34, height: 34)
                        Text(String((store.user?.username ?? "S").prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(ShelfTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.user?.username ?? L10n.tr("欢迎来到 ShelfMac")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(store.isDemo ? L10n.tr("连接自己的书库") : store.profile?.name ?? L10n.tr("连接你的 Audiobookshelf")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 18).contentShape(Rectangle())
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
                .popover(isPresented: $showAccounts, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.tr("账户与服务器")).font(.headline)
                        ForEach(store.profiles) { profile in
                            Button(profile.name + " · " + profile.username) { showAccounts = false; Task { await store.restore(profile) } }.buttonStyle(.plain)
                        }
                        Divider()
                        Button(L10n.tr("连接服务器…")) { showAccounts = false; store.showConnection = true }.buttonStyle(.plain)
                            .disabled(store.recoveryBusy)
                        if !store.restoreArchives.isEmpty {
                            Button(L10n.tr("本机恢复记录…")) { showAccounts = false; showRestoreArchives = true }.buttonStyle(.plain).disabled(store.recoveryBusy)
                        }
                        if store.client != nil {
                            Button(L10n.tr("个人设置与播放偏好…")) { showAccounts = false; showPersonalSettings = true }
                                .buttonStyle(.plain).disabled(store.user?.isActive != true || store.isConnecting)
                            if store.canPublish {
                                Button(L10n.tr("管理 RSS 订阅…")) { showAccounts = false; showRSS = true }.buttonStyle(.plain)
                            }
                            Button(L10n.tr("账户与服务器管理…")) { showAccounts = false; serverManagementSection = .users; showServerManagement = true }.buttonStyle(.plain)
                            if canOrganizeLibraries {
                                Button(L10n.tr("书库组织")) { showAccounts = false; showLibraryOrganization = true }
                                    .buttonStyle(.plain).accessibilityIdentifier("account.libraryOrganization")
                            }
                            Button(L10n.tr("退出当前账户")) { showAccounts = false; Task { await store.signOut() } }.buttonStyle(.plain)
                            if let source = AllDevicesSignOutSource(store: store) {
                                Button(L10n.tr("退出所有设备…")) { showAccounts = false; allDevicesSignOutSource = source }.buttonStyle(.plain)
                            }
                        }
                        SettingsLink { Text(L10n.tr("偏好设置…")) }.buttonStyle(.plain)
                    }.padding(20).frame(minWidth: 235, alignment: .leading)
                }
        }.background(.ultraThinMaterial)
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { columns = columns == .all ? .detailOnly : .all } } label: {
                Image(systemName: "sidebar.left").font(.system(size: 16)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help(L10n.tr("显示或隐藏侧边栏"))
            Text({ if case .library = store.route { return store.currentLibrary?.name ?? L10n.tr("书库") }; return store.route.title }())
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let library = store.currentLibrary, !store.isOffline, let user = store.user,
               AdminPolicy.allows(.manageLibraries, user: user) || AdminPolicy.allows(.upload, user: user) || AdminPolicy.allows(.updateContent, user: user) {
                Button { managedLibrary = library } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help(L10n.tr("管理当前书库"))
            } else if canOrganizeLibraries {
                Button(L10n.tr("书库组织"), systemImage: "square.stack.3d.up") { showLibraryOrganization = true }
                    .buttonStyle(.borderless).font(.caption).accessibilityIdentifier("library.organization")
            }
            if let library = store.currentLibrary, library.mediaType == "podcast", !store.isOffline {
                Button(L10n.tr("最新单集与队列"), systemImage: "clock.arrow.circlepath") { podcastActivityLibrary = library }
                    .buttonStyle(.borderless).font(.caption)
                Button(L10n.tr("订阅节目"), systemImage: "plus") { subscriptionLibrary = library }
                    .buttonStyle(.borderless).font(.caption)
            }
            if let library = store.currentLibrary, NarratorDirectorySource(store: store, library: library) != nil {
                Button(L10n.tr("朗读者"), systemImage: "person.wave.2") { narratorChange = nil; narratorLibrary = library }
                    .buttonStyle(.borderless).font(.caption).accessibilityIdentifier("library.narrators")
            }
            if store.isOffline {
                Label(L10n.tr("离线"), systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
            } else if store.client != nil {
                Circle().fill(.green.opacity(0.8)).frame(width: 5, height: 5).help(L10n.tr("服务器已连接"))
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("搜索书名、作者…"), text: $store.search).textFieldStyle(.plain).font(.system(size: 12))
                if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 11).padding(.vertical, 7).frame(width: 235).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).rotationEffect(.degrees(store.isLoading ? 30 : 0))
            }.buttonStyle(.plain).disabled(store.isLoading || store.isDemo || store.client == nil).help(L10n.tr("刷新书库"))
        }.padding(.horizontal, 30).frame(height: 64)
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if store.route == .home && store.search.isEmpty {
                    welcomeBanner
                    if !store.continueItems.isEmpty { continueSection }
                }
                if store.items.isEmpty && !store.isLoading {
                    if store.client == nil && !store.isDemo {
                        VStack(spacing: 20) {
                            QuietEmptyState(symbol: "books.vertical", title: L10n.tr("让好故事，常伴左右"), message: L10n.tr("连接你的 Audiobookshelf，把有声书、播客和阅读时光带到 Mac。"))
                            HStack(spacing: 12) {
                                Button(L10n.tr("连接服务器")) { store.showConnection = true }.buttonStyle(.borderedProminent).controlSize(.large)
                                Button(L10n.tr("浏览演示书库")) { Task { await store.enterDemo() } }.buttonStyle(.bordered).controlSize(.large)
                            }
                        }.padding(.bottom, 60)
                    } else {
                        QuietEmptyState(symbol: store.search.isEmpty ? "books.vertical" : "magnifyingglass", title: store.search.isEmpty ? L10n.tr("书库里还没有内容") : L10n.tr("没有找到相关内容"), message: store.search.isEmpty ? L10n.tr("添加内容到服务器后，刷新即可在这里看到。") : L10n.tr("试试其他书名或作者。"))
                        if store.libraries.isEmpty, store.search.isEmpty, canOrganizeLibraries {
                            Button(L10n.tr("创建书库"), systemImage: "plus") { showLibraryOrganization = true }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .accessibilityIdentifier("library.createFirst")
                        }
                    }
                } else {
                    SectionHeading(title: store.search.isEmpty ? (store.route == .home ? L10n.tr("探索你的书库") : store.currentLibrary?.name ?? L10n.tr("全部内容")) : L10n.tr("搜索结果"),
                                   subtitle: L10n.format("%1$@ %2$@，随时开始一段新旅程", String(describing: store.totalItems), String(describing: store.currentLibrary?.mediaType == "podcast" ? L10n.tr("个节目") : L10n.tr("本好书"))))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 210), spacing: 24, alignment: .top)], alignment: .leading, spacing: 28) {
                        ForEach(store.items) { item in
                            BookTile(store: store, item: item)
                                .onAppear {
                                    if item.id == store.items.last?.id, store.items.count < store.totalItems, !store.isLoading {
                                        Task { await store.loadLibrary(reset: false) }
                                    }
                                }
                        }
                    }
                }
                if store.isLoading { HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding() }
            }.padding(.horizontal, 32).padding(.top, 27).padding(.bottom, 32)
        }.scrollContentBackground(.hidden)
    }

    private var welcomeBanner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.37), Color(red: 0.25, green: 0.38, blue: 0.48)], startPoint: .leading, endPoint: .trailing))
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR EVERYDAY ESCAPE").font(.system(size: 9, weight: .semibold)).tracking(2.8).foregroundStyle(.white.opacity(0.56))
                    Text(L10n.tr("把时间，交给好故事。")).font(.system(size: 29, weight: .medium, design: .serif)).foregroundStyle(.white)
                    Text(L10n.tr("一段通勤，一杯咖啡，或一个安静的夜晚。\n你的下一段旅程，就在书架上。"))
                        .font(.system(size: 12)).lineSpacing(5).foregroundStyle(.white.opacity(0.66))
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(.white.opacity(0.07), lineWidth: 1).frame(width: 172, height: 172)
                    Circle().stroke(.white.opacity(0.09), lineWidth: 1).frame(width: 132, height: 132)
                    Circle().fill(.white.opacity(0.06)).frame(width: 92, height: 92)
                    Image(systemName: "headphones").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(.white.opacity(0.8))
                }.frame(width: 180).padding(.trailing, 5).accessibilityHidden(true)
            }.padding(.horizontal, 30).padding(.vertical, 25)
        }.frame(height: 195)
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: L10n.tr("接着上次的故事"), subtitle: L10n.tr("慢慢听，不必急着到达终点"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16)], spacing: 16) {
                ForEach(Array(store.continueItems.prefix(3))) { item in
                    Button { Task { await store.play(item) } } label: {
                        HStack(spacing: 13) {
                            CoverView(item: item, url: store.coverURL(item), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo").frame(width: 65, height: 76)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(item.authorName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                ProgressView(value: store.progressByItem[item.id]?.progress ?? 0).tint(ShelfTheme.accent).scaleEffect(y: 0.7)
                                Text(L10n.format("已听 %1$@%%", String(describing: Int((store.progressByItem[item.id]?.progress ?? 0) * 100))))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle.fill").font(.system(size: 25, weight: .light)).foregroundStyle(ShelfTheme.accent)
                        }.padding(12).background(ShelfTheme.card, in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private enum PendingSyncConflict: Identifiable {
    case audio(SyncConflict), reading(ReadingConflict)
    var id: String { switch self { case .audio(let conflict): "audio:" + conflict.id; case .reading(let conflict): "reading:" + conflict.id } }
}

struct BookTile: View {
    @Bindable var store: AppStore
    var item: ShelfCore.LibraryItem
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { Task { await store.open(item) } } label: {
                CoverView(item: item, url: store.coverURL(item), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo")
                    .aspectRatio(0.82, contentMode: .fit)
                    .shadow(color: .black.opacity(hovered ? 0.16 : 0.08), radius: hovered ? 10 : 5, y: 3)
            }.buttonStyle(.plain)
                    .overlay(alignment: .bottomTrailing) {
                        if hovered {
                            Button { Task { if item.mediaType == "podcast" { await store.open(item) } else { await store.play(item) } } } label: {
                                Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                                    .frame(width: 36, height: 36).background(.black.opacity(0.55), in: Circle())
                            }.buttonStyle(.plain).padding(10).help(item.mediaType == "podcast" ? L10n.tr("查看单集") : L10n.format("播放 %1$@", String(describing: item.title)))
                        }
                    }
            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(item.authorName.isEmpty ? L10n.tr("未知作者") : item.authorName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: item.mediaType == "podcast" ? "mic" : "headphones").font(.system(size: 9))
                Text(item.mediaType == "podcast" ? L10n.format("%1$@ 集", String(describing: item.media.episodes.count)) : item.media.duration.shelfDuration).font(.system(size: 10))
                Spacer()
                if store.downloads?.records.first(where: { $0.itemID == item.id })?.state == .ready {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 10)).foregroundStyle(ShelfTheme.accent)
                }
            }.foregroundStyle(.tertiary)
        }.onHover { value in withAnimation(.easeInOut(duration: 0.15)) { hovered = value } }
        .contextMenu {
            if item.mediaType != "podcast" { Button(L10n.tr("播放"), systemImage: "play") { Task { await store.play(item) } } }
            Button(L10n.tr("查看详情"), systemImage: "info.circle") { Task { await store.open(item) } }
            if store.canDownload && item.mediaType != "podcast" { Button(L10n.tr("下载到 Mac"), systemImage: "arrow.down.circle") { Task { await store.download(item) } } }
            Button(L10n.tr("标记为已完成"), systemImage: "checkmark.circle") { Task { await store.setFinished(item, finished: true) } }
        }
    }
}
