import Foundation
import Observation
import ShelfCore

struct RSSPublishingTarget: Sendable, Identifiable {
    let entity: RSSEntity
    let entityID: String
    let title: String
    var id: String { entity.rawValue + ":" + entityID }
    init(entity: RSSEntity, id: String, title: String) { self.entity = entity; entityID = id; self.title = title }
    init?(feed: RSSFeed) {
        guard let id = feed.entityId else { return nil }
        switch feed.entityType {
        case "libraryItem", "item": entity = .item
        case "collection": entity = .collection
        case "series": entity = .series
        default: return nil
        }
        entityID = id; title = feed.meta?.title ?? L10n.tr("RSS 订阅")
    }
}

struct RSSPublicationEditor: Identifiable {
    let id = UUID()
    let context: PersonalAccountContext
    let target: RSSPublishingTarget
    let previous: RSSFeed?
}

@MainActor @Observable final class RSSManagementModel {
    let scope: PersonalAccountScope
    let target: RSSPublishingTarget?
    var feeds: [RSSFeed] = []
    init(store: AppStore, target: RSSPublishingTarget?) { scope = .init(store: store); self.target = target }
    var visibleFeeds: [RSSFeed] {
        guard let target else { return feeds }
        return feeds.filter { RSSPublishingTarget(feed: $0)?.id == target.id }
    }
    func load() async {
        scope.bind(); feeds = []
        guard let context = scope.context(), scope.capabilities?.canPublish == true else { return }
        await scope.run(context, operation: { try await $0.rssFeeds() }, apply: { self.feeds = $0 })
    }
    func editor(for feed: RSSFeed? = nil) -> RSSPublicationEditor? {
        guard let context = scope.context(), scope.capabilities?.canPublish == true,
              let selected = feed.flatMap(RSSPublishingTarget.init(feed:)) ?? target else { return nil }
        return .init(context: context, target: selected, previous: feed)
    }
    func publish(editor: RSSPublicationEditor, slug: String, preventIndexing: Bool, ownerName: String, ownerEmail: String) {
        guard scope.isCurrent(editor.context), scope.capabilities?.canPublish == true else { return }
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PersonalPublicationLinks.isValidSlug(slug) else { scope.error = L10n.error(PersonalFeatureError.invalidSlug); return }
        let options: RSSFeedOptions
        do {
            options = .init(serverAddress: try PersonalPublicationLinks.origin(profile: editor.context.profile), slug: slug, preventIndexing: preventIndexing, ownerName: ownerName.trimmingCharacters(in: .whitespacesAndNewlines), ownerEmail: ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { scope.error = L10n.error(error); return }
        let message = L10n.format("持有订阅链接的人可以访问音频内容。%1$@", String(describing: preventIndexing ? L10n.tr("已请求搜索引擎不要收录，但链接仍是公开的。") : L10n.tr("允许搜索引擎收录订阅。"))) + (editor.previous == nil ? "" : L10n.tr("\n服务器需要先撤销旧订阅，再重新发布；如果第二步失败，旧订阅仍会保持撤销。"))
        scope.confirm(.init(title: editor.previous == nil ? L10n.tr("公开发布 RSS 订阅？") : L10n.tr("重新配置并发布订阅？"), message: message, destructive: editor.previous != nil, action: {
            guard self.scope.isCurrent(editor.context), self.scope.capabilities?.canPublish == true else { return }
            if let old = editor.previous {
                guard await self.scope.run(editor.context, operation: { try await $0.closeRSSFeed(id: old.id) }, apply: { self.feeds.removeAll { $0.id == old.id }; self.scope.notice = L10n.tr("旧订阅已撤销。") }) else { return }
            }
            guard self.scope.isCurrent(editor.context), self.scope.capabilities?.canPublish == true else { return }
            let target = editor.target
            let opened = await self.scope.run(editor.context, operation: { try await $0.openRSSFeed(entity: target.entity, id: target.entityID, options: options) }, apply: { feed in self.feeds.append(feed); self.scope.notice = L10n.tr("RSS 订阅已发布。") })
            if !opened, editor.previous != nil, self.scope.isCurrent(editor.context) { self.scope.notice = L10n.tr("旧订阅已撤销，重新发布失败；可重新创建订阅。") }
            // Open returns a minified feed; fetch episodes without reclassifying a
            // successful publication as failed if the follow-up read fails.
            guard opened, self.scope.isCurrent(editor.context), self.scope.capabilities?.canPublish == true else { return }
            await self.scope.run(editor.context, operation: { try await $0.rssFeeds() }, apply: { self.feeds = $0 })
            if self.scope.isCurrent(editor.context) { self.scope.notice = L10n.tr("RSS 订阅已发布。") }
        }))
    }
    func revoke(_ feed: RSSFeed) {
        guard let context = scope.context(), scope.capabilities?.canPublish == true else { return }
        scope.confirm(.init(title: L10n.tr("撤销 RSS 订阅？"), message: L10n.format("%1$@的现有链接将失效。已经下载到其他设备的文件不会被删除。", String(describing: feed.meta?.title ?? L10n.tr("此订阅"))), destructive: true, action: {
            guard self.scope.isCurrent(context), self.scope.capabilities?.canPublish == true else { return }
            await self.scope.run(context, operation: { try await $0.closeRSSFeed(id: feed.id) }, apply: { self.feeds.removeAll { $0.id == feed.id }; self.scope.notice = L10n.tr("RSS 订阅已撤销。") })
        }))
    }
}
