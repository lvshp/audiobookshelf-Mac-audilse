import Foundation
import Observation
import ShelfCore

@MainActor @Observable final class PersonalSettingsModel {
    let scope: PersonalAccountScope
    var devices: [EReaderDevice] = []
    var preferences = ClientPreferences()
    @ObservationIgnored private var preferencesPartition: AccountPartition?
    init(store: AppStore) { scope = .init(store: store) }
    var personalDevices: [EReaderDevice] {
        devices.filter { $0.availabilityOption == "specificUsers" && $0.users == [scope.store.user?.id ?? ""] }
    }
    var sharedDevices: [EReaderDevice] { devices.filter { !personalDevices.contains($0) } }
    func load() async {
        scope.bind(); devices = []
        preferencesPartition = scope.store.partition
        if let partition = preferencesPartition { preferences = PersonalPlaybackPreferencesStore.shared.preferences(for: partition) }
        else { preferences = .init() }
        guard let context = scope.context() else { return }
        await scope.run(context, operation: { try await $0.personalAccountDetails() }, apply: { self.devices = $0.ereaderDevices })
    }
    func savePreferences() {
        guard let partition = preferencesPartition, partition == scope.store.partition, scope.canUseBoundAccount else { return }
        do {
            try scope.store.savePlaybackPreferences(preferences, for: partition)
            preferences = scope.store.playbackPreferences
            scope.notice = L10n.tr("播放偏好已保存到此 Mac。")
        } catch is CancellationError { }
        catch { scope.error = L10n.error(error) }
    }
    func saveDevice(context: PersonalAccountContext, oldName: String?, name: String, email: String) {
        guard scope.isCurrent(context), scope.capabilities?.canManageReaderDevices == true else { return }
        let updated = EReaderDevice(name: name.trimmingCharacters(in: .whitespacesAndNewlines), email: email.trimmingCharacters(in: .whitespacesAndNewlines), userID: context.user.id)
        var changes = personalDevices.filter { $0.name != oldName }; changes.append(updated)
        do {
            try PersonalPublicationLinks.validatePersonalDevices(changes, userID: context.user.id)
            guard !sharedDevices.contains(where: { $0.name == updated.name }) else { throw PersonalFeatureError.duplicateDevice }
        } catch { scope.error = L10n.error(error); return }
        let payload = changes
        scope.confirm(.init(title: oldName == nil ? L10n.tr("创建个人阅读器？") : L10n.tr("更新个人阅读器？"), message: L10n.format("电子书将可以通过服务器邮件发送到 %1$@。此设备仅关联当前账户。", String(describing: updated.email)), action: {
            await self.scope.run(context, operation: { try await $0.updateEReaderDevices(payload) }, apply: { self.devices = $0; self.scope.notice = L10n.tr("阅读器设备已保存。") })
        }))
    }
    func deleteDevice(_ device: EReaderDevice) {
        guard let context = scope.context(), scope.capabilities?.canManageReaderDevices == true else { return }
        let remaining = personalDevices.filter { $0.name != device.name }
        scope.confirm(.init(title: L10n.tr("删除个人阅读器？"), message: L10n.format("将移除 %1$@（%2$@），不会删除已经发送的电子书。", String(describing: device.name), String(describing: device.email)), destructive: true, action: {
            await self.scope.run(context, operation: { try await $0.updateEReaderDevices(remaining) }, apply: { self.devices = $0; self.scope.notice = L10n.tr("个人阅读器已删除。") })
        }))
    }
    func changePassword(current: String, new: String) {
        guard let context = scope.context(), scope.capabilities?.canChangePassword == true else { return }
        scope.confirm(.init(title: L10n.tr("修改当前账户密码？"), message: L10n.format("其他设备可能需要重新登录。%1$@", String(describing: new.isEmpty ? L10n.tr("新密码将为空，请确认这是你希望的设置。") : "")), destructive: true, action: {
            var mustSignIn = false
            let changed = await self.scope.run(context, operation: { try await $0.changePassword(currentPassword: current, newPassword: new) }, apply: { result in
                switch result { case .authenticated: self.scope.notice = L10n.tr("密码已修改，当前设备的认证已更新。"); case .requiresSignIn: mustSignIn = true }
            })
            if changed, mustSignIn, self.scope.isCurrent(context) { await self.scope.store.signOut() }
        }))
    }
}
