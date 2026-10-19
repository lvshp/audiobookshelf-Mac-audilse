import SwiftUI
import AudilseCore

struct PersonalSettingsView: View {
    let store: AppStore
    @State private var model: PersonalSettingsModel
    @State private var deviceEditor: PersonalDeviceEditorTarget?
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var emptyRootPassword = false
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore) { self.store = store; _model = State(initialValue: .init(store: store)) }
    var body: some View {
        VStack(spacing: 0) {
            PersonalHeader(title: L10n.tr("个人设置"), subtitle: store.user?.username ?? L10n.tr("未登录"), busy: model.scope.isWorking) { dismiss() }
            PersonalStatus(scope: model.scope)
            Form {
                Section(L10n.tr("客户端界面")) {
                    AppLanguagePicker()
                    Text(L10n.tr("立即切换客户端界面语言，不修改服务器的 Web 界面设置。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.tr("播放偏好 · 此 Mac")) {
                    Picker(L10n.tr("默认播放速度"), selection: $model.preferences.playbackRate) {
                        ForEach(ClientSettingsChoices.preserving(model.preferences.playbackRate, in: ClientSettingsChoices.playbackRates), id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("settings.playback-rate")
                    Picker(L10n.tr("前进秒数"), selection: $model.preferences.jumpForwardAmount) {
                        ForEach(ClientSettingsChoices.preserving(model.preferences.jumpForwardAmount, in: ClientSettingsChoices.jumpSeconds), id: \.self) { Text(L10n.format("%1$@ 秒", String(describing: $0))).tag($0) }
                    }.pickerStyle(.menu)
                    Picker(L10n.tr("后退秒数"), selection: $model.preferences.jumpBackwardAmount) {
                        ForEach(ClientSettingsChoices.preserving(model.preferences.jumpBackwardAmount, in: ClientSettingsChoices.jumpSeconds), id: \.self) { Text(L10n.format("%1$@ 秒", String(describing: $0))).tag($0) }
                    }.pickerStyle(.menu)
                    Picker(L10n.tr("速度调整步长"), selection: $model.preferences.playbackRateIncrementDecrement) {
                        ForEach(ClientSettingsChoices.preserving(model.preferences.playbackRateIncrementDecrement, in: ClientSettingsChoices.rateSteps), id: \.self) { Text("\($0.formatted())×").tag($0) }
                    }.pickerStyle(.menu)
                    Toggle(L10n.tr("使用当前章节的播放进度"), isOn: $model.preferences.useChapterTrack)
                    Text(L10n.tr("这些偏好按服务器和账户分别保存在本机。速度设置会同时应用到当前播放。")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("保存播放偏好")) { model.savePreferences() }.disabled(!model.scope.canUseBoundAccount || store.isConnecting)
                }
                Section(L10n.tr("个人阅读器")) {
                    if model.personalDevices.isEmpty { Text(L10n.tr("尚未创建个人阅读器。添加设备的收件邮箱后，可从书籍详情发送电子书。")).foregroundStyle(.secondary) }
                    ForEach(model.personalDevices) { device in
                        HStack { VStack(alignment: .leading) { Text(device.name); Text(device.email).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(L10n.tr("编辑")) { editDevice(device) }; Button(L10n.tr("删除"), role: .destructive) { model.deleteDevice(device) } }
                    }
                    Button(L10n.tr("添加个人阅读器"), systemImage: "plus") { editDevice(nil) }
                }.disabled(model.scope.isWorking || !model.scope.canUseServer || model.scope.capabilities?.canManageReaderDevices != true)
                if !model.sharedDevices.isEmpty {
                    Section(L10n.tr("服务器共享给你的阅读器")) {
                        ForEach(model.sharedDevices) { device in LabeledContent(device.name, value: device.email) }
                        Text(L10n.tr("共享设备由服务器管理员管理。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.tr("修改密码")) {
                    FormInputRow(L10n.tr("当前密码")) { SecureField("", text: $currentPassword).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("当前密码")) }
                    if store.user?.type == "root" { Toggle(L10n.tr("将密码设为空（仅 root）"), isOn: $emptyRootPassword) }
                    if !emptyRootPassword { FormInputRow(L10n.tr("新密码")) { SecureField("", text: $newPassword).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("新密码")) }; FormInputRow(L10n.tr("再次输入新密码")) { SecureField("", text: $repeatedPassword).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("再次输入新密码")) } }
                    Button(L10n.tr("修改密码…")) {
                        model.changePassword(current: currentPassword, new: emptyRootPassword ? "" : newPassword)
                        clearPasswords()
                    }.disabled(!model.scope.canUseServer || model.scope.capabilities?.canChangePassword != true || (!emptyRootPassword && (newPassword.isEmpty || newPassword != repeatedPassword)))
                    Text(L10n.tr("密码仅用于这次请求，不会保存在本机。使用 OIDC 的账户需按服务器提供的本地密码规则操作。")).font(.caption).foregroundStyle(.secondary)
                }.disabled(model.scope.isWorking)
            }.formStyle(.grouped).textFieldStyle(.shelfLeading)
        }.frame(width: 660, height: 760)
        .task(id: model.scope.identity) { clearPasswords(); deviceEditor = nil; await model.load() }
        .onDisappear { clearPasswords(); model.scope.cancel() }
        .sheet(item: $deviceEditor) { target in
            PersonalDeviceEditor(device: target.device) { name, email in
                model.saveDevice(context: target.context, oldName: target.device?.name, name: name, email: email)
            }
        }
        .personalConfirmation(scope: model.scope)
    }
    private func clearPasswords() { currentPassword = ""; newPassword = ""; repeatedPassword = ""; emptyRootPassword = false }
    private func editDevice(_ device: EReaderDevice?) {
        guard let context = model.scope.context() else { return }
        deviceEditor = .init(device: device, context: context)
    }
}

private struct PersonalDeviceEditorTarget: Identifiable {
    let id = UUID()
    let device: EReaderDevice?
    let context: PersonalAccountContext
}

private struct PersonalDeviceEditor: View {
    let device: EReaderDevice?
    let save: (String, String) -> Void
    @State private var name = ""
    @State private var email = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(device == nil ? L10n.tr("添加个人阅读器") : L10n.tr("编辑个人阅读器")).font(.title2.bold())
            TextField(L10n.tr("设备名称"), text: $name); TextField(L10n.tr("收件电子邮箱"), text: $email)
            Text(L10n.tr("可填写 Kindle 等设备的收件邮箱，并在设备服务中允许服务器发件地址。")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction); Button(L10n.tr("继续")) { save(name, email); dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !email.contains("@")) }
        }.padding(24).frame(width: 490).textFieldStyle(.shelfLeading)
        .onAppear { name = device?.name ?? ""; email = device?.email ?? "" }
    }
}

struct PersonalHeader: View {
    let title: String
    var subtitle: String = ""
    var busy = false
    let close: () -> Void
    var body: some View {
        HStack { VStack(alignment: .leading, spacing: 4) { Text(title).font(.title2.bold()); if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) } }; Spacer(); if busy { ProgressView().controlSize(.small) }; Button(L10n.tr("完成"), action: close).keyboardShortcut(.cancelAction) }.padding(20)
    }
}
struct PersonalStatus: View {
    let scope: PersonalAccountScope
    var body: some View {
        if let error = scope.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout).padding(10) }
        if let notice = scope.notice { Text(notice).foregroundStyle(.secondary).font(.callout).padding(8) }
        if !scope.canUseServer { Text(scope.store.isOffline ? L10n.tr("当前处于离线状态，连接服务器后可管理设备与发布链接。") : L10n.tr("请连接真实账户后使用个人功能。")).font(.caption).foregroundStyle(.secondary).padding(10) }
    }
}
private struct PersonalConfirmationModifier: ViewModifier {
    let scope: PersonalAccountScope
    func body(content: Content) -> some View {
        content.alert(scope.confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { scope.confirmation != nil }, set: { if !$0 { scope.confirmation = nil } })) {
            if let confirmation = scope.confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) { scope.confirmation = nil; Task { await confirmation.action() } }
                Button(L10n.tr("取消"), role: .cancel) { scope.confirmation = nil }
            }
        } message: { Text(scope.confirmation?.message ?? "") }
    }
}
extension View {
    func personalConfirmation(scope: PersonalAccountScope) -> some View { modifier(PersonalConfirmationModifier(scope: scope)) }
}
