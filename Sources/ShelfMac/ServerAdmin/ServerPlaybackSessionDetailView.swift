import SwiftUI
import ShelfCore

struct ServerPlaybackSessionDetailView: View {
    let session: AdminPlaybackSession
    let kind: AdminPlaybackSessionKind
    let canDelete: Bool
    let canClose: Bool
    let administratorCloseSupported: Bool
    let busy: Bool
    let back: () -> Void
    let play: () -> Void
    let delete: () -> Void
    let close: () -> Void

    private var canPlay: Bool { session.libraryItemId?.isEmpty == false && session.currentTime.map { $0.isFinite && $0 >= 0 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(action: back) { Label(L10n.tr("返回会话列表"), systemImage: "chevron.left") }
                Spacer(); Text(L10n.tr("收听会话详情")).font(.title3.bold())
            }
            switch kind {
            case .history:
                Label(L10n.tr("收听历史"), systemImage: "clock.arrow.circlepath")
                    .font(.headline).foregroundStyle(.secondary)
            case .open:
                Label(L10n.tr("活动会话"), systemImage: "headphones")
                    .font(.headline).foregroundStyle(.secondary)
            case .share:
                Label(L10n.tr("分享会话"), systemImage: "link")
                    .font(.headline).foregroundStyle(.secondary)
            }
            Text(session.displayTitle ?? L10n.tr("已删除的内容")).font(.title2.bold()).textSelection(.enabled)
            if let author = session.displayAuthor { Text(author).foregroundStyle(.secondary) }
            if kind == .share || session.mediaPlayer == "web-share" {
                Label(L10n.tr("分享会话仅供查看，不能删除或关闭。"), systemImage: "link").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(action: play) { Label(L10n.tr("在此 Mac 从此位置播放"), systemImage: "play.fill") }.disabled(!canPlay || busy)
                if kind == .history, session.mediaPlayer != "web-share" {
                    Button(L10n.tr("删除记录"), role: .destructive, action: delete).disabled(!canDelete || busy)
                }
                if kind == .open, session.mediaPlayer != "web-share" {
                    Button(L10n.tr("关闭活动会话"), role: .destructive, action: close).disabled(!canClose || busy)
                }
            }
            if kind == .open, !canClose, !administratorCloseSupported {
                Text(L10n.tr("此服务器仅允许关闭当前账户自己的会话；关闭他人会话需要已核验的 2.36.1 或更高版本。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox(L10n.tr("播放信息")) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    row("会话标识", session.id)
                    if kind != .share { row("用户", session.user?.username ?? session.userId) }
                    row("开始时间", playbackSessionDate(session.startedAt ?? session.createdAt))
                    row("更新时间", playbackSessionDate(session.updatedAt))
                    row("收听时长", playbackSessionTime(session.timeListening))
                    row("起始位置", playbackSessionTime(session.startTime))
                    row("当前位置", playbackSessionTime(session.currentTime))
                    row("总时长", playbackSessionTime(session.duration))
                    row("播放方式", playbackSessionMethod(session.playMethod))
                    row("播放器", session.mediaPlayer)
                    row("书库标识", session.libraryId)
                    row("内容标识", session.libraryItemId)
                    row("单集标识", session.episodeId)
                    row("媒体类型", session.mediaType)
                    row("服务器版本", session.serverVersion)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            GroupBox(L10n.tr("设备信息")) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    row("客户端", session.deviceInfo?.clientName)
                    row("客户端版本", session.deviceInfo?.clientVersion)
                    row("设备名称", session.deviceInfo?.deviceName)
                    row("IP 地址", session.deviceInfo?.ipAddress)
                    row("操作系统", joined(session.deviceInfo?.osName, session.deviceInfo?.osVersion))
                    row("浏览器", joined(session.deviceInfo?.browserName, session.deviceInfo?.browserVersion))
                    row("制造商", session.deviceInfo?.manufacturer)
                    row("设备型号", session.deviceInfo?.model)
                    row("SDK 版本", session.deviceInfo?.sdkVersion)
                    row("设备类型", session.deviceInfo?.deviceType)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ key: String, _ value: String?) -> some View {
        GridRow { Text(L10n.tr(key)).foregroundStyle(.secondary); Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func joined(_ first: String?, _ second: String?) -> String? {
        let value = [first, second].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return value.isEmpty ? nil : value
    }
}

func playbackSessionDate(_ value: Double?) -> String {
    guard let value, value.isFinite, abs(value) < 8_000_000_000_000_000 else { return "—" }
    return Date(timeIntervalSince1970: value / 1_000).formatted(date: .abbreviated, time: .shortened)
}
func playbackSessionTime(_ value: Double?) -> String {
    guard let value, value.isFinite, value >= 0, value < 1_000_000_000_000 else { return "—" }
    let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .positional; formatter.zeroFormattingBehavior = .pad
    return formatter.string(from: value) ?? "—"
}
func playbackSessionMethod(_ value: Int?) -> String {
    switch value { case 0: L10n.tr("直接播放"); case 1: L10n.tr("直接流式播放"); case 2: L10n.tr("转码播放"); case 3: L10n.tr("本机播放"); default: L10n.tr("未知播放方式") }
}
