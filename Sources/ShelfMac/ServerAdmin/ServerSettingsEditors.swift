import SwiftUI
import ShelfCore

struct ServerSettingsEditor: View {
    @State private var draft: ServerSettingsUpdate
    @State private var origins: String
    @State private var prefixes: String
    @State private var backupCron: String
    @State private var backupInterval: String
    @State private var backupHour: Int
    @State private var backupMinute: Int
    @State private var automaticBackup: Bool
    @State private var backupSize: String
    private let initialPrefixes: [String]
    let coverProviders: [MetadataProvider]
    let save: (ServerSettingsUpdate) -> Void
    init(settings: ServerSettingsUpdate, coverProviders: [MetadataProvider], save: @escaping (ServerSettingsUpdate) -> Void) {
        _draft = State(initialValue: settings); _origins = State(initialValue: (settings.allowedOrigins ?? []).joined(separator: "\n")); _prefixes = State(initialValue: (settings.sortingPrefixes ?? []).joined(separator: "\n"))
        _backupSize = State(initialValue: String(settings.maxBackupSize ?? 1))
        initialPrefixes = settings.sortingPrefixes ?? []
        let cron: String
        if case .cron(let value) = settings.backupSchedule { cron = value; _automaticBackup = State(initialValue: true) }
        else { cron = "0 0 * * *"; _automaticBackup = State(initialValue: false) }
        _backupCron = State(initialValue: cron); _backupInterval = State(initialValue: ServerSettingOptions.backupInterval(for: cron))
        let dailyTime = ServerSettingOptions.dailyTime(cron)
        _backupHour = State(initialValue: dailyTime?.hour ?? 0); _backupMinute = State(initialValue: dailyTime?.minute ?? 0)
        self.coverProviders = coverProviders; self.save = save
    }
    var body: some View {
        Form {
            Section(L10n.tr("扫描与文件")) {
                Toggle(L10n.tr("解析副标题"), isOn: flag(\.scannerParseSubtitle)); Toggle(L10n.tr("自动寻找封面"), isOn: flag(\.scannerFindCovers))
                ServerSettingPicker(title: L10n.tr("封面来源"), selection: text(\.scannerCoverProvider), options: coverProviders.map { .init($0.value, $0.text, localizesTitle: false) })
                Toggle(L10n.tr("优先使用匹配元数据"), isOn: flag(\.scannerPreferMatchedMetadata)); Toggle(L10n.tr("停用文件监控"), isOn: flag(\.scannerDisableWatcher))
                Toggle(L10n.tr("封面保存在内容目录"), isOn: flag(\.storeCoverWithItem)); Toggle(L10n.tr("元数据保存在内容目录"), isOn: flag(\.storeMetadataWithItem))
            }
            Section(L10n.tr("访问与显示")) {
                Toggle(L10n.tr("允许网页嵌入 iframe"), isOn: flag(\.allowIframe))
                LabeledContent(L10n.tr("允许的来源（每行一个）")) { LeadingTextEditor(text: $origins).frame(height: 72) }
                ServerSettingPicker(title: L10n.tr("服务器 Web 界面语言"), selection: text(\.language), options: ServerSettingOptions.languages)
                Text(L10n.tr("此设置仅影响服务器 Web 界面；ShelfMac 客户端语言在应用设置中切换。")).font(.caption).foregroundStyle(.secondary)
                ServerSettingPicker(title: L10n.tr("日期格式"), selection: text(\.dateFormat), options: ServerSettingOptions.dateFormats)
                ServerSettingPicker(title: L10n.tr("时间格式"), selection: text(\.timeFormat), options: ServerSettingOptions.timeFormats)
                ServerSettingPicker(title: L10n.tr("首页书架样式"), selection: integerOption(\.homeBookshelfView, fallback: 1), options: ServerSettingOptions.bookshelfViews)
                ServerSettingPicker(title: L10n.tr("书库书架样式"), selection: integerOption(\.bookshelfView, fallback: 1), options: ServerSettingOptions.bookshelfViews)
                Toggle(L10n.tr("排序时忽略冠词前缀"), isOn: flag(\.sortingIgnorePrefix)); LabeledContent(L10n.tr("排序前缀（每行一个）")) { LeadingTextEditor(text: $prefixes).frame(height: 64) }
                if isClearingPrefixes {
                    Text(L10n.tr("排序前缀至少保留一项；服务器不支持清空列表。"))
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L10n.tr("备份与日志")) {
                Toggle(L10n.tr("自动备份"), isOn: $automaticBackup)
                if automaticBackup { backupSchedule }
                Stepper(L10n.format("保留备份：%1$@", String(describing: draft.backupsToKeep ?? 2)), value: integer(\.backupsToKeep, fallback: 2), in: 1...99)
                FormInputRow(L10n.tr("最大备份大小（GB）")) { TextField("", text: $backupSize).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("最大备份大小（GB）")) }
                if !validBackup {
                    Text(L10n.tr("备份大小须为非负有限数值（0 表示不限），保留数量须为 1–99。"))
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                ServerSettingPicker(title: L10n.tr("日志级别"), selection: integerOption(\.logLevel, fallback: 2), options: ServerSettingOptions.logLevels)
            }
            Button(L10n.tr("保存服务器设置")) {
                let changedPrefixes = Self.sortingPrefixesUpdate(text: prefixes, initial: initialPrefixes)
                guard changedPrefixes?.isEmpty != true, validBackup, let maximumSize = parsedBackupSize else { return }
                var update = draft
                update.maxBackupSize = maximumSize
                update.allowedOrigins = adminLines(origins)
                update.sortingPrefixes = changedPrefixes
                update.backupSchedule = automaticBackup ? .cron(backupCron) : .disabled
                save(update)
            }.buttonStyle(.borderedProminent).disabled(!validBackup || isClearingPrefixes || (automaticBackup && backupCron.isEmpty))
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    private var parsedBackupSize: Double? { Double(backupSize.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var validBackup: Bool { parsedBackupSize.map { ServerSettingsValidation.validBackup(maximumSizeGB: $0, retainedCount: draft.backupsToKeep ?? 2) } ?? false }
    private var isClearingPrefixes: Bool { Self.sortingPrefixesUpdate(text: prefixes, initial: initialPrefixes)?.isEmpty == true }
    static func sortingPrefixesUpdate(text: String, initial: [String]) -> [String]? {
        func normalized(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.compactMap { value in
                let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !prefix.isEmpty && seen.insert(prefix).inserted ? prefix : nil
            }
        }
        let edited = normalized(text.components(separatedBy: .newlines))
        return Set(edited) == Set(normalized(initial)) ? nil : edited
    }
    private var backupSchedule: some View {
        Group {
            ServerSettingPicker(title: L10n.tr("备份频次"), selection: Binding(get: { backupInterval }, set: { value in
                backupInterval = value
                if value == "daily" { updateDailyBackup() }
                else if value != "custom" { backupCron = value }
            }), options: ServerSettingOptions.backupIntervals)
            if backupInterval == "daily" {
                Picker(L10n.tr("小时"), selection: Binding(get: { backupHour }, set: { backupHour = $0; updateDailyBackup() })) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.pickerStyle(.menu)
                Picker(L10n.tr("分钟"), selection: Binding(get: { backupMinute }, set: { backupMinute = $0; updateDailyBackup() })) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.pickerStyle(.menu)
            } else if backupInterval == "custom" { FormInputRow(L10n.tr("Cron 表达式")) { TextField("", text: $backupCron).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("Cron 表达式")) } }
            Text(L10n.format("服务器时区 · %1$@", String(describing: backupCron))).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
    private func updateDailyBackup() { backupCron = "\(backupMinute) \(backupHour) * * *" }
    private func text(_ key: WritableKeyPath<ServerSettingsUpdate, String?>) -> Binding<String> { Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 }) }
    private func integerOption(_ key: WritableKeyPath<ServerSettingsUpdate, Int?>, fallback: Int) -> Binding<String> { Binding(get: { String(draft[keyPath: key] ?? fallback) }, set: { if let value = Int($0) { draft[keyPath: key] = value } }) }
    private func flag(_ key: WritableKeyPath<ServerSettingsUpdate, Bool?>) -> Binding<Bool> { Binding(get: { draft[keyPath: key] ?? false }, set: { draft[keyPath: key] = $0 }) }
    private func integer(_ key: WritableKeyPath<ServerSettingsUpdate, Int?>, fallback: Int) -> Binding<Int> { Binding(get: { draft[keyPath: key] ?? fallback }, set: { draft[keyPath: key] = $0 }) }
}

struct ServerAuthenticationEditor: View {
    @State private var draft: AuthenticationSettings
    @State private var local: Bool
    @State private var openID: Bool
    @State private var redirects: String
    @State private var signingAlgorithms = ["RS256"]
    @State private var customSigningAlgorithm: Bool
    @State private var isDiscovering = false
    @State private var discoveryError: String?
    @State private var discoveryRequest = UUID()
    @State private var discoveryTask: Task<Void, Never>?
    let basePath: String
    let loadConfiguration: @MainActor (String) async throws -> ServerOIDCConfiguration
    let save: (AuthenticationSettings) -> Void
    init(settings: AuthenticationSettings, basePath: String, loadConfiguration: @escaping @MainActor (String) async throws -> ServerOIDCConfiguration, save: @escaping (AuthenticationSettings) -> Void) {
        _draft = State(initialValue: settings); _local = State(initialValue: settings.authActiveAuthMethods?.contains("local") ?? true); _openID = State(initialValue: settings.authActiveAuthMethods?.contains("openid") ?? false)
        _redirects = State(initialValue: (settings.authOpenIDMobileRedirectURIs ?? []).joined(separator: "\n")); self.save = save
        _customSigningAlgorithm = State(initialValue: settings.authOpenIDTokenSigningAlgorithm.map { $0 != "RS256" } ?? false)
        self.basePath = basePath == "/" ? "" : (basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath); self.loadConfiguration = loadConfiguration
    }
    var body: some View {
        Form {
            Section(L10n.tr("登录方式")) { Toggle(L10n.tr("用户名和密码"), isOn: $local); Toggle("OpenID Connect", isOn: $openID); FormInputRow(L10n.tr("登录提示")) { TextField("", text: text(\.authLoginCustomMessage)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("登录提示")) }; FormInputRow(L10n.tr("OIDC 按钮文字")) { TextField("", text: text(\.authOpenIDButtonText)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("OIDC 按钮文字")) }; Toggle(L10n.tr("自动进入 OIDC"), isOn: flag(\.authOpenIDAutoLaunch)) }
            discoverySection
            Section(L10n.tr("客户端凭据")) {
                FormInputRow(L10n.tr("客户端 ID")) { TextField("", text: text(\.authOpenIDClientID)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("客户端 ID")) }; FormInputRow(L10n.tr("客户端密钥")) { SecureField("", text: text(\.authOpenIDClientSecret)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("客户端密钥")) }
                ServerSettingPicker(title: L10n.tr("签名算法"), selection: Binding(get: { customSigningAlgorithm ? "custom" : (draft.authOpenIDTokenSigningAlgorithm ?? "RS256") }, set: { value in
                    customSigningAlgorithm = value == "custom"
                    if !customSigningAlgorithm { draft.authOpenIDTokenSigningAlgorithm = value }
                }), options: signingAlgorithms.map { .init($0, $0, localizesTitle: false) } + [.init("custom", L10n.tr("自定义算法"))])
                if customSigningAlgorithm { FormInputRow(L10n.tr("自定义签名算法")) { TextField("", text: text(\.authOpenIDTokenSigningAlgorithm)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("自定义签名算法")) } }
                Text(L10n.tr("读取身份提供商配置后，下拉菜单显示其支持的签名算法。当前配置会保留。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("用户关联与权限")) {
                Toggle(L10n.tr("自动注册新用户"), isOn: flag(\.authOpenIDAutoRegister))
                ServerSettingPicker(title: L10n.tr("关联已有用户"), selection: text(\.authOpenIDMatchExistingBy), options: ServerSettingOptions.existingUserMatches)
                FormInputRow(L10n.tr("群组 Claim")) { TextField("", text: text(\.authOpenIDGroupClaim)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("群组 Claim")) }; FormInputRow(L10n.tr("高级权限 Claim")) { TextField("", text: text(\.authOpenIDAdvancedPermsClaim)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("高级权限 Claim")) }
                ServerSettingPicker(title: L10n.tr("反向代理子路径"), selection: text(\.authOpenIDSubfolderForRedirectURLs), options: [.init("", L10n.tr("无"))] + (basePath.isEmpty || basePath == "/" ? [] : [.init(basePath, basePath, localizesTitle: false)]))
                LabeledContent(L10n.tr("应用回调地址（每行一个）")) { LeadingTextEditor(text: $redirects).frame(height: 72) }
            }
            Button(L10n.tr("保存认证设置")) {
                var update = draft
                let unknownMethods = (draft.authActiveAuthMethods ?? []).filter { $0 != "local" && $0 != "openid" }
                update.authActiveAuthMethods = unknownMethods + (local ? ["local"] : []) + (openID ? ["openid"] : [])
                update.authOpenIDMobileRedirectURIs = adminLines(redirects); save(update)
            }.buttonStyle(.borderedProminent).disabled((!local && !openID) || isDiscovering)
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
            .onDisappear { discoveryRequest = UUID(); discoveryTask?.cancel(); discoveryTask = nil }
    }
    private var discoverySection: some View {
        Section(L10n.tr("身份提供商")) {
            FormInputRow(L10n.tr("签发方地址")) { TextField("", text: text(\.authOpenIDIssuerURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("签发方地址")) }
            HStack { Button(L10n.tr("读取身份提供商配置"), action: discover).disabled(isDiscovering || (draft.authOpenIDIssuerURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if isDiscovering { ProgressView().controlSize(.small) } }
            if let discoveryError { Text(discoveryError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            FormInputRow(L10n.tr("授权端点")) { TextField("", text: text(\.authOpenIDAuthorizationURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("授权端点")) }; FormInputRow(L10n.tr("令牌端点")) { TextField("", text: text(\.authOpenIDTokenURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("令牌端点")) }; FormInputRow(L10n.tr("用户信息端点")) { TextField("", text: text(\.authOpenIDUserInfoURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("用户信息端点")) }; FormInputRow(L10n.tr("公钥集地址")) { TextField("", text: text(\.authOpenIDJwksURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("公钥集地址")) }; FormInputRow(L10n.tr("退出端点")) { TextField("", text: text(\.authOpenIDLogoutURL)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("退出端点")) }
        }
    }
    private func discover() {
        let originalIssuer = draft.authOpenIDIssuerURL ?? ""
        var issuer = originalIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
        if issuer.hasSuffix("/") { issuer.removeLast() }
        if issuer.hasSuffix("/.well-known/openid-configuration") { issuer.removeLast("/.well-known/openid-configuration".count) }
        guard !issuer.isEmpty else { return }
        let requestedIssuer = issuer
        discoveryTask?.cancel(); let request = UUID(); discoveryRequest = request; isDiscovering = true; discoveryError = nil
        discoveryTask = Task { @MainActor in
            defer { if discoveryRequest == request { isDiscovering = false; discoveryTask = nil } }
            do {
                let config = try await loadConfiguration(requestedIssuer)
                guard !Task.isCancelled, discoveryRequest == request, draft.authOpenIDIssuerURL == originalIssuer else { return }
                if let value = config.issuer, !value.isEmpty { draft.authOpenIDIssuerURL = value }
                if let value = config.authorization_endpoint { draft.authOpenIDAuthorizationURL = value }
                if let value = config.token_endpoint { draft.authOpenIDTokenURL = value }
                if let value = config.userinfo_endpoint { draft.authOpenIDUserInfoURL = value }
                if let value = config.jwks_uri { draft.authOpenIDJwksURL = value }
                if let value = config.end_session_endpoint { draft.authOpenIDLogoutURL = value }
                let algorithms = Array(Set((config.id_token_signing_alg_values_supported ?? []).filter { !$0.isEmpty })).sorted()
                if !algorithms.isEmpty {
                    signingAlgorithms = algorithms
                    customSigningAlgorithm = !algorithms.contains(draft.authOpenIDTokenSigningAlgorithm ?? "RS256")
                }
            } catch {
                guard !Task.isCancelled, discoveryRequest == request, draft.authOpenIDIssuerURL == originalIssuer, !(error is CancellationError) else { return }
                discoveryError = L10n.error(error)
            }
        }
    }
    private func text(_ key: WritableKeyPath<AuthenticationSettings, String?>) -> Binding<String> { Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 }) }
    private func flag(_ key: WritableKeyPath<AuthenticationSettings, Bool?>) -> Binding<Bool> { Binding(get: { draft[keyPath: key] ?? false }, set: { draft[keyPath: key] = $0 }) }
}

struct ServerSMTPEditor: View {
    @State private var draft: SMTPSettings
    @State private var deviceIDs: [UUID]
    private let initialSnapshot: SMTPSettings
    let users: [AdminUser]
    let save: (SMTPSettings) -> Void
    let test: () -> Void
    init(settings: SMTPSettings, users: [AdminUser], save: @escaping (SMTPSettings) -> Void, test: @escaping () -> Void) { _draft = State(initialValue: settings); _deviceIDs = State(initialValue: (settings.ereaderDevices ?? []).map { _ in UUID() }); initialSnapshot = settings; self.users = users; self.save = save; self.test = test }
    private var hasUnsavedChanges: Bool { draft != initialSnapshot }
    private var canSendTest: Bool { Self.permitsTest(draft: draft, saved: initialSnapshot) }
    var body: some View {
        Form {
            Section(L10n.tr("SMTP 服务")) {
                FormInputRow(L10n.tr("服务器")) { TextField("", text: text(\.host)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("服务器")) }; FormInputRow(L10n.tr("端口")) { TextField("", value: Binding(get: { draft.port ?? 465 }, set: { draft.port = $0 }), format: .number).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("端口")) }
                Toggle(L10n.tr("使用 TLS（465）"), isOn: flag(\.secure, fallback: true)); Toggle(L10n.tr("验证服务器证书"), isOn: flag(\.rejectUnauthorized, fallback: true))
                FormInputRow(L10n.tr("用户名")) { TextField("", text: text(\.user)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("用户名")) }; FormInputRow(L10n.tr("密码")) { SecureField("", text: text(\.pass)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("密码")) }; FormInputRow(L10n.tr("发件人地址")) { TextField("", text: text(\.fromAddress)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("发件人地址")) }; FormInputRow(L10n.tr("测试收件人")) { TextField("", text: text(\.testAddress)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("测试收件人")) }
            }
            Section(L10n.tr("阅读器设备")) {
                ForEach(deviceIDs, id: \.self) { deviceID in
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) { FormInputRow(L10n.tr("设备名称")) { TextField("", text: deviceText(deviceID, \.name)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("设备名称")) }; FormInputRow(L10n.tr("接收电子邮件")) { TextField("", text: deviceText(deviceID, \.email)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("接收电子邮件")) }; Button(L10n.tr("移除"), role: .destructive) { removeDevice(deviceID) } }
                        ServerSettingPicker(title: L10n.tr("允许发送的用户"), selection: deviceText(deviceID, \.availabilityOption), options: ServerSettingOptions.deviceAvailability)
                        if deviceText(deviceID, \.availabilityOption).wrappedValue == "specificUsers" {
                            ForEach(users) { user in Toggle(user.username, isOn: deviceUser(deviceID, userID: user.id)) }
                        }
                    }.padding(.vertical, 4)
                }
                Button(L10n.tr("添加设备"), systemImage: "plus") { var device = EReaderDevice(name: "", email: "", userID: ""); device.availabilityOption = "adminOrUp"; device.users = []; draft.ereaderDevices = (draft.ereaderDevices ?? []) + [device]; deviceIDs.append(UUID()) }
            }
            HStack {
                Button(L10n.tr("保存邮件设置")) { save(draft) }.buttonStyle(.borderedProminent).disabled((draft.ereaderDevices ?? []).contains { $0.name.isEmpty || $0.email.isEmpty || ($0.availabilityOption == "specificUsers" && $0.users.isEmpty) })
                Button(L10n.tr("发送测试邮件")) { guard canSendTest else { return }; test() }.disabled(!canSendTest)
            }
            if hasUnsavedChanges {
                Text(L10n.tr("有未保存的更改。请先保存邮件设置，再发送测试邮件。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !canSendTest {
                Text(L10n.tr("填写并保存 SMTP 服务器和测试收件人后，可发送测试邮件。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).textFieldStyle(.shelfLeading)
    }
    static func permitsTest(draft: SMTPSettings, saved: SMTPSettings) -> Bool {
        draft == saved && !(draft.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(draft.testAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func text(_ key: WritableKeyPath<SMTPSettings, String?>) -> Binding<String> { Binding(get: { draft[keyPath: key] ?? "" }, set: { draft[keyPath: key] = $0 }) }
    private func flag(_ key: WritableKeyPath<SMTPSettings, Bool?>, fallback: Bool) -> Binding<Bool> { Binding(get: { draft[keyPath: key] ?? fallback }, set: { draft[keyPath: key] = $0 }) }
    private func deviceIndex(_ id: UUID) -> Int? { guard let index = deviceIDs.firstIndex(of: id), draft.ereaderDevices?.indices.contains(index) == true else { return nil }; return index }
    private func removeDevice(_ id: UUID) { guard let index = deviceIndex(id) else { return }; draft.ereaderDevices?.remove(at: index); deviceIDs.remove(at: index) }
    private func deviceText(_ id: UUID, _ key: WritableKeyPath<EReaderDevice, String>) -> Binding<String> { Binding(get: { guard let index = deviceIndex(id) else { return "" }; return draft.ereaderDevices![index][keyPath: key] }, set: { guard let index = deviceIndex(id) else { return }; draft.ereaderDevices![index][keyPath: key] = $0 }) }
    private func deviceUser(_ id: UUID, userID: String) -> Binding<Bool> {
        Binding(get: { guard let index = deviceIndex(id) else { return false }; return draft.ereaderDevices![index].users.contains(userID) }, set: { selected in
            guard let index = deviceIndex(id) else { return }
            if selected { if !draft.ereaderDevices![index].users.contains(userID) { draft.ereaderDevices![index].users.append(userID) } }
            else { draft.ereaderDevices![index].users.removeAll { $0 == userID } }
        })
    }
}

struct ServerNotificationSettingsEditor: View {
    @State private var address: String
    @State private var attempts: String
    @State private var queue: String
    let save: (NotificationSettingsUpdate) -> Void
    init(settings: NotificationSettings, save: @escaping (NotificationSettingsUpdate) -> Void) { _address = State(initialValue: settings.appriseApiUrl ?? ""); _attempts = State(initialValue: String(settings.maxFailedAttempts ?? 5)); _queue = State(initialValue: String(settings.maxNotificationQueue ?? 20)); self.save = save }
    var body: some View {
        GroupBox(L10n.tr("Apprise 服务")) {
            VStack(alignment: .leading, spacing: 10) {
                FormInputRow(L10n.tr("服务地址")) {
                    SecureField("", text: $address)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(L10n.tr("服务地址"))
                }
                FormInputRow(L10n.tr("最多失败次数")) {
                    TextField("", text: $attempts)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(L10n.tr("最多失败次数"))
                }
                FormInputRow(L10n.tr("通知队列上限")) {
                    TextField("", text: $queue)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel(L10n.tr("通知队列上限"))
                }
                if !validNumbers { Text(L10n.tr("请输入大于零的整数。")).font(.caption).foregroundStyle(.red) }
                Button(L10n.tr("保存")) {
                    guard let attempts = ServerSettingsValidation.positiveInteger(attempts), let queue = ServerSettingsValidation.positiveInteger(queue) else { return }
                    save(.init(appriseApiUrl: address, maxFailedAttempts: attempts, maxNotificationQueue: queue))
                }.disabled(!validNumbers)
            }.textFieldStyle(.shelfLeading)
        }
    }
    private var validNumbers: Bool { ServerSettingsValidation.positiveInteger(attempts) != nil && ServerSettingsValidation.positiveInteger(queue) != nil }
}
func adminLines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
