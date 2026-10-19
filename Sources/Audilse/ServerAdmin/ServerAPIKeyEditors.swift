import SwiftUI
import AudilseCore

struct ServerAPIKeySource: Hashable, Sendable {
    let partition: AccountPartition
    let profileID: UUID
    let client: ABSClient
    let actorID: String
    let actorType: String
    let version: String?
    var isRoot: Bool { actorType == "root" }
    @MainActor init?(store: AppStore) {
        guard !store.isConnecting, !store.isOffline, !store.isDemo,
              let user = store.user, AdminPolicy.allows(.manageServer, user: user),
              let partition = store.partition, let profile = store.profile, let client = store.client,
              partition.serverID == profile.id, partition.userID == user.id,
              AdminCapabilities(version: profile.serverVersion).hasAPIKeys else { return nil }
        self.partition = partition; profileID = profile.id; self.client = client
        actorID = user.id; actorType = user.type; version = profile.serverVersion
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.partition == rhs.partition && lhs.profileID == rhs.profileID && lhs.client === rhs.client &&
        lhs.actorID == rhs.actorID && lhs.actorType == rhs.actorType && lhs.version == rhs.version
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(partition); hasher.combine(profileID); hasher.combine(ObjectIdentifier(client))
        hasher.combine(actorID); hasher.combine(actorType); hasher.combine(version)
    }
    @MainActor func isCurrent(store: AppStore) -> Bool { Self(store: store) == self }
}

struct ServerAPIKeyEditor: View {
    let users: [AdminUser]
    let save: (APIKeyDraft) -> Void
    private let store: AppStore?
    private let source: ServerAPIKeySource?
    @State private var name = ""
    @State private var userID: String
    @State private var lifetimeValue = "30"
    @State private var unit = APIKeyLifetimeUnit.days
    @State private var expires = true
    @State private var active = true
    @Environment(\.dismiss) private var dismiss

    init(users: [AdminUser], save: @escaping (APIKeyDraft) -> Void) {
        self.users = users; self.save = save; store = nil; source = nil
        _userID = State(initialValue: users.first(where: { $0.type != "root" })?.id ?? "")
    }
    init(store: AppStore, source: ServerAPIKeySource, users: [AdminUser], save: @escaping (APIKeyDraft) -> Void) {
        self.store = store; self.source = source; self.users = users; self.save = save
        _userID = State(initialValue: users.first(where: { APIKeyEditingPolicy.mayAssign(userType: $0.type, administratorType: source.actorType) })?.id ?? "")
    }
    private var eligibleUsers: [AdminUser] { users.filter { APIKeyEditingPolicy.mayAssign(userType: $0.type, administratorType: source?.actorType ?? "admin") } }
    private var available: Bool { store.map { source?.isCurrent(store: $0) == true } ?? true }
    private var lifetime: Double? { Double(lifetimeValue.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { APIKeyEditingPolicy.lifetime(value: $0, unit: unit) } }
    private var valid: Bool { available && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && eligibleUsers.contains { $0.id == userID } && (!expires || lifetime != nil) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.tr("创建 API Key")).font(.title2.bold()); Spacer(); SheetCloseButton { dismiss() } }
            Form {
                FormInputRow(L10n.tr("名称")) { TextField("", text: $name).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("名称")) }
                Picker(L10n.tr("身份"), selection: $userID) { ForEach(eligibleUsers) { Text("\($0.username)（\($0.type)）").tag($0.id) } }.pickerStyle(.menu)
                Toggle(L10n.tr("设置有效期"), isOn: $expires)
                if expires {
                    VStack(alignment: .leading, spacing: 8) {
                        FormInputRow(L10n.tr("有效期数值")) { TextField("", text: $lifetimeValue).accessibilityIdentifier("api-key.lifetime").labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("有效期数值")) }
                        Picker(L10n.tr("有效期单位"), selection: $unit) { ForEach(APIKeyLifetimeUnit.allCases, id: \.self) { Text(unitLabel($0)).tag($0) } }.pickerStyle(.menu).frame(width: 110)
                    }
                    if lifetime == nil { Text(L10n.tr("有效期须能换算为至少一整秒。")).font(.caption).foregroundStyle(.red) }
                }
                Toggle(L10n.tr("立即启用"), isOn: $active)
            }.textFieldStyle(.shelfLeading)
            Text(L10n.tr("密钥继承所选用户的权限；名称和有效期创建后不能修改。")).font(.caption).foregroundStyle(.secondary)
            if !available { Text(L10n.tr("账户或权限已变化，请关闭后重新打开。")).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("创建")) {
                guard valid else { return }
                save(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines), userId: userID, expiresIn: expires ? lifetime : nil, isActive: active)); dismiss()
            }.buttonStyle(.borderedProminent).disabled(!valid) }
        }.padding(24).frame(width: 540)
    }
    private func unitLabel(_ value: APIKeyLifetimeUnit) -> String {
        switch value { case .seconds: L10n.tr("秒"); case .minutes: L10n.tr("分钟"); case .hours: L10n.tr("小时"); case .days: L10n.tr("天") }
    }
}

struct ServerAPIKeyIdentityEditor: View {
    let store: AppStore
    let source: ServerAPIKeySource
    let key: APIKeyRecord
    let users: [AdminUser]
    let save: (APIKeyUpdate) -> Void
    @State private var userID: String
    @State private var active: Bool
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, source: ServerAPIKeySource, key: APIKeyRecord, users: [AdminUser], save: @escaping (APIKeyUpdate) -> Void) {
        self.store = store; self.source = source; self.key = key; self.users = users; self.save = save
        _userID = State(initialValue: key.userId); _active = State(initialValue: key.isActive)
    }
    private var eligibleUsers: [AdminUser] { users.filter { APIKeyEditingPolicy.mayAssign(userType: $0.type, administratorType: source.actorType) } }
    private var originalType: String? { key.user?.type ?? users.first(where: { $0.id == key.userId })?.type }
    private var available: Bool {
        source.isCurrent(store: store) && originalType.map { APIKeyEditingPolicy.mayAssign(userType: $0, administratorType: source.actorType) } == true && APIKeyEditingPolicy.mayEnable(key)
    }
    private var valid: Bool { available && eligibleUsers.contains { $0.id == userID } && (userID != key.userId || active != key.isActive) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.tr("编辑 API Key 身份")).font(.title2.bold()); Spacer(); SheetCloseButton { dismiss() } }
            Form {
                LabeledContent(L10n.tr("名称"), value: key.name)
                LabeledContent(L10n.tr("到期时间"), value: key.expiresAt ?? L10n.tr("永不过期"))
                Picker(L10n.tr("身份"), selection: $userID) { ForEach(eligibleUsers) { Text("\($0.username)（\($0.type)）").tag($0.id) } }.pickerStyle(.menu).disabled(!available)
                Toggle(L10n.tr("有效"), isOn: $active).disabled(!available)
            }
            Text(L10n.tr("仅更新身份和启停状态；名称和现有到期时间保持不变。")).font(.caption).foregroundStyle(.secondary)
            if !APIKeyEditingPolicy.mayEnable(key) { Text(L10n.tr("已过期的停用密钥不能重新启用或改派身份。")).font(.caption).foregroundStyle(.red) }
            else if !available { Text(L10n.tr("账户或权限已变化，请关闭后重新打开。")).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("保存")) {
                guard valid else { return }
                save(.init(userId: userID == key.userId ? nil : userID, isActive: active == key.isActive ? nil : active)); dismiss()
            }.buttonStyle(.borderedProminent).disabled(!valid) }
        }.padding(24).frame(width: 560)
    }
}
