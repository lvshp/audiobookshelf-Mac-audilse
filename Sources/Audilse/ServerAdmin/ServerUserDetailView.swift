import AppKit
import ImageIO
import SwiftUI
import AudilseCore

struct ServerUserDetailView: View {
    let store: AppStore
    let source: ServerUserDetailSource
    @State private var model = ServerUserDetailModel()
    @State private var statisticsRefresh = UUID()
    @State private var playbackModel: ServerPlaybackSessionsModel
    @State private var progressRefresh = UUID()
    @State private var progressPage = 0
    @Environment(\.dismiss) private var dismiss
    private struct Request: Hashable { let source: ServerUserDetailSource; var page = 0; let refresh: UUID }
    private var bound: Bool { model.isBound(to: store, source: source) }
    private var progressPages: Int { max(1, ((model.savedProgress?.count ?? 0) + 19) / 20) }

    init(store: AppStore, source: ServerUserDetailSource) {
        self.store = store; self.source = source
        _playbackModel = State(initialValue: ServerPlaybackSessionsModel(targetUserID: source.userID))
    }

    var body: some View {
        let statisticsRequest = Request(source: source, refresh: statisticsRefresh)
        let progressRequest = Request(source: source, refresh: progressRefresh)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("用户收听详情")).font(.title2.bold())
                    Text(bound ? (model.user?.username ?? source.userID) : source.userID).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); SheetCloseButton(identifier: "admin-user-detail.close") { dismiss() }
            }.padding(20)
            Divider()
            if !source.isCurrent(store: store) {
                ContentUnavailableView(L10n.tr("用户收听详情"), systemImage: "person.crop.circle.badge.exclamationmark", description: Text(L10n.tr("账户或权限已变化，请关闭后重新打开。")))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(L10n.tr("查看此用户的服务器记录，不会修改其进度。")).font(.callout).foregroundStyle(.secondary)
                        statisticsSection
                        historySection
                        progressSection
                    }.padding(24)
                }
            }
        }.frame(minWidth: 760, idealWidth: 880, minHeight: 650, idealHeight: 800)
        .task(id: statisticsRequest) { await model.loadStatistics(store: store, source: statisticsRequest.source) }
        .task(id: progressRequest) { await model.loadProgress(store: store, source: progressRequest.source) }
        .onChange(of: source) { _, _ in progressPage = 0 }
        .onChange(of: model.savedProgress?.count) { _, _ in progressPage = min(progressPage, progressPages - 1) }
        .onDisappear { model.cancel(); playbackModel.cancel() }
    }

    private var statisticsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(L10n.tr("收听统计"), loading: bound && model.isStatisticsLoading) { statisticsRefresh = UUID() }
                if bound {
                    if let error = model.statisticsError { errorMessage(error) }
                    if let stats = model.statistics {
                        HStack(spacing: 18) {
                            metric(L10n.tr("总收听时长"), value: serverUserTime(stats.totalTime))
                            metric(L10n.tr("今日收听"), value: serverUserTime(stats.today))
                            metric(L10n.tr("收听次数"), value: playbackModel.history.map { String($0.total) } ?? "—")
                        }
                        if let latest = stats.recentSessions.first {
                            Divider(); Text(L10n.tr("最近收听")).font(.caption).foregroundStyle(.secondary)
                            Text(latest.displayTitle).font(.headline).lineLimit(2)
                            Text(serverUserDate(latest.updatedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !model.isStatisticsLoading && model.statisticsError == nil { Text(L10n.tr("尚无收听统计。")).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private var historySection: some View {
        ServerPlaybackSessionsView(store: store, model: playbackModel, embedded: true)
    }
    private var progressSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(L10n.tr("已保存进度"), loading: bound && model.isProgressLoading) { progressRefresh = UUID() }
                if bound {
                    if let error = model.progressError { errorMessage(error) }
                    if let rows = model.savedProgress {
                        if rows.isEmpty { Text(L10n.tr("尚无已保存的媒体进度。")).foregroundStyle(.secondary) }
                        ForEach(Array(rows.dropFirst(progressPage * 20).prefix(20))) { row in
                            HStack(alignment: .top, spacing: 12) {
                                ServerUserProgressCover(store: store, source: source, row: row)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.displayTitle ?? L10n.tr("已删除的内容")).font(.headline).lineLimit(2)
                                    if let subtitle = row.displaySubtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                    HStack(spacing: 12) {
                                        Text(row.isFinished ? L10n.tr("已完成") : serverUserPercent(row.progress))
                                        Text(L10n.format("位置 %1$@", serverUserTime(row.currentTime)))
                                        if let ebook = row.ebookProgress { Text(L10n.format("阅读 %1$@", serverUserPercent(ebook))) }
                                    }.font(.caption).monospacedDigit()
                                    Text(L10n.format("开始 %1$@ · 更新 %2$@", serverUserDate(row.startedAt), serverUserDate(row.lastUpdate))).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Divider()
                        }
                        if rows.count > 20 { pager(page: progressPage, pages: progressPages, disabled: false) { progressPage -= 1 } next: { progressPage += 1 } }
                    } else if model.user != nil && !model.isProgressLoading { Text(L10n.tr("服务器未返回此用户的保存进度。")).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private func sectionHeader(_ title: String, loading: Bool, refresh: @escaping () -> Void) -> some View {
        HStack { Text(title).font(.title3.bold()); Spacer(); if loading { ProgressView().controlSize(.small) }; Button(action: refresh) { Image(systemName: "arrow.clockwise") }.disabled(loading).help(L10n.tr("重新载入")).accessibilityLabel(L10n.tr("重新载入")) }
    }
    private func errorMessage(_ error: String) -> some View { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
    private func metric(_ title: String, value: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.bold()).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
    private func pager(page: Int, pages: Int, disabled: Bool, previous: @escaping () -> Void, next: @escaping () -> Void) -> some View {
        HStack {
            Spacer(); Button(action: previous) { Image(systemName: "chevron.left") }.disabled(disabled || page <= 0).accessibilityLabel(L10n.tr("上一页"))
            Text(L10n.format("第 %1$@ / %2$@ 页", String(page + 1), String(pages))).font(.caption).monospacedDigit()
            Button(action: next) { Image(systemName: "chevron.right") }.disabled(disabled || page + 1 >= pages).accessibilityLabel(L10n.tr("下一页"))
        }
    }
    private func playMethod(_ value: Int?) -> String {
        switch value { case 0: L10n.tr("直接播放"); case 1: L10n.tr("直接流式播放"); case 2: L10n.tr("转码播放"); case 3: L10n.tr("本机播放"); default: L10n.tr("未知播放方式") }
    }
    private func deviceDescription(_ device: AdminSessionDeviceInfo) -> String {
        [device.clientName, device.clientVersion, device.model, device.browserName, device.browserVersion, device.osName, device.osVersion].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct ServerUserProgressCover: View {
    let store: AppStore
    let source: ServerUserDetailSource
    let row: AdminUserProgress
    @State private var image: NSImage?
    private struct Key: Hashable { let source: ServerUserDetailSource; let itemID: String?; let updatedAt: Double? }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: row.episodeId == nil ? "book.closed" : "mic").font(.title3).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.frame(width: 42, height: 54).clipShape(RoundedRectangle(cornerRadius: 5)).accessibilityHidden(true)
        .task(id: Key(source: source, itemID: row.libraryItemId, updatedAt: row.mediaUpdatedAt)) {
            guard !Task.isCancelled, source.isCurrent(store: store) else { return }
            image = nil
            guard row.coverPath != nil,
                  let id = row.libraryItemId?.addingPercentEncoding(withAllowedCharacters: .alphanumerics), !id.isEmpty else { return }
            let path = "api/items/\(id)/cover?width=100&height=140" + (row.mediaUpdatedAt.map { "&ts=\($0)" } ?? "")
            guard let data = try? await source.client.requestData(path: path), data.count < 12 * 1024 * 1024,
                  !Task.isCancelled, source.isCurrent(store: store),
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 180] as CFDictionary) else { return }
            image = NSImage(cgImage: thumbnail, size: .zero)
        }
    }
}

private func serverUserPercent(_ value: Double) -> String { (value.isFinite ? min(1, max(0, value)) : 0).formatted(.percent.precision(.fractionLength(0))) }
private func serverUserDate(_ value: Double?) -> String {
    guard let value, value.isFinite, abs(value) < 8_000_000_000_000_000 else { return L10n.tr("未知") }
    return Date(timeIntervalSince1970: value / 1_000).formatted(date: .abbreviated, time: .shortened)
}
private func serverUserTime(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0, value < 1_000_000_000_000 else { return "—" }
    let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute, .second]; formatter.unitsStyle = .positional; formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: value) ?? "—"
}
