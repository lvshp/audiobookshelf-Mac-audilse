import AppKit
import SwiftUI
import ShelfCore
import ShelfPlayback

struct MenuBarPlayerView: View {
    @Bindable var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Audisle", systemImage: "headphones").font(.headline)
                Spacer()
                if store.activePlayer?.isBuffering == true { ProgressView().controlSize(.small) }
            }
            if let player = store.activePlayer, let media = player.currentMedia {
                VStack(alignment: .leading, spacing: 5) {
                    Text(media.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(player.currentChapter?.title ?? media.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(progressText(player))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 20) {
                    Button {
                        let amount = store.playbackPreferences.jumpBackwardAmount
                        Task { await player.skip(by: -Double(amount)) }
                    } label: { PlaybackSkipLabel(forward: false, seconds: store.playbackPreferences.jumpBackwardAmount) }
                        .help(L10n.format("后退 %1$@ 秒", String(describing: store.playbackPreferences.jumpBackwardAmount))).accessibilityLabel(L10n.format("后退 %1$@ 秒", String(describing: store.playbackPreferences.jumpBackwardAmount)))
                    Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaybackRequested ? "pause.fill" : "play.fill") }
                        .help(player.isPlaybackRequested ? L10n.tr("暂停") : L10n.tr("播放")).accessibilityLabel(player.isPlaybackRequested ? L10n.tr("暂停") : L10n.tr("播放"))
                        .accessibilityIdentifier("menubar.toggle")
                    Button {
                        let amount = store.playbackPreferences.jumpForwardAmount
                        Task { await player.skip(by: Double(amount)) }
                    } label: { PlaybackSkipLabel(forward: true, seconds: store.playbackPreferences.jumpForwardAmount) }
                        .help(L10n.format("前进 %1$@ 秒", String(describing: store.playbackPreferences.jumpForwardAmount))).accessibilityLabel(L10n.format("前进 %1$@ 秒", String(describing: store.playbackPreferences.jumpForwardAmount)))
                    Spacer()
                    Menu("\(Double(player.rate).formatted())×") {
                        Button(L10n.format("加快 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) { store.adjustPlaybackRate(1, for: player) }.disabled(!player.canAdjustRate(by: store.playbackPreferences.playbackRateIncrementDecrement))
                        Button(L10n.format("减慢 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) { store.adjustPlaybackRate(-1, for: player) }.disabled(!player.canAdjustRate(by: -store.playbackPreferences.playbackRateIncrementDecrement))
                        Divider()
                        ForEach(PlaybackRatePolicy.presets.filter { $0 >= Double(player.minimumRate) && $0 <= Double(player.maximumRate) }, id: \.self) { rate in
                            Button("\(rate.formatted())×") { store.setPlaybackRate(rate, for: player) }
                        }
                    }.fixedSize().help(playbackRateRangeText(player))
                }.buttonStyle(.borderless).font(.system(size: 18))
                Button(L10n.tr(store.publicSharing.isActive ? "停止播放并保存位置" : "停止播放并同步")) { Task { await store.stopPlaybackAndSync() } }
                if let error = (player.errorDiagnostic ?? player.syncDiagnostic).map(L10n.diagnostic) {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                } else if player.isRateLimited {
                    Label(playbackRateLimitText(player), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L10n.tr("选择一本书，开始收听。 "))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let error = store.activePlayer?.errorDiagnostic.map(L10n.diagnostic) {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
            Divider()
            Button(L10n.tr("打开公开分享…")) {
                openWindow(id: "public-share")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderless)
            HStack {
                Button(L10n.tr("打开 ShelfMac")) {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }.accessibilityIdentifier("menubar.open")
                Spacer()
                Button(L10n.tr("退出")) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }.buttonStyle(.borderless)
        }.padding(18).frame(width: 310)
    }
    private func progressText(_ player: PlaybackController) -> String {
        if store.playbackPreferences.useChapterTrack, let chapter = player.currentChapter,
           chapter.start.isFinite, chapter.end.isFinite {
            let start = min(player.duration, max(0, chapter.start)), end = min(player.duration, chapter.end)
            if end > start { return L10n.format("本章 %1$@ / %2$@", String(describing: min(end - start, max(0, player.position - start)).shelfTime), String(describing: (end - start).shelfTime)) }
        }
        return "\(player.position.shelfTime) / \(player.duration.shelfTime)"
    }
}
