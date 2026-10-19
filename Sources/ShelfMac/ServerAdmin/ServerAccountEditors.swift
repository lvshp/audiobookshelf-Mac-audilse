import SwiftUI
import ShelfCore

struct ServerUserEditor: View {
    let user: AdminUser?
    let libraries: [Library]
    let save: (UserDraft, UserUpdate) -> Void
    @State private var username: String
    @State private var password = ""
    @State private var email: String
    @State private var type: String
    @State private var active: Bool
    @State private var permissions: UserPermissionUpdate
    @State private var selectedLibraries: Set<String>
    @State private var tags: String
    @Environment(\.dismiss) private var dismiss
    init(user: AdminUser?, libraries: [Library], save: @escaping (UserDraft, UserUpdate) -> Void) {
        self.user = user; self.libraries = libraries; self.save = save
        _username = State(initialValue: user?.username ?? ""); _email = State(initialValue: user?.email ?? ""); _type = State(initialValue: user?.type ?? "user")
        _active = State(initialValue: user?.isActive ?? true); _permissions = State(initialValue: user?.permissions ?? .restrictedCreationDefaults); _selectedLibraries = State(initialValue: Set(user?.librariesAccessible ?? [])); _tags = State(initialValue: (user?.itemTagsSelected ?? []).joined(separator: "\n"))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(user == nil ? L10n.tr("创建用户") : L10n.format("编辑 %1$@", String(describing: user!.username))).font(.title2.bold()); Spacer(); Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Form {
                Section(L10n.tr("账户")) {
                    FormInputRow(L10n.tr("用户名")) { TextField("", text: $username).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("用户名")) }; FormInputRow(L10n.tr("电子邮件")) { TextField("", text: $email).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("电子邮件")) }
                    if user?.type != "root" { FormInputRow(user == nil ? L10n.tr("密码") : L10n.tr("新密码（留空保持不变）")) { SecureField("", text: $password).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(user == nil ? L10n.tr("密码") : L10n.tr("新密码（留空保持不变）")) } }
                    else { Text(L10n.tr("根账户的密码请在个人设置中修改。")).font(.caption).foregroundStyle(.secondary) }
                    if user?.type == "root" { LabeledContent(L10n.tr("账户类型"), value: "root") }
                    else { ServerSettingPicker(title: L10n.tr("账户类型"), selection: $type, options: ServerSettingOptions.accountTypes); Toggle(L10n.tr("账户有效"), isOn: $active) }
                }
                if user?.type != "root" {
                Section(L10n.tr("操作权限")) {
                    Toggle(L10n.tr("下载原件"), isOn: flag(\.download)); Toggle(L10n.tr("编辑内容信息"), isOn: flag(\.update)); Toggle(L10n.tr("上传文件"), isOn: flag(\.upload)); Toggle(L10n.tr("删除内容"), isOn: flag(\.delete)); Toggle(L10n.tr("创建阅读器设备"), isOn: flag(\.createEreader))
                }
                Section(L10n.tr("书库访问")) {
                    Toggle(L10n.tr("访问所有书库"), isOn: flag(\.accessAllLibraries))
                    if permissions.accessAllLibraries != true { ForEach(libraries) { library in Toggle(library.name, isOn: Binding(get: { selectedLibraries.contains(library.id) }, set: { if $0 { selectedLibraries.insert(library.id) } else { selectedLibraries.remove(library.id) } })) } }
                }
                Section(L10n.tr("标签与内容访问")) {
                    Toggle(L10n.tr("访问全部标签"), isOn: flag(\.accessAllTags)); Toggle(L10n.tr("允许成人内容"), isOn: flag(\.accessExplicitContent))
                    if permissions.accessAllTags != true { Toggle(L10n.tr("所选标签为禁止访问列表"), isOn: flag(\.selectedTagsNotAccessible)); LabeledContent(L10n.tr("标签（每行一个）")) { LeadingTextEditor(text: $tags).frame(height: 72) } }
                }
                }
            }.formStyle(.grouped).textFieldStyle(.shelfLeading)
            HStack { Spacer(); Button(L10n.tr("保存用户")) { submit() }.buttonStyle(.borderedProminent).disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (user == nil && password.isEmpty)) }.padding(18)
        }.frame(width: 640, height: 760).onDisappear { password = "" }
    }
    private func flag(_ key: WritableKeyPath<UserPermissionUpdate, Bool?>) -> Binding<Bool> { Binding(get: { permissions[keyPath: key] ?? false }, set: { permissions[keyPath: key] = $0 }) }
    private func submit() {
        var draft = UserDraft(username: username, password: password, type: AccountType(rawValue: type) ?? .user, isActive: active); draft.email = email; draft.permissions = permissions; draft.librariesAccessible = Array(selectedLibraries).sorted(); draft.itemTagsSelected = adminLines(tags)
        var update = UserUpdate(); update.username = username; update.password = password.isEmpty ? nil : password; update.email = email; update.type = user?.type == "root" ? nil : AccountType(rawValue: type); update.isActive = user?.type == "root" ? nil : active; update.permissions = permissions; update.librariesAccessible = draft.librariesAccessible; update.itemTagsSelected = draft.itemTagsSelected
        if let user { update = AccountUpdatePolicy.update(update, for: user) }
        save(draft, update); password = ""; dismiss()
    }
}

struct ServerNotificationEditor: View {
    let definitions: [NotificationEventDefinition]
    let libraries: [Library]
    let save: (NotificationDraft) -> Void
    @State private var event: String
    @State private var libraryID: String
    @State private var urls: [String]
    @State private var urlIDs: [UUID]
    @State private var title: String
    @State private var bodyText: String
    @State private var kind: String
    @State private var enabled: Bool
    @Environment(\.dismiss) private var dismiss
    init(notification: ServerNotification?, definitions: [NotificationEventDefinition], libraries: [Library], save: @escaping (NotificationDraft) -> Void) {
        self.definitions = definitions; self.libraries = libraries; self.save = save
        _event = State(initialValue: notification?.eventName ?? "onTest"); _libraryID = State(initialValue: notification?.libraryId ?? ""); _urls = State(initialValue: notification?.urls ?? [""])
        _urlIDs = State(initialValue: (notification?.urls ?? [""]).map { _ in UUID() })
        _title = State(initialValue: notification?.titleTemplate ?? ""); _bodyText = State(initialValue: notification?.bodyTemplate ?? ""); _kind = State(initialValue: notification?.type ?? "info"); _enabled = State(initialValue: notification?.enabled ?? true)
    }
    private var definition: NotificationEventDefinition? { definitions.first { $0.name == event } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.tr("事件通知")).font(.title2.bold()); Spacer(); Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            Form {
                Section(L10n.tr("事件")) {
                    ServerSettingPicker(title: L10n.tr("触发事件"), selection: $event, options: definitions.map { .init($0.name, $0.name, localizesTitle: false) }); Text(L10n.notificationDescription(raw: definition?.description ?? "", key: definition?.descriptionKey)).font(.caption).foregroundStyle(.secondary)
                    if definition?.requiresLibrary == true { ServerSettingPicker(title: L10n.tr("书库"), selection: $libraryID, options: [.init("", L10n.tr("选择书库"))] + libraries.filter { definition?.libraryMediaType == nil || $0.mediaType == definition?.libraryMediaType }.map { .init($0.id, $0.name, localizesTitle: false) }) }
                    Toggle(L10n.tr("启用"), isOn: $enabled); ServerSettingPicker(title: L10n.tr("通知类型"), selection: $kind, options: ServerSettingOptions.notificationTypes)
                }
                Section(L10n.tr("接收地址")) {
                    ForEach(urlIDs, id: \.self) { id in VStack(alignment: .leading, spacing: 8) { FormInputRow(L10n.tr("Apprise 通知地址")) { SecureField("", text: urlBinding(id)).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("Apprise 通知地址")) }; Button(L10n.tr("移除"), role: .destructive) { removeURL(id) } } }
                    Button(L10n.tr("添加地址"), systemImage: "plus") { urls.append(""); urlIDs.append(UUID()) }
                }
                Section(L10n.tr("消息模板")) {
                    FormInputRow(L10n.tr("标题")) { TextField("", text: $title).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("标题")) }; LeadingTextEditor(text: $bodyText).frame(height: 100)
                    Text(L10n.tr("可用变量：") + (definition?.variables ?? []).joined(separator: "、")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L10n.tr("使用事件默认模板")) { title = definition?.defaults.title ?? ""; bodyText = definition?.defaults.body ?? "" }
                }
            }.formStyle(.grouped).textFieldStyle(.shelfLeading)
            HStack { Spacer(); Button(L10n.tr("保存通知")) { save(.init(eventName: event, urls: urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, titleTemplate: title, bodyTemplate: bodyText, enabled: enabled, libraryId: (definition?.requiresLibrary == true || definition == nil) && !libraryID.isEmpty ? libraryID : nil, type: kind)); dismiss() }.buttonStyle(.borderedProminent).disabled(urls.allSatisfy { $0.isEmpty } || (definition?.requiresLibrary == true && libraryID.isEmpty)) }.padding(18)
        }.frame(width: 650, height: 710).onDisappear { urls = []; urlIDs = [] }
    }
    private func urlIndex(_ id: UUID) -> Int? { guard let index = urlIDs.firstIndex(of: id), urls.indices.contains(index) else { return nil }; return index }
    private func urlBinding(_ id: UUID) -> Binding<String> { Binding(get: { guard let index = urlIndex(id) else { return "" }; return urls[index] }, set: { guard let index = urlIndex(id) else { return }; urls[index] = $0 }) }
    private func removeURL(_ id: UUID) { guard let index = urlIndex(id) else { return }; urls.remove(at: index); urlIDs.remove(at: index) }
}
