import SwiftUI
import AudilseCore

struct AllDevicesSignOutSource: Identifiable {
    let id: UUID
    let profile: ServerProfile
    let user: UserAccount
    let partition: AccountPartition
    let client: ABSClient

    @MainActor init?(store: AppStore) {
        guard !store.isDemo, !store.isOffline, !store.isConnecting,
              !store.recoveryBusy, store.serverRecovery == nil,
              let profile = store.profile, let user = store.user, user.isActive,
              user.type != "guest", profile.userID == user.id,
              let version = profile.serverVersion,
              ServerCapabilities(version: version).supportsLogoutAllDevices,
              let partition = store.partition, let client = store.client else { return nil }
        id = store.accountOperationID; self.profile = profile; self.user = user
        self.partition = partition; self.client = client
    }
    @MainActor func isCurrent(_ store: AppStore) -> Bool {
        guard let current = Self(store: store) else { return false }
        return current.id == id && current.profile == profile && current.partition == partition && current.client === client &&
            current.user.id == user.id && current.user.username == user.username && current.user.type == user.type &&
            current.user.permissions == user.permissions && current.user.librariesAccessible == user.librariesAccessible &&
            current.user.itemTagsSelected == user.itemTagsSelected
    }
    static func message(for eligibility: AllDevicesLogoutEligibility) -> String {
        switch eligibility {
        case .available: ""
        case .unsupportedServer: L10n.tr("此功能需要 Audiobookshelf 2.36.1 或更新版本。")
        case .missingRefreshToken: L10n.tr("此登录没有刷新会话，无法请求退出所有设备。请使用账户密码或单点登录重新登录。")
        case .accountMismatch: L10n.tr("登录凭据与当前账户不匹配，请重新登录。")
        }
    }
}

enum AllDevicesSignOutCompletion { case finished, notCompleted(String) }

struct AllDevicesSignOutView: View {
    let store: AppStore
    let source: AllDevicesSignOutSource
    @Environment(\.dismiss) private var dismiss
    @State private var eligibility: AllDevicesLogoutEligibility?
    @State private var error: String?
    @State private var isWorking = false
    @State private var consumed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.tr("退出所有设备？")).font(.title2.bold())
                Spacer()
                SheetCloseButton(identifier: "logout-all.close") { dismiss() }.disabled(isWorking)
            }
            Text(source.user.username + " · " + source.profile.name).font(.headline).textSelection(.enabled)
            Text(L10n.tr("将请求这台服务器废止此账户的全部刷新会话。其他设备已签发的访问令牌可能仍有效，直到到期；API 密钥不会被撤销。"))
            Text(L10n.tr("本机原件、下载和待同步记录会保留。此操作不会退出单点登录提供商。"))
                .foregroundStyle(.secondary)
            if isWorking { ProgressView(L10n.tr("正在退出…")) }
            else if !source.isCurrent(store) { Text(L10n.tr("账户已变化，请关闭后重新打开。")).foregroundStyle(.orange) }
            else if let eligibility, eligibility != .available { Text(AllDevicesSignOutSource.message(for: eligibility)).foregroundStyle(.orange) }
            else if eligibility == nil && error == nil { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button(L10n.tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Spacer()
                Button(L10n.tr("退出所有设备"), role: .destructive) { submit() }
                    .disabled(isWorking || consumed || eligibility != .available || !source.isCurrent(store))
            }
        }.padding(24).frame(width: 540).fixedSize(horizontal: false, vertical: true)
        .task {
            do {
                let result = try await source.client.allDevicesLogoutEligibility()
                guard !Task.isCancelled, source.isCurrent(store) else { return }
                eligibility = result
            } catch {
                guard !Task.isCancelled, source.isCurrent(store) else { return }
                self.error = L10n.error(error)
            }
        }
    }
    private func submit() {
        guard !isWorking, !consumed, eligibility == .available, source.isCurrent(store) else { return }
        isWorking = true; consumed = true
        Task {
            let result = await store.signOutAllDevices(source)
            isWorking = false
            switch result {
            case .finished: dismiss()
            case let .notCompleted(message): error = message
            }
        }
    }
}
