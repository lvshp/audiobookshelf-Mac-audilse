import Foundation
import Observation
import SwiftUI
import ShelfCore

@MainActor @Observable private final class PodcastEpisodeEditorModel {
    let account = PodcastAccountSession()
    let itemID: String
    let episodeID: String
    var details: PodcastEpisodeDetails?
    var title = ""
    var subtitle = ""
    var description = ""
    var season = ""
    var episodeNumber = ""
    var episodeType = "full"
    var updatePublicationDate = false
    var publicationDate = Date()
    var searchTitle = ""
    var matches: [PodcastFeedEpisode] = []
    var selectedMatch: PodcastFeedEpisode?
    var isBusy = false
    var error: String?
    init(itemID: String, episodeID: String) { self.itemID = itemID; self.episodeID = episodeID }
    func load(store: AppStore) async {
        account.bind(store)
        await perform(requiring: [], operation: { [itemID, episodeID] in try await $0.podcastEpisodeDetails(itemID: itemID, episodeID: episodeID) }, apply: { details in
            self.details = details; self.title = details.base.title; self.subtitle = details.base.subtitle ?? ""; self.description = details.base.description ?? ""
            self.season = details.season ?? ""; self.episodeNumber = details.episodeNumber ?? ""; self.episodeType = details.episodeType ?? "full"
            self.searchTitle = details.base.title; self.matches = []; self.selectedMatch = nil; self.updatePublicationDate = false
            if let stamp = details.base.publishedAt, stamp.isFinite { self.publicationDate = Date(timeIntervalSince1970: stamp / 1000) }
        })
    }
    @discardableResult private func perform<T: Sendable>(requiring actions: [AdminAction], operation: @escaping @Sendable (ABSClient) async throws -> T, apply: (T) -> Void) async -> Bool {
        guard !isBusy else { return false }
        let snapshot: (ABSClient, UUID)
        do { snapshot = try account.snapshot(requiring: actions) }
        catch { self.error = L10n.error(error); return false }
        let (client, attempt) = snapshot
        isBusy = true; error = nil
        defer { if account.isCurrent(attempt) { isBusy = false } }
        do { let value = try await account.run(attempt) { try await operation(client) }; apply(value); return true }
        catch is CancellationError {} catch ABSError.sessionChanged {} catch let failure as URLError where failure.code == .cancelled {}
        catch { if account.isCurrent(attempt) { self.error = L10n.error(error) } }
        return false
    }
    func search() async {
        let term = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        await perform(requiring: [], operation: { [itemID] in try await $0.searchPodcastEpisodes(itemID: itemID, title: term) }, apply: { self.matches = $0 })
    }
    func apply(_ match: PodcastFeedEpisode) {
        selectedMatch = match; title = match.title; subtitle = match.subtitle ?? ""; description = match.description ?? ""
        season = match.season ?? ""; episodeNumber = match.episode ?? ""; episodeType = match.episodeType ?? "full"
        if let stamp = match.publishedAt, stamp.isFinite { publicationDate = Date(timeIntervalSince1970: stamp / 1000); updatePublicationDate = true }
    }
    func save() async -> Bool {
        guard let details, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var update = PodcastEpisodeUpdate()
        if title != details.base.title { update.title = title }
        if subtitle != (details.base.subtitle ?? "") { update.subtitle = subtitle }
        if description != (details.base.description ?? "") { update.description = description }
        if season != (details.season ?? "") { update.season = season }
        if episodeNumber != (details.episodeNumber ?? "") { update.episode = episodeNumber }
        if episodeType != (details.episodeType ?? "full") { update.episodeType = episodeType }
        if let selectedMatch { update.enclosure = selectedMatch.enclosure }
        if updatePublicationDate {
            update.publishedAt = publicationDate.timeIntervalSince1970 * 1000
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"; update.pubDate = formatter.string(from: publicationDate)
        }
        let payload = update
        return await perform(requiring: [.updateContent], operation: { [itemID, episodeID] in try await $0.updatePodcastEpisode(itemID: itemID, episodeID: episodeID, update: payload) }, apply: { _ in })
    }
}

struct PodcastEpisodeEditor: View {
    let store: AppStore
    let hasFeed: Bool
    let didSave: @MainActor () async -> Void
    @State private var model: PodcastEpisodeEditorModel
    @State private var tab = 0
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, itemID: String, episode: PodcastEpisode, hasFeed: Bool, didSave: @escaping @MainActor () async -> Void) {
        self.store = store; self.hasFeed = hasFeed; self.didSave = didSave
        _model = State(initialValue: .init(itemID: itemID, episodeID: episode.id))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.tr("编辑单集")).font(.title2.bold()); Spacer(); if model.isBusy { ProgressView().controlSize(.small) } }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            TabView(selection: $tab) {
                Form {
                    FormInputRow(L10n.tr("标题")) { TextField("", text: $model.title).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("标题")) }
                    FormInputRow(L10n.tr("副标题")) { TextField("", text: $model.subtitle).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("副标题")) }
                    VStack(alignment: .leading, spacing: 8) { FormInputRow(L10n.tr("季")) { TextField("", text: $model.season).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("季")) }; FormInputRow(L10n.tr("集")) { TextField("", text: $model.episodeNumber).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("集")) } }
                    SettingsChoicePicker(title: L10n.tr("单集类型"), selection: $model.episodeType, choices: ClientSettingsChoices.episodeTypes)
                    if let stamp = model.details?.base.publishedAt { LabeledContent(L10n.tr("原发布日期"), value: Date(timeIntervalSince1970: stamp / 1000).formatted()) }
                    Toggle(L10n.tr("更新发布日期"), isOn: $model.updatePublicationDate)
                    if model.updatePublicationDate { DatePicker(L10n.tr("发布日期"), selection: $model.publicationDate) }
                    Text(L10n.tr("简介")).font(.headline)
                    LeadingTextEditor(text: $model.description).frame(minHeight: 140)
                    if model.selectedMatch != nil { Text(L10n.tr("已从 RSS 填入匹配信息和音频来源；保存后才会更新服务器。")).font(.caption).foregroundStyle(.secondary) }
                }.formStyle(.grouped).tabItem { Text(L10n.tr("详细信息")) }.tag(0)
                VStack(alignment: .leading, spacing: 14) {
                    HStack { TextField(L10n.tr("RSS 中的单集标题"), text: $model.searchTitle); Button(L10n.tr("搜索")) { Task { await model.search() } }.disabled(!hasFeed || model.searchTitle.isEmpty) }
                    if !hasFeed { Text(L10n.tr("此播客没有 RSS 地址，请先在内容管理中设置订阅源。")).foregroundStyle(.secondary) }
                    List(model.matches) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(match.title).font(.headline)
                            if let date = match.pubDate { Text(date).font(.caption).foregroundStyle(.secondary) }
                            HStack { Text([match.season, match.episode, match.episodeType].compactMap { $0 }.joined(separator: " · ")).font(.caption); Spacer(); Button(L10n.tr("应用到表单")) { model.apply(match); tab = 0 } }
                        }.padding(.vertical, 6)
                    }
                }.padding(16).tabItem { Text(L10n.tr("匹配 RSS 单集")) }.tag(1)
            }.disabled(model.isBusy || model.details == nil)
            HStack { Spacer(); Button(L10n.tr("取消")) { dismiss() }; Button(L10n.tr("保存")) { Task { if await model.save() { await didSave(); dismiss() } } }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.details == nil || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(22).frame(width: 650, height: 650).textFieldStyle(.shelfLeading)
        .task { await model.load(store: store) }
        .onChange(of: store.partition) { _, _ in model.account.cancel(); dismiss() }
        .onDisappear { model.account.cancel() }
    }
}
