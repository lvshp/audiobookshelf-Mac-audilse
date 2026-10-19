import SwiftUI
import AuthenticationServices
import AudilseCore

struct ConnectionView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var failure: String?
    @State private var allowHTTP = false
    @State private var isSubmitting = false
    @State private var isWaitingForOIDC = false
    @State private var oidcTask: Task<Void, Never>?
    @State private var systemAuthentication = SystemAuthentication()
    @FocusState private var focused: Field?
    private enum Field { case address, username, password }
    private var normalizedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var requiresHTTPConsent: Bool { URL(string: normalizedAddress)?.scheme?.lowercased() == "http" }
    private var canAuthenticate: Bool {
        !normalizedAddress.isEmpty && !store.isConnecting && !store.recoveryBusy && !isSubmitting
            && (!requiresHTTPConsent || allowHTTP)
    }
    private var canLogin: Bool { canAuthenticate && !username.isEmpty && !password.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "books.vertical.fill").font(.system(size: 36, weight: .light)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(L10n.tr("你的故事，\n随处可听。")).font(.system(size: 36, weight: .medium, design: .serif)).foregroundStyle(.white).lineSpacing(8)
                Text(L10n.tr("连接 Audiobookshelf，\n打开属于你的私人书房。"))
                    .font(.system(size: 13)).lineSpacing(6).foregroundStyle(.white.opacity(0.65))
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield")
                    Text(L10n.tr("只连接你选择的服务器"))
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }.padding(32).frame(width: 260).frame(maxHeight: .infinity)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.23, blue: 0.36), Color(red: 0.23, green: 0.38, blue: 0.43)], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("连接你的书库")).font(.system(size: 24, weight: .bold))
                        Text(L10n.tr("使用服务器地址和 Audiobookshelf 账号登录")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SheetCloseButton(label: L10n.tr("关闭连接"), identifier: "connection.close") { dismiss() }
                }
                VStack(alignment: .leading, spacing: 15) {
                    field(L10n.tr("服务器地址")) {
                        TextField("https://books.example.com", text: $address).focused($focused, equals: .address).accessibilityIdentifier("connection.address")
                    }
                    HStack(spacing: 12) {
                        field(L10n.tr("用户名")) { TextField(L10n.tr("你的用户名"), text: $username).focused($focused, equals: .username).accessibilityIdentifier("connection.username") }
                        field(L10n.tr("名称（可选）")) { TextField(L10n.tr("我的书房"), text: $name) }
                    }
                    field(L10n.tr("密码")) { SecureField(L10n.tr("账号密码"), text: $password).focused($focused, equals: .password).accessibilityIdentifier("connection.password").onSubmit { login() } }
                    if requiresHTTPConsent {
                        Toggle(L10n.tr("允许通过 HTTP 连接此服务器"), isOn: $allowHTTP).font(.caption)
                    }
                }.textFieldStyle(.shelfLeading).controlSize(.large)
                if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Button(action: login) {
                    HStack(spacing: 9) {
                        if store.isConnecting || isSubmitting { ProgressView().controlSize(.small) }
                        Text(store.isConnecting || isSubmitting ? L10n.tr("正在连接…") : L10n.tr("连接并进入书库")).font(.system(size: 13, weight: .semibold))
                        if !store.isConnecting && !isSubmitting { Image(systemName: "arrow.right") }
                    }.frame(maxWidth: .infinity).frame(height: 28)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!canLogin)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("connection.submit")
                if isWaitingForOIDC {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("请在浏览器完成登录；等待过久可取消后重试。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connection.oidc-waiting")
                        Button(L10n.tr("取消认证")) { cancelOIDC() }
                            .buttonStyle(.bordered).accessibilityIdentifier("connection.oidc-cancel")
                    }
                } else {
                    Button(L10n.tr("使用 OpenID Connect 登录"), systemImage: "person.crop.circle.badge.checkmark") { oidcLogin() }
                        .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(!canAuthenticate)
                }
                HStack {
                    Text(L10n.tr("令牌加密保存在本机。")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(L10n.tr("浏览演示书库")) { password = ""; Task { await store.enterDemo(); dismiss() } }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(ShelfTheme.accent).disabled(store.isConnecting || isSubmitting || store.recoveryBusy)
                }
                Spacer(minLength: 0)
            }.padding(30).frame(width: 410)
        }.frame(minHeight: 530).background(ShelfTheme.canvas)
            .onAppear {
                if store.serverRecovery != nil, let profile = store.profile {
                    address = profile.baseURL.absoluteString
                    username = profile.username
                    name = profile.name
                    focused = .password
                } else { focused = .address }
            }
            .onDisappear { cancelOIDC() }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); content() }
    }
    private func login() {
        guard canLogin else { return }
        failure = nil
        isSubmitting = true
        let draft = (name: name, address: address, username: username, password: password)
        Task {
            defer { isSubmitting = false }
            guard !store.isConnecting, !store.recoveryBusy else { return }
            do { try await store.connect(name: draft.name, address: draft.address, username: draft.username, password: draft.password); password = ""; dismiss() }
            catch { failure = L10n.error(error) }
        }
    }
    private func oidcLogin() {
        guard canAuthenticate else { return }
        failure = nil
        isSubmitting = true
        let draft = (name: name, address: address)
        oidcTask = Task {
            defer { isSubmitting = false; isWaitingForOIDC = false; oidcTask = nil }
            guard !store.isConnecting, !store.recoveryBusy else { return }
            do {
                try await store.connectOIDC(name: draft.name, address: draft.address) { url, scheme in
                    try Task.checkCancellation()
                    isWaitingForOIDC = true
                    defer { isWaitingForOIDC = false }
                    let callback = try await systemAuthentication.authenticate(url: url, callbackScheme: scheme)
                    try Task.checkCancellation()
                    return callback
                }
                password = ""; dismiss()
            } catch is CancellationError { }
            catch { failure = L10n.error(error) }
        }
    }
    private func cancelOIDC() {
        oidcTask?.cancel()
        systemAuthentication.cancel()
    }
}

@MainActor private final class SystemAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var attempt = UUID()
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        try Task.checkCancellation()
        let attempt = UUID()
        self.attempt = attempt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let authentication = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                    Task { @MainActor in self?.finish(attempt: attempt, callback: callback, error: error) }
                }
                authentication.presentationContextProvider = self
                authentication.prefersEphemeralWebBrowserSession = false
                session = authentication
                if !authentication.start() { finish(attempt: attempt, callback: nil, error: ConnectionFailure.invalidAddress) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.attempt == attempt else { return }
                self.cancel()
            }
        }
    }
    func cancel() {
        attempt = UUID()
        let active = session; session = nil
        let pending = continuation; continuation = nil
        active?.cancel(); pending?.resume(throwing: CancellationError())
    }
    private func finish(attempt: UUID, callback: URL?, error: (any Error)?) {
        guard self.attempt == attempt, let pending = continuation else { return }
        continuation = nil; session = nil
        if let callback { pending.resume(returning: callback) }
        else { pending.resume(throwing: error ?? CancellationError()) }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? NSWindow()
    }
}

struct PreferencesView: View {
    @Bindable var store: AppStore
    @State private var showPersonalSettings = false
    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label(L10n.tr("通用"), systemImage: "gearshape") }
            AboutView()
                .tabItem { Label(L10n.tr("关于"), systemImage: "info.circle") }
        }
        .padding(12)
        .sheet(isPresented: $showPersonalSettings) { PersonalSettingsView(store: store) }
    }

    private var generalSettings: some View {
        Form {
            Section(L10n.tr("语言")) {
                AppLanguagePicker()
                Text(L10n.tr("立即切换客户端界面语言，不修改服务器的 Web 界面设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.tr("外观")) { Picker(L10n.tr("主题"), selection: $store.appearance) { ForEach(Appearance.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
            Section(L10n.tr("账户")) {
                LabeledContent(L10n.tr("当前用户"), value: store.user?.username ?? L10n.tr("未登录"))
                LabeledContent(L10n.tr("服务器"), value: store.profile?.baseURL.host ?? L10n.tr("未连接"))
                Button(L10n.tr("连接其他服务器…")) { store.showConnection = true }
                Button(L10n.tr("播放偏好、阅读器与密码…")) { showPersonalSettings = true }
                    .disabled(store.partition == nil || store.user?.isActive != true || store.isConnecting)
            }
        }.formStyle(.grouped).padding(.vertical, 12)
    }
}
