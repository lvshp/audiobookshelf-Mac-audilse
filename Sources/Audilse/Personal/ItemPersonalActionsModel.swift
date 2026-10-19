import Foundation
import Observation
import AudilseCore

struct SharePublicationEditor: Identifiable {
    let id = UUID()
    let context: PersonalAccountContext
    let mediaID: String
    let title: String
    let previous: MediaShare?
}

@MainActor @Observable final class ItemPersonalActionsModel {
    let scope: PersonalAccountScope
    let itemID: String
    var item: LibraryItem
    var share: MediaShare?
    var devices: [EReaderDevice] = []
    var isLoaded = false
    init(store: AppStore, item: LibraryItem) { scope = .init(store: store); itemID = item.id; self.item = item }
    var hasAudio: Bool { !item.media.tracks.isEmpty || !item.media.audioFiles.isEmpty || item.media.episodes.contains { $0.audioFile != nil } }
    var canShare: Bool { isLoaded && scope.capabilities?.canPublish == true && item.mediaType == "book" && hasAudio && item.media.id != nil }
    var canSendEBook: Bool { isLoaded && scope.canUseServer && item.mediaType == "book" && item.media.ebookFile != nil && !devices.isEmpty }
    var rssTarget: RSSPublishingTarget { .init(entity: .item, id: itemID, title: item.title) }
    func load() async {
        scope.bind(); share = nil; devices = []; isLoaded = false
        guard let context = scope.context() else { return }
        let id = itemID
        await scope.run(context, operation: { client in
            async let details = client.itemPersonalDetails(id: id)
            async let account = client.personalAccountDetails()
            return try await (details, account)
        }, apply: { result in
            let (details, account) = result
            self.item = details.item; self.share = details.mediaItemShare; self.devices = account.ereaderDevices; self.isLoaded = true
        })
    }
    func shareEditor() -> SharePublicationEditor? {
        guard canShare, let context = scope.context(), let mediaID = item.media.id else { return nil }
        return .init(context: context, mediaID: mediaID, title: item.title, previous: share)
    }
    func publish(editor: SharePublicationEditor, slug: String, expiresAt: Date?, downloadable: Bool) {
        guard scope.isCurrent(editor.context), canShare else { return }
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PersonalPublicationLinks.isValidSlug(slug) else { scope.error = L10n.error(PersonalFeatureError.invalidSlug); return }
        guard expiresAt == nil || expiresAt! > Date() else { scope.error = L10n.tr("到期时间必须晚于现在。"); return }
        let draft = MediaShareDraft(mediaItemId: editor.mediaID, mediaItemType: .book, slug: slug, expiresAt: expiresAt.map { $0.timeIntervalSince1970 * 1000 } ?? 0, isDownloadable: downloadable)
        let message = L10n.format("持有链接的人可以收听《%1$@》%2$@，无需账户登录。", String(describing: editor.title), String(describing: downloadable ? L10n.tr("并下载音频") : "")) + (editor.previous == nil ? "" : L10n.tr("\n重新配置需要先撤销旧分享，再创建新分享；若第二步失败，旧分享仍会保持撤销。"))
        scope.confirm(.init(title: editor.previous == nil ? L10n.tr("创建公开音频分享？") : L10n.tr("重新配置公开分享？"), message: message, destructive: editor.previous != nil, action: {
            if let old = editor.previous {
                guard await self.scope.run(editor.context, operation: { try await $0.deleteShare(id: old.id) }, apply: { _ in self.share = nil; self.scope.notice = L10n.tr("旧分享已撤销。") }) else { return }
            }
            let opened = await self.scope.run(editor.context, operation: { try await $0.createShare(draft) }, apply: { self.share = $0; self.scope.notice = L10n.tr("音频分享已创建。") })
            if !opened, editor.previous != nil, self.scope.isCurrent(editor.context) { self.scope.notice = L10n.tr("旧分享已撤销，新分享创建失败；可重新创建。") }
        }))
    }
    func revokeShare() {
        guard let context = scope.context(), scope.capabilities?.canPublish == true, let previous = share else { return }
        scope.confirm(.init(title: L10n.tr("撤销公开音频分享？"), message: L10n.tr("分享链接将立即失效。已经下载的音频不会被删除。"), destructive: true, action: {
            await self.scope.run(context, operation: { try await $0.deleteShare(id: previous.id) }, apply: { _ in self.share = nil; self.scope.notice = L10n.tr("音频分享已撤销。") })
        }))
    }
    func sendEBook(to device: EReaderDevice) {
        guard canSendEBook, let context = scope.context(), devices.contains(device) else { return }
        let itemID = itemID
        scope.confirm(.init(title: L10n.tr("发送电子书？"), message: L10n.format("服务器将把《%1$@》的主电子书文件发送到 %2$@（%3$@）。", String(describing: item.title), String(describing: device.name), String(describing: device.email)), action: {
            await self.scope.run(context, operation: { try await $0.sendEBook(itemID: itemID, deviceName: device.name) }, apply: { _ in self.scope.notice = L10n.tr("电子书已交给服务器发送。") })
        }))
    }
}
