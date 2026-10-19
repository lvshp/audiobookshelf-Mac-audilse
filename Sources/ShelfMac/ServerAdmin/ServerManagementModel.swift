import Foundation
import Observation
import ShelfCore

enum ServerAdminSection: String, CaseIterable, Identifiable {
    case users = "用户与权限", sessions = "活跃登录", keys = "API 密钥", playback = "收听会话", backups = "备份与恢复", logs = "服务器日志", tasks = "任务与缓存", settings = "服务器设置", authentication = "认证与 OIDC", smtp = "邮件与阅读器", notifications = "通知", providers = "元数据来源", taxonomy = "标签与分类"
    var id: String { rawValue }
    var icon: String {
        switch self { case .users: "person.2"; case .sessions: "desktopcomputer"; case .keys: "key"; case .playback: "clock.arrow.circlepath"; case .backups: "externaldrive.badge.timemachine"; case .logs: "text.alignleft"; case .tasks: "checklist"; case .settings: "gearshape"; case .authentication: "lock.shield"; case .smtp: "envelope"; case .notifications: "bell"; case .providers: "books.vertical"; case .taxonomy: "tag" }
    }
}
struct ServerAdminContext: Sendable {
    let client: ABSClient; let profileID: UUID; let userID: String; let isAdministrator: Bool
    let accountEpoch: UUID
    let user: UserAccount
}
struct ServerAdminConfirmation: Identifiable {
    let id = UUID(); let title: String; let message: String; let destructive: Bool; let action: @MainActor () async -> Void
    init(title: String, message: String, destructive: Bool = false, action: @escaping @MainActor () async -> Void) {
        self.title = title; self.message = message; self.destructive = destructive; self.action = action
    }
}

@MainActor @Observable final class ServerManagementModel {
    let store: AppStore
    var section: ServerAdminSection = .users
    var isWorking = false
    var error: String?
    var notice: String?
    var revision = UUID()
    var confirmation: ServerAdminConfirmation?
    var users: [AdminUser] = []
    var sessions: AuthenticationSessionPage?
    var keys: [APIKeyRecord] = []
    var newKeySecret = ""
    var backups: BackupListing?
    var logs: [ServerLogEntry] = []
    var logLevel: ServerLogLevel = .info
    var tasks: ServerTaskListing?
    var settings: ServerSettingsUpdate?
    var coverProviders: [MetadataProvider] = []
    var authentication: AuthenticationSettings?
    var smtp: SMTPSettings?
    var notifications: ServerNotificationConfiguration?
    var providers: [CustomMetadataProvider] = []
    var tags: [String] = []
    var genres: [String] = []
    var page = 0
    var editorContext: ServerAdminContext?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var cancelOperation: (() -> Void)?
    @ObservationIgnored private var logClient: ABSRealtimeClient?
    @ObservationIgnored private var logTask: Task<Void, Never>?
    init(store: AppStore) { self.store = store; if store.user?.isAdmin != true { section = .sessions } }
    var accountKey: String {
        [store.profile?.id.uuidString ?? "", store.user?.id ?? "", store.user?.type ?? "",
         store.client.map { String(describing: ObjectIdentifier($0)) } ?? "", store.profile?.serverVersion ?? "",
         store.accountOperationID.uuidString, String(store.user?.isActive == true), String(store.isOffline), String(store.isConnecting)].joined(separator: ":")
    }
    var canManage: Bool { canUsePersonal && store.user.map { AdminPolicy.allows(.manageServer, user: $0) } == true }
    var canUsePersonal: Bool {
        guard store.user?.isActive == true, !store.isOffline, !store.isConnecting, !store.isDemo,
              let partition = store.partition, let profile = store.profile, let user = store.user, store.client != nil else { return false }
        return partition.serverID == profile.id && partition.userID == user.id
    }
    var capabilities: AdminCapabilities { .init(version: store.profile?.serverVersion) }
    var visibleSections: [ServerAdminSection] { canManage ? ServerAdminSection.allCases : [.sessions] }
    func context() -> ServerAdminContext? {
        guard canUsePersonal, let client = store.client, let profile = store.profile, let user = store.user else { return nil }
        return .init(client: client, profileID: profile.id, userID: user.id, isAdministrator: canManage, accountEpoch: store.accountOperationID, user: user)
    }
    func isCurrent(_ context: ServerAdminContext) -> Bool { store.accountOperationID == context.accountEpoch && store.client === context.client && store.profile?.id == context.profileID && store.user.map { $0.username == context.user.username && AccountUpdatePolicy.hasSameAccess($0, context.user) } == true && canUsePersonal && (!context.isAdministrator || canManage) }
    func reset() {
        cancelOperation?(); cancelOperation = nil
        lifecycle = UUID()
        operationID = UUID(); isWorking = false; error = nil; notice = nil; confirmation = nil; editorContext = nil
        users = []; sessions = nil; keys = []; newKeySecret = ""; backups = nil; logs = []; tasks = nil; settings = nil; coverProviders = []; authentication = nil; smtp = nil; notifications = nil; providers = []; tags = []; genres = []; page = 0
        stopLogs(); if !canManage { section = .sessions }; revision = UUID()
    }
    func cancelLoad() { cancelOperation?(); cancelOperation = nil; lifecycle = UUID(); confirmation = nil; operationID = UUID(); isWorking = false; stopLogs() }
    func load() async {
        guard let context = context(), section == .sessions || context.isAdministrator else { return }
        let selected = section, page = page
        if selected != .logs { stopLogs() }
        switch selected {
        case .users: _ = await run(context, operation: { try await $0.adminUsers() }, apply: { users = $0 })
        case .sessions:
            guard capabilities.hasAuthenticationSessions else { sessions = nil; return }
            _ = await run(context, operation: { try await $0.authenticationSessions(page: page) }, apply: { sessions = $0 })
        case .keys:
            guard capabilities.hasAPIKeys else { keys = []; return }
            _ = await run(context, operation: { try await $0.apiKeys() }, apply: { keys = $0 })
            if users.isEmpty { _ = await run(context, operation: { try await $0.adminUsers() }, apply: { users = $0 }) }
        case .playback: break // ServerPlaybackSessionsModel independently scopes every list and action.
        case .backups: _ = await run(context, operation: { try await $0.backups() }, apply: { backups = $0 })
        case .logs:
            if await run(context, operation: { try await $0.serverLogs() }, apply: { logs = Array($0.suffix(1000)) }) { await startLogs(context) }
        case .tasks: break // The independently scoped ServerTasksModel owns this page.
        case .settings:
            _ = await run(context, operation: { client in
                async let settings = client.serverSettings()
                let catalog = try? await client.metadataProviders()
                return (try await settings, catalog?.booksCovers ?? [])
            }, apply: { settings = $0.0; coverProviders = $0.1 })
        case .authentication: _ = await run(context, operation: { try await $0.authenticationSettings() }, apply: { authentication = $0 })
        case .smtp:
            _ = await run(context, operation: { try await $0.smtpSettings() }, apply: { smtp = $0 })
            if users.isEmpty { _ = await run(context, operation: { try await $0.adminUsers() }, apply: { users = $0 }) }
        case .notifications: _ = await run(context, operation: { try await $0.notificationConfiguration() }, apply: { notifications = $0 })
        case .providers: _ = await run(context, operation: { try await $0.customMetadataProviders() }, apply: { providers = $0 })
        case .taxonomy:
            _ = await run(context, operation: { client in async let tags = client.serverTags(); async let genres = client.serverGenres(); return try await (tags, genres) }, apply: { tags = $0.0; genres = $0.1 })
        }
    }
    @discardableResult func run<Value: Sendable>(_ context: ServerAdminContext, operation: @escaping @Sendable (ABSClient) async throws -> Value, apply: (Value) -> Void = { _ in }) async -> Bool {
        guard !Task.isCancelled, isCurrent(context), !isWorking else { return false }
        let operationID = UUID(); self.operationID = operationID; isWorking = true; error = nil
        let task = Task { try Task.checkCancellation(); return try await operation(context.client) }
        cancelOperation = { task.cancel() }
        defer { task.cancel(); if self.operationID == operationID { isWorking = false; cancelOperation = nil } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, isCurrent(context), self.operationID == operationID else { return false }
            apply(value); revision = UUID(); return true
        } catch is CancellationError { return false
        } catch ABSError.sessionChanged { return false
        } catch {
            guard !Task.isCancelled, isCurrent(context), self.operationID == operationID else { return false }
            self.error = L10n.error(error); return false
        }
    }
    func mutate<Value: Sendable>(title: String, message: String? = nil, destructive: Bool = false, context suppliedContext: ServerAdminContext? = nil, apply: @escaping @MainActor (Value) -> Void = { _ in }, operation: @escaping @Sendable (ABSClient) async throws -> Value) {
        guard let context = suppliedContext ?? context(), context.isAdministrator, isCurrent(context) else { return }
        let lifecycle = lifecycle
        let action: @MainActor () async -> Void = { [weak self] in
            guard let self, self.lifecycle == lifecycle, self.isCurrent(context) else { return }
            if await self.run(context, operation: operation, apply: apply) { self.notice = L10n.format("%1$@完成", String(describing: title)); await self.load() }
        }
        if let message { confirmation = .init(title: title, message: message, destructive: destructive, action: action) }
        else { Task { await action() } }
    }
    func revokeSession(_ session: AuthenticationSession) {
        guard let context = context() else { return }
        let lifecycle = lifecycle
        confirmation = .init(title: L10n.tr("撤销登录"), message: session.current ? L10n.tr("将撤销此 Mac 的登录并退出当前账户。") : L10n.tr("该设备将失去刷新登录的能力，需要重新登录。"), destructive: true, action: { [weak self] in
            guard let self, self.lifecycle == lifecycle, self.isCurrent(context) else { return }
            if await self.run(context, operation: { try await $0.deleteAuthenticationSession(id: session.id) }) {
                if session.current { await self.store.signOut() }
                else { await self.load() }
            }
        })
    }

    func updateUser(_ original: AdminUser, update proposed: UserUpdate, context: ServerAdminContext) {
        guard context.isAdministrator, isCurrent(context), !isWorking else { return }
        let lifecycle = lifecycle
        var consumed = false
        let update = AccountUpdatePolicy.update(proposed, for: original)
        confirmation = .init(title: L10n.tr("更新用户"),
                             message: AccountUpdatePolicy.requiresSignIn(user: original, update: update, actorID: context.userID)
                                ? L10n.tr("修改当前账户的用户名或密码后，需要重新登录。本机下载和待同步记录会保留。")
                                : L10n.format("将更新 %1$@ 的账户资料与访问权限，密码或身份变化可能使其设备退出登录。", original.username)) { [weak self] in
            guard let self, !consumed, self.lifecycle == lifecycle, self.isCurrent(context) else { return }
            consumed = true
            var needsSignIn = false
            var updatedUsername: String?
            let updated = await self.run(context, operation: { [weak self] client in
                let actor = try await client.currentUser()
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.validateUserUpdateActor(actor, context: context, lifecycle: lifecycle)
                let fresh = try await client.adminUser(id: original.id)
                try Task.checkCancellation()
                try await self.validateUserUpdate(fresh, original: original, context: context, lifecycle: lifecycle)
                let payload = AccountUpdatePolicy.update(update, for: fresh)
                let result = try await client.updateUser(id: fresh.id, update: payload)
                return (result, AccountUpdatePolicy.requiresSignIn(user: fresh, update: payload, actorID: context.userID))
            }, apply: { needsSignIn = $0.1; updatedUsername = $0.0.username })
            guard updated, self.isCurrent(context) else { return }
            if needsSignIn {
                await self.store.requireAccountReauthentication(client: context.client, profileID: context.profileID,
                                                               userID: context.userID, epoch: context.accountEpoch,
                                                               message: L10n.tr("账户资料已更新，请重新登录。本机下载和待同步记录已保留。"), username: updatedUsername)
            } else {
                await self.store.refresh()
                guard self.isCurrent(context) else { return }
                self.notice = L10n.tr("用户资料已更新。")
                await self.load()
            }
        }
    }

    private func validateUserUpdate(_ fresh: AdminUser, original: AdminUser, context: ServerAdminContext, lifecycle: UUID) throws {
        guard !Task.isCancelled, self.lifecycle == lifecycle, isCurrent(context),
              AccountUpdatePolicy.isUnchanged(fresh, since: original) else { throw ABSError.sessionChanged }
        guard fresh.type != "root" || store.user?.type == "root" else { throw ABSError.sessionChanged }
    }

    private func validateUserUpdateActor(_ actor: UserAccount, context: ServerAdminContext, lifecycle: UUID) async throws {
        guard !Task.isCancelled, self.lifecycle == lifecycle, isCurrent(context), actor.id == context.userID else { throw ABSError.sessionChanged }
        guard actor.username == context.user.username, AccountUpdatePolicy.hasSameAccess(actor, context.user) else {
            await store.refresh()
            throw ABSError.sessionChanged
        }
    }

    func restoreBackup(_ backup: ServerBackup) {
        guard let context = context(), context.isAdministrator, isCurrent(context), !isWorking else { return }
        let lifecycle = lifecycle
        confirmation = .init(title: L10n.tr("从备份恢复服务器"),
                             message: L10n.format("将使用 %1$@ 覆盖服务器数据。请先创建最新备份。ShelfMac 将暂停播放和同步，保留旧本机进度供导出；恢复后需管理员重启服务器，再重新连接。", backup.filename),
                             destructive: true) { [weak self] in
            guard let self, self.lifecycle == lifecycle, self.isCurrent(context), !self.isWorking else { return }
            self.store.requestServerRestore(backupID: backup.id, context: context)
        }
    }
    func createKey(_ draft: APIKeyDraft, context: ServerAdminContext, source: ServerAPIKeySource) {
        guard context.isAdministrator, isCurrent(context), source.isCurrent(store: store) else { return }
        let lifecycle = lifecycle
        confirmation = .init(title: L10n.tr("创建 API Key"), message: L10n.tr("此密钥将继承所选用户的权限，可在到期前访问服务器。创建后只显示一次。"), action: { [weak self] in
            guard let self, self.lifecycle == lifecycle, source.isCurrent(store: self.store) else { return }
            if await self.run(context, operation: { [weak self] client in
                guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      draft.expiresIn == nil || APIKeyEditingPolicy.lifetime(value: draft.expiresIn!, unit: .seconds) != nil else { throw ServerAPIKeyMutationError.invalidLifetime }
                let users = try await client.adminUsers()
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.validateKeyUsers(users, targetID: draft.userId, context: context, source: source, lifecycle: lifecycle)
                return try await client.createAPIKey(draft)
            }, apply: { if source.isCurrent(store: self.store) { newKeySecret = $0.apiKey ?? "" } }), source.isCurrent(store: self.store) { await self.load() }
        })
    }
    func updateKey(_ original: APIKeyRecord, update: APIKeyUpdate, context: ServerAdminContext, source: ServerAPIKeySource) {
        guard context.isAdministrator, isCurrent(context), source.isCurrent(store: store) else { return }
        let lifecycle = lifecycle
        confirmation = .init(title: L10n.tr("更新密钥身份"), message: L10n.tr("持有此密钥的客户端将立即使用所选身份和启用状态。确认前请核对用户权限。"), destructive: update.isActive == false, action: { [weak self] in
            guard let self, self.lifecycle == lifecycle, source.isCurrent(store: self.store) else { return }
            if await self.run(context, operation: { [weak self] client in
                async let fetchedKeys = client.apiKeys()
                async let fetchedUsers = client.adminUsers()
                let (keys, users) = try await (fetchedKeys, fetchedUsers)
                try Task.checkCancellation()
                guard let current = keys.first(where: { $0.id == original.id }), APIKeyEditingPolicy.unchanged(current, since: original) else { throw ServerAPIKeyMutationError.changedKey }
                guard APIKeyEditingPolicy.mayEnable(current) else { throw ServerAPIKeyMutationError.expiredKey }
                guard let self else { throw CancellationError() }
                try await self.validateKeyUsers(users, targetID: current.userId, context: context, source: source, lifecycle: lifecycle)
                try await self.validateKeyUsers(users, targetID: update.userId ?? current.userId, context: context, source: source, lifecycle: lifecycle)
                return try await client.updateAPIKey(id: current.id, update: update)
            }), source.isCurrent(store: self.store) { await self.load() }
        })
    }
    private func validateKeyUsers(_ users: [AdminUser], targetID: String, context: ServerAdminContext, source: ServerAPIKeySource, lifecycle: UUID) throws {
        guard !Task.isCancelled, self.lifecycle == lifecycle, isCurrent(context), source.isCurrent(store: store) else { throw ABSError.sessionChanged }
        guard let actor = users.first(where: { $0.id == source.actorID }), actor.type == source.actorType, actor.isActive != false else { throw ServerAPIKeyMutationError.changedActor }
        guard let target = users.first(where: { $0.id == targetID }) else { throw ServerAPIKeyMutationError.missingUser }
        guard APIKeyEditingPolicy.mayAssign(userType: target.type, administratorType: actor.type) else { throw ServerAPIKeyMutationError.rootIdentity }
    }
    func stopLogs() { logTask?.cancel(); logTask = nil; logClient?.removeLogListener(); logClient?.disconnect(); logClient = nil }
    func updateLogLevel() { do { try logClient?.setLogListener(level: logLevel) } catch { self.error = L10n.error(error) } }
    private func startLogs(_ context: ServerAdminContext) async {
        stopLogs()
        guard isCurrent(context), context.isAdministrator, let profile = store.profile else { return }
        let socket = ABSRealtimeClient(); logClient = socket
        do {
            let events = try await socket.connect(profile: profile, client: context.client)
            guard isCurrent(context), logClient === socket else { socket.disconnect(); return }
            logTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled, let self, self.isCurrent(context), self.logClient === socket else { return }
                    if event.name == "init" { try? socket.setLogListener(level: self.logLevel) }
                    else if event.name == "log", let data = event.payload, let entry = try? JSONDecoder().decode(ServerLogEntry.self, from: data) {
                        self.logs.append(entry); if self.logs.count > 1000 { self.logs.removeFirst(self.logs.count - 1000) }
                    }
                }
            }
        } catch { if isCurrent(context), logClient === socket { self.error = L10n.error(error) } }
    }
}

private enum ServerAPIKeyMutationError: LocalizedError {
    case invalidLifetime, changedKey, expiredKey, changedActor, missingUser, rootIdentity
    var errorDescription: String? {
        switch self {
        case .invalidLifetime: L10n.tr("请输入可转换为整秒且大于零的有效期。")
        case .changedKey: L10n.tr("密钥已被其他操作更新，请刷新后重新编辑。")
        case .expiredKey: L10n.tr("此密钥已过期，无法重新启用，请创建新密钥。")
        case .changedActor: L10n.tr("账户或权限已变化，请关闭后重新打开。")
        case .missingUser: L10n.tr("所选用户已不存在，请刷新后重新选择。")
        case .rootIdentity: L10n.tr("只有根账户可以管理根身份的密钥。")
        }
    }
}
