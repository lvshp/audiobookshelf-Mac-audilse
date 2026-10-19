import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AudilseCore

struct ServerManagementView: View {
    let store: AppStore
    @State private var model: ServerManagementModel
    @State private var showingStatistics = false
    @State private var playbackModel = ServerPlaybackSessionsModel()
    private var independentDetail: Bool { showingStatistics || model.section == .tasks || model.section == .playback }
    private enum Destination: Hashable { case section(ServerAdminSection), statistics }
    private var destination: Destination { showingStatistics ? .statistics : .section(model.section) }
    private var navigationSelection: Binding<Destination?> {
        Binding(get: { destination }, set: { selection in
            guard let selection else { return }
            switch selection {
            case .statistics: guard model.canManage else { return }; showingStatistics = true
            case .section(let section): showingStatistics = false; model.section = section
            }
        })
    }
    @State private var userEditor: ServerUserEditorTarget?
    @State private var userDetail: ServerUserDetailTarget?
    @State private var keyEditor: ServerKeyEditorTarget?
    @State private var keyIdentityEditor: ServerKeyIdentityTarget?
    @State private var notificationEditor: ServerNotificationEditorTarget?
    @State private var showingBackupImporter = false
    @State private var backupImportContext: ServerAdminContext?
    @State private var backupPath = ""
    @State private var providerName = ""
    @State private var providerURL = ""
    @State private var providerSecret = ""
    @State private var taxonomyOld = ""
    @State private var taxonomyNew = ""
    @State private var taxonomyIsGenre = false
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, initialSection: ServerAdminSection = .users) {
        self.store = store
        let model = ServerManagementModel(store: store)
        model.section = initialSection
        _model = State(initialValue: model)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) { Text(L10n.tr("服务器管理")).font(.title2.bold()); Text(store.profile?.name ?? "Audiobookshelf").foregroundStyle(.secondary).font(.caption) }
                Spacer()
                if model.isWorking && !independentDetail { ProgressView().controlSize(.small) }
                if !independentDetail { Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }.help(L10n.tr("刷新")).disabled(model.isWorking) }
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if !showingStatistics, model.section != .playback, let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(10) }
            else if !showingStatistics, model.section != .playback, let notice = model.notice { Text(notice).foregroundStyle(.secondary).font(.callout).padding(8) }
            HStack(spacing: 0) {
                List(selection: navigationSelection) {
                    ForEach(model.visibleSections) { section in Label(L10n.tr(section.rawValue), systemImage: section.icon).tag(Destination.section(section)) }
                    if model.canManage { Label(L10n.tr("服务器年度回顾"), systemImage: "chart.bar.xaxis").tag(Destination.statistics) }
                }
                    .listStyle(.sidebar).frame(width: 205).disabled(model.isWorking)
                Divider()
                if !model.canUsePersonal { ContentUnavailableView(L10n.tr("连接服务器后管理"), systemImage: "server.rack", description: Text(L10n.tr("请使用真实账户连接到服务器。"))) }
                else if showingStatistics { ServerStatisticsView(store: store).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { detail.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.isWorking && !independentDetail) }
            }
        }.frame(minWidth: 980, idealWidth: 1120, minHeight: 680, idealHeight: 790)
        .task(id: model.accountKey) { guard !Task.isCancelled else { return }; showingStatistics = false; userEditor = nil; userDetail = nil; keyEditor = nil; keyIdentityEditor = nil; notificationEditor = nil; showingBackupImporter = false; backupImportContext = nil; providerSecret = ""; providerName = ""; providerURL = ""; model.reset(); await model.load() }
        .task(id: destination) {
            guard !Task.isCancelled else { return }
            if independentDetail { model.cancelLoad(); return }
            model.page = 0; await model.load()
        }
        .onDisappear { model.reset(); playbackModel.cancel(); providerSecret = "" }
        .alert(model.confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            if let confirmation = model.confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) { model.confirmation = nil; Task { await confirmation.action() } }
                Button(L10n.tr("取消"), role: .cancel) { model.confirmation = nil }
            }
        } message: { Text(model.confirmation?.message ?? "") }
        .sheet(item: $userEditor) { target in
            ServerUserEditor(user: target.user, libraries: store.libraries) { draft, update in
                if let user = target.user { model.updateUser(user, update: update, context: target.context) }
                else { model.mutate(title: L10n.tr("创建用户"), message: L10n.tr("新用户将获得表单中勾选的访问权限。"), context: target.context) { _ = try await $0.createUser(draft) } }
            }
        }
        .sheet(item: $userDetail) { target in ServerUserDetailView(store: store, source: target.source) }
        .sheet(item: $keyEditor) { target in
            ServerAPIKeyEditor(store: store, source: target.source, users: target.users) {
                model.createKey($0, context: target.context, source: target.source)
            }
        }
        .sheet(item: $keyIdentityEditor) { target in
            ServerAPIKeyIdentityEditor(store: store, source: target.source, key: target.key, users: model.users) { model.updateKey(target.key, update: $0, context: target.context, source: target.source) }
        }
        .sheet(item: $notificationEditor) { target in
            ServerNotificationEditor(notification: target.notification, definitions: model.notifications?.data.events ?? [], libraries: store.libraries) { draft in
                if let notification = target.notification { model.mutate(title: L10n.tr("更新通知"), message: L10n.tr("启用的通知可能向指定地址发送书库事件。"), context: target.context) { _ = try await $0.updateNotification(id: notification.id, update: draft) } }
                else { model.mutate(title: L10n.tr("创建通知"), message: L10n.tr("启用后会向指定地址发送所选事件。"), context: target.context) { _ = try await $0.createNotification(draft) } }
            }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                guard let context = backupImportContext, model.isCurrent(context) else { return }
                model.mutate(title: L10n.tr("上传备份"), message: L10n.tr("只上传备份文件，恢复需要另行确认。"), context: context) { client in
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    _ = try await client.uploadBackup(file: .init(localURL: url))
                }
            case .failure(let error): model.error = L10n.error(error)
            }
        }
    }
    @ViewBuilder private var detail: some View {
        switch model.section {
        case .users: usersPanel
        case .sessions: sessionsPanel
        case .keys: keysPanel
        case .playback: playbackPanel
        case .backups: backupsPanel
        case .logs: logsPanel
        case .tasks: tasksPanel
        case .settings:
            if let settings = model.settings, let context = model.context() { ServerSettingsEditor(settings: settings, coverProviders: model.coverProviders) { draft in model.mutate(title: L10n.tr("保存服务器设置"), message: L10n.tr("将应用新的扫描、存储和安全设置。"), context: context) { client in
                var update = draft; let prefixes = update.sortingPrefixes; update.sortingPrefixes = nil
                _ = try await client.updateServerSettings(update)
                if let prefixes, !prefixes.isEmpty { _ = try await client.updateSortingPrefixes(prefixes) }
            } }.id(model.revision) }
        case .authentication:
            if let settings = model.authentication, let context = model.context() {
                ServerAuthenticationEditor(settings: settings, basePath: store.profile?.baseURL.path ?? "", loadConfiguration: { issuer in
                    guard model.isCurrent(context), context.isAdministrator, !Task.isCancelled else { throw CancellationError() }
                    var query = URLComponents(); query.path = "auth/openid/config"; query.queryItems = [.init(name: "issuer", value: issuer)]
                    guard let path = query.string else { throw ABSError.invalidResourcePath }
                    let config: ServerOIDCConfiguration = try await context.client.getJSON(path: path)
                    guard model.isCurrent(context), !Task.isCancelled else { throw CancellationError() }
                    return config
                }) { draft in model.mutate(title: L10n.tr("保存认证设置"), message: L10n.tr("认证方式或 OIDC 配置变更可能影响所有用户登录。请确认本地登录或正确的身份提供商仍可使用。"), context: context) { try await $0.updateAuthenticationSettings(draft) } }.id(model.revision)
            }
        case .smtp:
            if let settings = model.smtp, let context = model.context() { ServerSMTPEditor(settings: settings, users: model.users) { draft in model.mutate(title: L10n.tr("保存邮件设置"), message: L10n.tr("邮件服务将使用新的连接信息和阅读器设备访问规则。"), context: context, apply: { model.smtp = $0 }) { try await $0.updateSMTPSettings(draft) } } test: { model.mutate(title: L10n.tr("发送测试邮件"), message: L10n.tr("将向配置的测试地址发送一封邮件。"), context: context) { try await $0.sendSMTPTest() } }.id(model.revision) }
        case .notifications: notificationsPanel
        case .providers: providersPanel
        case .taxonomy: taxonomyPanel
        }
    }
    private var usersPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.tr("用户与细粒度权限")).font(.title3.bold()); Spacer(); Button(L10n.tr("新建用户"), systemImage: "plus") { if let context = model.context() { userEditor = .init(user: nil, context: context) } } }
            List(model.users) { user in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(user.username).font(.headline); Text("\(user.type) · \(user.isActive == false ? L10n.tr("已停用") : L10n.tr("有效"))\(user.isOpenID ? " · OIDC" : "")").foregroundStyle(.secondary).font(.caption) }
                    Spacer()
                    Button(L10n.tr("活动详情")) { if let source = ServerUserDetailSource(store: store, userID: user.id) { userDetail = .init(source: source) } }
                    Button(L10n.tr("编辑")) { if let context = model.context() { userEditor = .init(user: user, context: context) } }.disabled(user.type == "root" && store.user?.type != "root")
                    if user.isOpenID { Button(L10n.tr("解除 OIDC")) { model.mutate(title: L10n.tr("解除 OIDC 关联"), message: L10n.format("%1$@ 将无法通过原有 OIDC 身份关联登录。", String(describing: user.username)), destructive: true) { try await $0.unlinkUserOpenID(id: user.id) } } }
                    if user.type != "root" && user.id != store.user?.id { Button(L10n.tr("删除"), role: .destructive) { model.mutate(title: L10n.tr("删除用户"), message: L10n.format("将删除 %1$@ 及其进度等个人数据。", String(describing: user.username)), destructive: true) { try await $0.deleteUser(id: user.id) } } }
                }.padding(.vertical, 6)
            }.overlay { if model.users.isEmpty { ContentUnavailableView(L10n.tr("暂无用户"), systemImage: "person.2") } }
        }.padding(20)
    }
    private var sessionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("当前账户的活跃登录")).font(.title3.bold())
            if !model.capabilities.hasAuthenticationSessions { ContentUnavailableView(L10n.tr("服务器版本暂不支持"), systemImage: "desktopcomputer", description: Text(L10n.tr("活跃登录管理需要 Audiobookshelf 2.37.1 或更高版本。"))) }
            else {
                List(model.sessions?.sessions ?? []) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text([session.deviceInfo?.browserName, session.deviceInfo?.osName].compactMap { $0 }.joined(separator: " · ").shelfFallback(L10n.tr("未知设备"))).font(.headline)
                            Text("\(session.ipAddress ?? "")\(session.current ? L10n.tr(" · 此 Mac") : "")").foregroundStyle(.secondary)
                            Text(L10n.format("最近使用 %1$@", String(describing: adminDate(session.updatedAt)))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Button(L10n.tr("撤销登录"), role: .destructive) { model.revokeSession(session) }
                    }.padding(.vertical, 5)
                }
                paging(total: model.sessions?.numPages ?? 0)
            }
        }.padding(20)
    }
    private var keysPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.tr("API 密钥")).font(.title3.bold()); Spacer(); Button(L10n.tr("创建密钥"), systemImage: "plus") {
                if let context = model.context(), let source = ServerAPIKeySource(store: store) {
                    keyEditor = .init(context: context, source: source, users: model.users)
                }
            }.disabled(!model.capabilities.hasAPIKeys) }
            if !model.capabilities.hasAPIKeys { ContentUnavailableView(L10n.tr("需要服务器 2.37.1"), systemImage: "key") }
            else {
                if !model.newKeySecret.isEmpty {
                    GroupBox(L10n.tr("新密钥仅显示一次")) {
                        HStack { SecureField(L10n.tr("API 密钥"), text: $model.newKeySecret).textFieldStyle(.shelfLeading); Button(L10n.tr("复制")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.newKeySecret, forType: .string) }; Button(L10n.tr("隐藏")) { model.newKeySecret = "" } }
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.keys) { key in
                    HStack {
                        VStack(alignment: .leading) { Text(key.name).font(.headline); Text("\(key.user?.username ?? key.userId) · \(key.isActive ? L10n.tr("有效") : L10n.tr("已停用")) · \(key.expiresAt ?? L10n.tr("永不过期"))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(L10n.tr("编辑身份")) {
                            if let context = model.context(), let source = ServerAPIKeySource(store: store) { keyIdentityEditor = .init(key: key, source: source, context: context) }
                        }.disabled((key.user?.type ?? model.users.first { $0.id == key.userId }?.type) == "root" && store.user?.type != "root")
                        Button(key.isActive ? L10n.tr("停用") : L10n.tr("启用")) {
                            if let context = model.context(), let source = ServerAPIKeySource(store: store) { model.updateKey(key, update: .init(isActive: !key.isActive), context: context, source: source) }
                        }.disabled((key.user?.type ?? model.users.first { $0.id == key.userId }?.type) == "root" && store.user?.type != "root" || !key.isActive && !APIKeyEditingPolicy.mayEnable(key))
                        Button(L10n.tr("删除"), role: .destructive) { model.mutate(title: L10n.tr("删除密钥"), message: L10n.tr("持有此密钥的客户端将失去访问权限。"), destructive: true) { try await $0.deleteAPIKey(id: key.id) } }
                    }.padding(.vertical, 8)
                            Divider()
                        }
                    }.padding(.horizontal, 8)
                }
            }
        }.padding(20)
    }
    private var playbackPanel: some View {
        ServerPlaybackSessionsView(store: store, model: playbackModel)
    }
    private var backupsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.tr("备份与恢复")).font(.title3.bold()); Spacer(); Button(L10n.tr("上传备份")) { backupImportContext = model.context(); showingBackupImporter = backupImportContext != nil }; Button(L10n.tr("创建备份"), systemImage: "plus") { model.mutate(title: L10n.tr("创建备份")) { _ = try await $0.createBackup() } } }
            List(model.backups?.backups ?? []) { backup in
                HStack {
                    VStack(alignment: .leading) { Text(backup.filename).font(.headline); Text("\(backup.serverVersion ?? "") · \(adminDate(backup.createdAt)) · \(ByteCountFormatter.string(fromByteCount: backup.fileSize ?? 0, countStyle: .file))").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button(L10n.tr("导出")) { exportBackup(backup) }
                    Button(L10n.tr("恢复"), role: .destructive) { model.restoreBackup(backup) }
                    Button(L10n.tr("删除"), role: .destructive) { model.mutate(title: L10n.tr("删除备份"), message: L10n.format("将永久删除服务器上的 %1$@。", String(describing: backup.filename)), destructive: true) { _ = try await $0.deleteBackup(id: backup.id) } }
                }.padding(.vertical, 5)
            }
            HStack { TextField(L10n.tr("服务器备份目录"), text: $backupPath).textFieldStyle(.shelfLeading); Button(L10n.tr("更改目录")) { let path = backupPath; model.mutate(title: L10n.tr("更改备份目录"), message: L10n.tr("将更改服务器保存备份的位置。")) { try await $0.updateBackupLocation(path: path) } }.disabled(backupPath.isEmpty || model.backups?.backupPathEnvSet == true) }
                .onChange(of: model.backups?.backupLocation, initial: true) { _, value in backupPath = value ?? "" }
        }.padding(20)
    }
    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.tr("实时日志")).font(.title3.bold()); Spacer(); Picker(L10n.tr("级别"), selection: $model.logLevel) { ForEach(ServerLogLevel.allCases, id: \.self) { Text(L10n.tr($0.settingsLabel)).tag($0) } }.pickerStyle(.menu).frame(width: 180).onChange(of: model.logLevel) { _, _ in model.updateLogLevel() } }
            List(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) { Text("\(entry.timestamp ?? "")  \(entry.levelName ?? "")  \(entry.source ?? "")").foregroundStyle(.secondary); Text(entry.message ?? "") }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }.padding(20)
    }
    private var tasksPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ServerTasksView(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button(L10n.tr("清理服务器缓存")) { model.mutate(title: L10n.tr("清理服务器缓存"), message: L10n.tr("将移除可重新生成的缓存；之后的访问可能稍慢。"), destructive: true) { try await $0.purgeServerCache() } }
                Button(L10n.tr("清理内容缓存")) { model.mutate(title: L10n.tr("清理内容缓存"), message: L10n.tr("将清理服务器生成的内容缓存，原件保留。"), destructive: true) { try await $0.purgeItemCache() } }
            }.disabled(model.isWorking)
        }.padding(20)
    }
    private var notificationsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.tr("通知")).font(.title3.bold()); Spacer(); Button(L10n.tr("新建通知"), systemImage: "plus") { if let context = model.context() { notificationEditor = .init(notification: nil, context: context) } } }
            if let settings = model.notifications?.settings, let context = model.context() {
                ServerNotificationSettingsEditor(settings: settings) { draft in model.mutate(title: L10n.tr("保存通知设置"), message: L10n.tr("通知事件将通过配置的 Apprise 服务发出。"), context: context) { try await $0.updateNotificationSettings(draft) } }.id(model.revision)
                List(settings.notifications) { notification in
                    HStack {
                        VStack(alignment: .leading) { Text(notification.eventName).font(.headline); Text(L10n.format("%1$@ · %2$@ 个接收地址", String(describing: notification.enabled ? L10n.tr("启用") : L10n.tr("停用")), String(describing: notification.urls.count))).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button(L10n.tr("编辑")) { notificationEditor = .init(notification: notification, context: context) }
                        Button(L10n.tr("测试")) { model.mutate(title: L10n.tr("发送通知测试"), message: L10n.tr("将向此通知配置的接收地址发送测试消息。")) { try await $0.sendNotificationTest(id: notification.id) } }
                        Button(L10n.tr("删除"), role: .destructive) { model.mutate(title: L10n.tr("删除通知"), message: L10n.tr("将移除此事件通知规则。"), destructive: true) { _ = try await $0.deleteNotification(id: notification.id) } }
                    }
                }
            }
        }.padding(20)
    }
    private var providersPanel: some View {
        Form {
            Section(L10n.tr("自定义元数据来源")) { ForEach(model.providers) { provider in HStack { VStack(alignment: .leading) { Text(provider.name).font(.headline); Text(provider.url).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(L10n.tr("删除"), role: .destructive) { model.mutate(title: L10n.tr("删除元数据来源"), message: L10n.tr("使用此来源的书库会恢复默认提供商。"), destructive: true) { try await $0.deleteCustomMetadataProvider(id: provider.id) } } } } }
            Section(L10n.tr("添加图书元数据来源")) { FormInputRow(L10n.tr("名称")) { TextField("", text: $providerName).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("名称")) }; FormInputRow(L10n.tr("服务地址")) { TextField("", text: $providerURL).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("服务地址")) }; FormInputRow(L10n.tr("Authorization（可选）")) { SecureField("", text: $providerSecret).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("Authorization（可选）")) }; Button(L10n.tr("添加来源")) { let draft = CustomMetadataProviderDraft(name: providerName, url: providerURL, authHeaderValue: providerSecret.isEmpty ? nil : providerSecret); model.mutate(title: L10n.tr("添加元数据来源"), message: L10n.tr("服务器将向此地址请求内容信息，并发送填写的认证头。")) { _ = try await $0.createCustomMetadataProvider(draft) }; providerSecret = "" }.disabled(providerName.isEmpty || providerURL.isEmpty) }
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    private var taxonomyPanel: some View {
        Form {
            Section(L10n.tr("服务器标签与分类")) { Picker(L10n.tr("范围"), selection: $taxonomyIsGenre) { Text(L10n.tr("标签")).tag(false); Text(L10n.tr("分类")).tag(true) }.pickerStyle(.segmented); Text((taxonomyIsGenre ? model.genres : model.tags).joined(separator: " · ")).textSelection(.enabled); FormInputRow(L10n.tr("原名称")) { TextField("", text: $taxonomyOld).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("原名称")) }; FormInputRow(L10n.tr("新名称")) { TextField("", text: $taxonomyNew).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("新名称")) }
                HStack { Button(L10n.tr("重命名或合并")) { let old = taxonomyOld, new = taxonomyNew, genre = taxonomyIsGenre; model.mutate(title: L10n.tr("更改分类标签"), message: L10n.tr("服务器中所有使用该名称的内容都会更新，已存在的新名称会合并。")) { client in if genre { _ = try await client.renameServerGenre(old, to: new) } else { _ = try await client.renameServerTag(old, to: new) } } }.disabled(taxonomyOld.isEmpty || taxonomyNew.isEmpty)
                    Button(L10n.tr("删除"), role: .destructive) { let old = taxonomyOld, genre = taxonomyIsGenre; model.mutate(title: L10n.tr("删除分类标签"), message: L10n.tr("将从所有内容中移除此名称。"), destructive: true) { client in if genre { _ = try await client.deleteServerGenre(old) } else { _ = try await client.deleteServerTag(old) } } }.disabled(taxonomyOld.isEmpty) }
            }
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    private func paging(total: Int) -> some View { HStack { Button(L10n.tr("上一页")) { model.page = max(0, model.page - 1); Task { await model.load() } }.disabled(model.page == 0); Text(L10n.format("第 %1$@ / %2$@ 页", String(describing: model.page + 1), String(describing: max(1, total)))).font(.caption).foregroundStyle(.secondary); Button(L10n.tr("下一页")) { model.page += 1; Task { await model.load() } }.disabled(model.page + 1 >= total) } }
    private func exportBackup(_ backup: ServerBackup) {
        guard let context = model.context() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = backup.filename; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { if await model.run(context, operation: { try await $0.downloadBackup(id: backup.id, destination: destination) }) { model.notice = L10n.tr("备份已导出") } }
    }
}
private struct ServerUserEditorTarget: Identifiable { let id = UUID(); let user: AdminUser?; let context: ServerAdminContext }
private struct ServerUserDetailTarget: Identifiable { let id = UUID(); let source: ServerUserDetailSource }
// Keep presentation and its required data in one state value. A boolean sheet with
// separately captured optional state can initially render EmptyView (a 0×0 sheet).
private struct ServerKeyEditorTarget: Identifiable { let id = UUID(); let context: ServerAdminContext; let source: ServerAPIKeySource; let users: [AdminUser] }
private struct ServerKeyIdentityTarget: Identifiable { let id = UUID(); let key: APIKeyRecord; let source: ServerAPIKeySource; let context: ServerAdminContext }
private struct ServerNotificationEditorTarget: Identifiable { let id = UUID(); let notification: ServerNotification?; let context: ServerAdminContext }
func adminDate(_ milliseconds: Double?) -> String { guard let milliseconds else { return L10n.tr("未知") }; return Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .shortened) }
private extension String { func shelfFallback(_ fallback: String) -> String { isEmpty ? fallback : self } }
