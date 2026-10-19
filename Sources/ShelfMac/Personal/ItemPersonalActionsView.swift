import SwiftUI
import ShelfCore

struct ItemPersonalActionsView: View {
    let store: AppStore
    @State private var model: ItemPersonalActionsModel
    @State private var editor: SharePublicationEditor?
    @State private var showRSS = false
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, item: ShelfCore.LibraryItem) { self.store = store; _model = State(initialValue: .init(store: store, item: item)) }
    var body: some View {
        VStack(spacing: 0) {
            PersonalHeader(title: L10n.tr("分享与发送"), subtitle: model.item.title, busy: model.scope.isWorking) { dismiss() }
            PersonalStatus(scope: model.scope)
            Form {
                if model.scope.capabilities?.canPublish == true {
                    Section(L10n.tr("公开音频分享")) { shareContent }
                    Section(L10n.tr("RSS 订阅")) {
                        Button(L10n.tr("管理此内容的 RSS 订阅…"), systemImage: "dot.radiowaves.left.and.right") { showRSS = true }
                            .disabled(!model.isLoaded || !model.hasAudio)
                        Text(L10n.tr("RSS 可用于外部播客或音频客户端。订阅链接无需登录即可访问。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.tr("发送电子书到阅读器")) { sendContent }
            }.formStyle(.grouped).disabled(!model.scope.canUseServer || model.scope.isWorking)
            HStack { Button(L10n.tr("刷新"), systemImage: "arrow.clockwise") { Task { await model.load() } }; Spacer() }.padding(16).disabled(!model.scope.canUseServer || model.scope.isWorking)
        }.frame(width: 650, height: 580)
        .task(id: model.scope.identity) { editor = nil; showRSS = false; await model.load() }
        .onDisappear { model.scope.cancel() }
        .sheet(item: $editor) { entry in SharePublicationEditorView(entry: entry) { slug, expiry, downloadable in model.publish(editor: entry, slug: slug, expiresAt: expiry, downloadable: downloadable) } }
        .sheet(isPresented: $showRSS) { RSSManagementView(store: store, target: model.rssTarget) }
        .personalConfirmation(scope: model.scope)
    }
    @ViewBuilder private var shareContent: some View {
        if let share = model.share, let context = model.scope.context() {
            if let url = try? PersonalPublicationLinks.share(slug: share.slug, profile: context.profile) { PersonalPublicLink(url: url) }
            LabeledContent(L10n.tr("允许下载"), value: share.isDownloadable ? L10n.tr("是") : L10n.tr("否"))
            LabeledContent(L10n.tr("到期时间"), value: share.expiresAt.flatMap(Self.date)?.formatted(date: .abbreviated, time: .shortened) ?? L10n.tr("永不过期"))
            HStack { Button(L10n.tr("配置…")) { editor = model.shareEditor() }; Spacer(); Button(L10n.tr("撤销…"), role: .destructive) { model.revokeShare() } }
        } else {
            Button(L10n.tr("创建公开分享…"), systemImage: "link.badge.plus") { editor = model.shareEditor() }.disabled(!model.canShare)
            Text(model.item.mediaType == "book" ? L10n.tr("为此有声书创建无需登录的收听链接。") : L10n.tr("播客可通过 RSS 订阅分享。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var sendContent: some View {
        if model.item.media.ebookFile == nil {
            Text(L10n.tr("此内容没有主电子书文件。")).foregroundStyle(.secondary)
        } else if model.devices.isEmpty {
            Text(model.scope.isWorking ? L10n.tr("正在加载阅读器…") : L10n.tr("当前账户没有可用阅读器。可在个人设置中添加，或请管理员共享设备。")).foregroundStyle(.secondary)
        } else {
            ForEach(model.devices) { device in
                HStack { VStack(alignment: .leading) { Text(device.name); Text(device.email).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button(L10n.tr("发送…"), systemImage: "paperplane") { model.sendEBook(to: device) }.disabled(!model.canSendEBook) }
            }
            Text(L10n.tr("发送主电子书文件；服务器需要已配置邮件服务。")).font(.caption).foregroundStyle(.secondary)
        }
    }
    fileprivate static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}

private struct SharePublicationEditorView: View {
    let entry: SharePublicationEditor
    let publish: (String, Date?, Bool) -> Void
    @State private var slug = ""
    @State private var expires = false
    @State private var expiry = Date().addingTimeInterval(7 * 86400)
    @State private var downloadable = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(entry.previous == nil ? L10n.tr("创建公开分享") : L10n.tr("配置公开分享")).font(.title2.bold())
            Text(entry.title).foregroundStyle(.secondary)
            TextField(L10n.tr("链接名称（英文字母、数字、- 或 _）"), text: $slug)
            Toggle(L10n.tr("允许下载音频"), isOn: $downloadable)
            Toggle(L10n.tr("设置到期时间"), isOn: $expires)
            if expires { DatePicker(L10n.tr("到期时间"), selection: $expiry, in: Date()..., displayedComponents: [.date, .hourAndMinute]) }
            Text(L10n.tr("链接可被再次转发；到期或撤销之前，持有者都能访问。配置现有分享会先撤销旧分享。")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("继续…")) { publish(slug, expires ? expiry : nil, downloadable); dismiss() }.buttonStyle(.borderedProminent).disabled(!PersonalPublicationLinks.isValidSlug(slug.trimmingCharacters(in: .whitespacesAndNewlines)) || (expires && expiry <= Date())) }
        }.padding(24).frame(width: 520).textFieldStyle(.shelfLeading)
        .onAppear {
            slug = entry.previous?.slug ?? UUID().uuidString.lowercased(); downloadable = entry.previous?.isDownloadable ?? false
            if let value = entry.previous?.expiresAt, let date = ItemPersonalActionsView.date(value) { expires = true; expiry = max(Date().addingTimeInterval(3600), date) }
        }
    }
}
