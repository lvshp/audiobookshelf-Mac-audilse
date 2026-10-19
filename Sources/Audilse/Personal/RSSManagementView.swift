import SwiftUI
import AppKit
import AudilseCore

struct RSSManagementView: View {
    let store: AppStore
    @State private var model: RSSManagementModel
    @State private var editor: RSSPublicationEditor?
    @State private var detailFeed: RSSFeed?
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, target: RSSPublishingTarget? = nil) { self.store = store; _model = State(initialValue: .init(store: store, target: target)) }
    var body: some View {
        VStack(spacing: 0) {
            PersonalHeader(title: L10n.tr("RSS 订阅"), subtitle: model.target?.title ?? L10n.tr("服务器发布的订阅"), busy: model.scope.isWorking) { dismiss() }
            PersonalStatus(scope: model.scope)
            if model.scope.capabilities?.canPublish != true {
                ContentUnavailableView(L10n.tr("需要管理员权限"), systemImage: "dot.radiowaves.left.and.right", description: Text(L10n.tr("Audiobookshelf 只允许管理员发布和管理 RSS。")))
            } else {
                List {
                    if model.visibleFeeds.isEmpty { Text(model.scope.isWorking ? L10n.tr("正在加载订阅…") : L10n.tr("尚未发布 RSS 订阅。")).foregroundStyle(.secondary) }
                    ForEach(model.visibleFeeds) { feed in feedRow(feed) }
                }.listStyle(.inset).disabled(model.scope.isWorking)
                HStack {
                    Button(L10n.tr("刷新"), systemImage: "arrow.clockwise") { Task { await model.load() } }
                    Spacer()
                    if model.target != nil { Button(L10n.tr("发布订阅…"), systemImage: "plus") { editor = model.editor() }.buttonStyle(.borderedProminent).disabled(!model.visibleFeeds.isEmpty) }
                }.padding(18).disabled(!model.scope.canUseServer || model.scope.isWorking)
            }
        }.frame(width: 660, height: 540)
        .task(id: model.scope.identity) { editor = nil; detailFeed = nil; await model.load() }
        .onDisappear { model.scope.cancel() }
        .sheet(item: $editor) { entry in
            RSSPublicationEditorView(entry: entry) { slug, indexing, name, email in model.publish(editor: entry, slug: slug, preventIndexing: indexing, ownerName: name, ownerEmail: email) }
        }
        .sheet(item: $detailFeed) { feed in RSSFeedDetailsView(feed: feed) }
        .onChange(of: model.feeds) { _, feeds in
            if let selected = detailFeed { detailFeed = feeds.first { $0.id == selected.id } }
        }
        .personalConfirmation(scope: model.scope)
    }
    private func feedRow(_ feed: RSSFeed) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(feed.meta?.title ?? L10n.tr("RSS 订阅")).font(.headline)
            if let context = model.scope.context(), let url = try? PersonalPublicationLinks.rss(feed: feed, profile: context.profile) {
                PersonalPublicLink(url: url)
            }
            Text(feed.meta?.preventIndexing == false ? L10n.tr("允许搜索引擎收录") : L10n.tr("请求搜索引擎不收录")).font(.caption).foregroundStyle(.secondary)
            LabeledContent(L10n.tr("条目数量"), value: feed.episodes.map { String($0.count) } ?? L10n.tr("未知"))
            HStack { Button(L10n.tr("查看条目…")) { detailFeed = feed }; Button(L10n.tr("配置…")) { editor = model.editor(for: feed) }.disabled(RSSPublishingTarget(feed: feed) == nil); Spacer(); Button(L10n.tr("撤销…"), role: .destructive) { model.revoke(feed) } }
        }.padding(.vertical, 8)
    }
}


private struct RSSFeedDetailsView: View {
    let feed: RSSFeed
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    private let pageSize = 80
    private var episodes: [RSSFeedEpisode] { feed.episodes ?? [] }
    private var pageCount: Int { max(1, (episodes.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(page, pageCount - 1) }
    private var indices: Range<Int> {
        let start = currentPage * pageSize
        return start..<min(start + pageSize, episodes.count)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(L10n.tr("RSS 条目详情")).font(.title2.bold())
                    Text(feed.meta?.title ?? L10n.tr("RSS 订阅")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            LabeledContent(L10n.tr("条目数量"), value: feed.episodes.map { String($0.count) } ?? L10n.tr("未知"))
            LabeledContent(L10n.tr("更新时间")) {
                if let timestamp = feed.updatedAt, timestamp.isFinite, timestamp > 0 {
                    Text(Date(timeIntervalSince1970: timestamp / 1_000), format: .dateTime.year().month().day().hour().minute())
                } else { Text(L10n.tr("未知")) }
            }
            if feed.episodes == nil {
                ContentUnavailableView(L10n.tr("服务器未提供条目列表"), systemImage: "list.bullet")
            } else if episodes.isEmpty {
                ContentUnavailableView(L10n.tr("此订阅尚无条目"), systemImage: "list.bullet")
            } else {
                List {
                    ForEach(indices, id: \.self) { index in
                        HStack(alignment: .top) {
                            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40, alignment: .leading)
                            Text(episodes[index].title ?? L10n.tr("未提供标题")).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }.listStyle(.inset)
                HStack {
                    Button(L10n.tr("上一页")) { page = max(0, currentPage - 1) }.disabled(currentPage == 0)
                    Spacer()
                    Text(L10n.format("第 %1$@ / %2$@ 页 · %3$@ 项", String(currentPage + 1), String(pageCount), String(episodes.count))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("下一页")) { page = min(pageCount - 1, currentPage + 1) }.disabled(currentPage + 1 >= pageCount)
                }
            }
        }.padding(20).frame(width: 660, height: 540)
        .onChange(of: feed.id) { _, _ in page = 0 }
    }
}

struct RSSPublicationEditorView: View {
    let entry: RSSPublicationEditor
    let publish: (String, Bool, String, String) -> Void
    @State private var slug = ""
    @State private var preventIndexing = true
    @State private var ownerName = ""
    @State private var ownerEmail = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.previous == nil ? L10n.tr("发布 RSS") : L10n.tr("配置 RSS")).font(.title2.bold())
            Text(entry.target.title).foregroundStyle(.secondary)
            TextField(L10n.tr("链接名称（英文字母、数字、- 或 _）"), text: $slug)
            Toggle(L10n.tr("请求搜索引擎不收录"), isOn: $preventIndexing)
            TextField(L10n.tr("所有者姓名（可选，随订阅公开）"), text: $ownerName)
            TextField(L10n.tr("所有者邮箱（可选，随订阅公开）"), text: $ownerEmail)
            Text(L10n.tr("订阅链接可直接播放内容。请只将链接发送给你愿意分享的人。")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("继续…")) { publish(slug, preventIndexing, ownerName, ownerEmail); dismiss() }.buttonStyle(.borderedProminent).disabled(!PersonalPublicationLinks.isValidSlug(slug.trimmingCharacters(in: .whitespacesAndNewlines))) }
        }.padding(24).frame(width: 520).textFieldStyle(.shelfLeading)
        .onAppear {
            slug = entry.previous?.feedUrl.split(separator: "/").last.map(String.init) ?? UUID().uuidString.lowercased()
            preventIndexing = entry.previous?.meta?.preventIndexing ?? true
            ownerName = entry.previous?.meta?.ownerName ?? ""; ownerEmail = entry.previous?.meta?.ownerEmail ?? ""
        }
    }
}

struct PersonalPublicLink: View {
    let url: URL
    var body: some View {
        HStack(alignment: .top) {
            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
            Spacer()
            Button(L10n.tr("复制"), systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help(L10n.tr("打开公开链接"))
        }
    }
}
