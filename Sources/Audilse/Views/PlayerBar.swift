import SwiftUI
import AudilseCore
import AudilsePlayback

struct PlayerBar: View {
    @Bindable var store: AppStore
    @State private var showChapters = false
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            if let player = store.activePlayer, let media = player.currentMedia {
                HStack(spacing: 20) {
                    nowPlaying(media)
                        .frame(width: 210, alignment: .leading)
                    VStack(spacing: 9) {
                        HStack(spacing: 22) {
                            Button {
                                let amount = store.playbackPreferences.jumpBackwardAmount
                                Task { await player.skip(by: -Double(amount)) }
                            } label: { PlaybackSkipLabel(forward: false, seconds: store.playbackPreferences.jumpBackwardAmount) }
                                .help(L10n.format("后退 %1$@ 秒", String(describing: store.playbackPreferences.jumpBackwardAmount))).accessibilityLabel(L10n.format("后退 %1$@ 秒", String(describing: store.playbackPreferences.jumpBackwardAmount)))
                            Button { player.togglePlayPause() } label: {
                                Group {
                                    if player.isBuffering { ProgressView().controlSize(.small) }
                                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .semibold)) }
                                }.frame(width: 39, height: 39).background(ShelfTheme.accent, in: Circle()).foregroundStyle(.white)
                            }.help(player.isPlaybackRequested ? L10n.tr("暂停") : L10n.tr("播放")).accessibilityIdentifier("player.toggle")
                            Button {
                                let amount = store.playbackPreferences.jumpForwardAmount
                                Task { await player.skip(by: Double(amount)) }
                            } label: { PlaybackSkipLabel(forward: true, seconds: store.playbackPreferences.jumpForwardAmount) }
                                .help(L10n.format("前进 %1$@ 秒", String(describing: store.playbackPreferences.jumpForwardAmount))).accessibilityLabel(L10n.format("前进 %1$@ 秒", String(describing: store.playbackPreferences.jumpForwardAmount)))
                        }.buttonStyle(.plain)
                        PlaybackProgressView(player: player, useChapterProgress: store.playbackPreferences.useChapterTrack)
                            .id(ObjectIdentifier(player))
                    }.frame(maxWidth: 480)
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        Menu {
                            Button(L10n.format("加快 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) { store.adjustPlaybackRate(1, for: player) }.disabled(!player.canAdjustRate(by: store.playbackPreferences.playbackRateIncrementDecrement))
                            Button(L10n.format("减慢 %1$@×", String(describing: store.playbackPreferences.playbackRateIncrementDecrement.formatted()))) { store.adjustPlaybackRate(-1, for: player) }.disabled(!player.canAdjustRate(by: -store.playbackPreferences.playbackRateIncrementDecrement))
                            Divider()
                            ForEach(PlaybackRatePolicy.presets.filter { $0 >= Double(player.minimumRate) && $0 <= Double(player.maximumRate) }, id: \.self) { rate in
                                Button("\(rate.formatted())×") { store.setPlaybackRate(rate, for: player) }
                            }
                        } label: { Text("\(Double(player.rate).formatted())×").font(.system(size: 11, weight: .semibold, design: .rounded)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 31).help(playbackRateRangeText(player))
                        Menu {
                            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in Button(L10n.format("%1$@ 分钟后停止", String(describing: minutes))) { player.setSleepTimer(minutes: minutes) } }
                            Button(L10n.tr("本章结束时停止")) { player.stopAtChapterEnd() }
                            Divider()
                            Button(L10n.tr("关闭定时")) { player.cancelSleepTimer() }
                        } label: { Image(systemName: player.sleepDeadline != nil || player.sleepAtChapterEnd ? "moon.fill" : "moon") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 17).help(L10n.tr("睡眠定时"))
                        Button { showChapters.toggle() } label: { Image(systemName: "list.bullet") }.help(L10n.tr("章节"))
                            .popover(isPresented: $showChapters) { chapters(player) }
                        if !store.publicSharing.isActive {
                        Button { showQueue.toggle() } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }.help(L10n.tr("待播队列"))
                            .popover(isPresented: $showQueue) { queue(player) }
                        }
                        Button { Task { await store.stopPlaybackAndSync() } } label: { Image(systemName: "stop.fill") }.help(L10n.tr(store.publicSharing.isActive ? "停止播放并保存位置" : "停止播放并同步收听记录")).accessibilityIdentifier("player.stop")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.vertical, 15)
                if let error = (player.errorDiagnostic ?? player.syncDiagnostic).map(L10n.diagnostic) {
                    HStack { Image(systemName: "exclamationmark.circle"); Text(error); Spacer() }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 10)
                } else if player.isRateLimited {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(playbackRateLimitText(player))
                        Spacer()
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.bottom, 10)
                }
            } else {
                HStack(spacing: 13) {
                    Image(systemName: "waveform").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary).frame(width: 42, height: 42)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("此刻，适合听点什么。")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text(L10n.tr("选择一本书，开始你的收听时光")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "gobackward.15").font(.system(size: 19)).foregroundStyle(.quaternary)
                    Image(systemName: "play.fill").font(.system(size: 17)).foregroundStyle(.tertiary).frame(width: 36, height: 36).background(.primary.opacity(0.035), in: Circle())
                    Image(systemName: "goforward.30").font(.system(size: 19)).foregroundStyle(.quaternary)
                    Spacer()
                    Text("AUDILSE").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(.quaternary)
                }.padding(.horizontal, 29).frame(height: 86)
            }
        }.background(.regularMaterial)
    }

    private func nowPlaying(_ media: PlaybackMedia) -> some View {
        HStack(spacing: 11) {
            if let item = store.items.first(where: { $0.id == media.itemID }) {
                CoverView(item: item, url: store.coverURL(item), client: store.client, accountKey: store.profile?.id.uuidString ?? "demo").frame(width: 48, height: 54)
            } else {
                Image(systemName: "headphones").frame(width: 48, height: 54).background(ShelfTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(media.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(store.activePlayer?.currentChapter?.title ?? media.author).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private func chapters(_ player: PlaybackController) -> some View {
        PlayerChaptersPopover(player: player) { showChapters = false }
            .id(ObjectIdentifier(player)).id(player.currentMedia?.id)
    }
    private func queue(_ player: PlaybackController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("接下来播放")).font(.headline).padding(.horizontal, 16).padding(.top, 16)
            if player.queue.isEmpty { Text(L10n.tr("队列为空，在书籍详情中添加内容。")).foregroundStyle(.secondary).padding() }
            List { ForEach(player.queue) { media in Text(media.title) }.onDelete { player.removeFromQueue(at: $0) } }
        }.frame(width: 320, height: 300)
    }
}

@MainActor func playbackRateLimitText(_ player: PlaybackController) -> String {
    L10n.format("此文件支持 %1$@–%2$@×，当前以 %3$@× 播放；默认速度仍为 %4$@×。",
                Double(player.minimumRate).formatted(), Double(player.maximumRate).formatted(),
                Double(player.rate).formatted(), Double(player.requestedRate).formatted())
}

@MainActor func playbackRateRangeText(_ player: PlaybackController) -> String {
    L10n.format("当前文件可用速度：%1$@–%2$@×", Double(player.minimumRate).formatted(), Double(player.maximumRate).formatted())
}

private struct PlayerChapterNavigation: Equatable {
    var page = 0
    var focusedIndex: Int?
    let revision = UUID()
}

private struct PlayerChaptersPopover: View {
    let player: PlaybackController
    let dismiss: () -> Void
    @State private var navigation = PlayerChapterNavigation()
    private let pageSize = 80

    var body: some View {
        let snapshot = player.chapters
        let mediaID = player.currentMedia?.id, sessionID = player.currentSessionID
        let pageCount = max(1, (snapshot.count + pageSize - 1) / pageSize)
        let page = min(max(0, navigation.page), pageCount - 1)
        let start = min(snapshot.count, page * pageSize)
        let end = min(snapshot.count, start + pageSize)
        let currentIndex = player.currentChapter.flatMap { snapshot.firstIndex(of: $0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.tr("章节")).font(.headline)
                Spacer()
                Button(L10n.tr("当前章节")) {
                    guard let currentIndex else { return }
                    navigation = .init(page: currentIndex / pageSize, focusedIndex: currentIndex)
                }.disabled(currentIndex == nil).font(.caption)
            }.padding(.horizontal, 16).padding(.top, 16)
            if snapshot.isEmpty { Text(L10n.tr("这本书没有章节信息")).foregroundStyle(.secondary).padding() }
            else {
                if pageCount > 1 {
                    HStack(spacing: 8) {
                        Text("\(start + 1)–\(end) / \(snapshot.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button { navigation = .init(page: page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0).help(L10n.tr("上一页章节")).accessibilityLabel(L10n.tr("上一页章节"))
                        Picker(L10n.tr("章节页码"), selection: Binding(get: { page }, set: { navigation = .init(page: $0) })) {
                            ForEach(0..<pageCount, id: \.self) { index in Text(L10n.format("第 %1$@ 页", String(describing: index + 1))).tag(index) }
                        }.labelsHidden().frame(width: 90).accessibilityLabel(L10n.tr("章节页码"))
                        Button { navigation = .init(page: page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page == pageCount - 1).help(L10n.tr("下一页章节")).accessibilityLabel(L10n.tr("下一页章节"))
                    }.controlSize(.small).padding(.horizontal, 16)
                }
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 1).id("player.chapters.top").accessibilityHidden(true)
                            ForEach(start..<end, id: \.self) { index in
                                let chapter = snapshot[index]
                                Button {
                                    Task {
                                        guard player.currentMedia?.id == mediaID, player.currentSessionID == sessionID else { return }
                                        await player.playChapter(chapter)
                                    }
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing)
                                        Text(chapter.title).lineLimit(1)
                                        Spacer()
                                        Text(chapter.start.shelfTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }.padding(12).contentShape(Rectangle())
                                        .background(currentIndex == index ? ShelfTheme.accent.opacity(0.08) : .clear)
                                }.buttonStyle(.plain).id(index)
                            }
                        }
                    }
                    .onChange(of: navigation) { _, value in
                        if let index = value.focusedIndex, (start..<end).contains(index) { scrollProxy.scrollTo(index, anchor: .center) }
                        else { scrollProxy.scrollTo("player.chapters.top", anchor: .top) }
                    }
                }
            }
        }.frame(width: 380, height: 390)
        .onAppear {
            if let currentIndex { navigation = .init(page: currentIndex / pageSize, focusedIndex: currentIndex) }
        }
        .onChange(of: snapshot.count) { _, _ in navigation = .init(page: min(navigation.page, pageCount - 1)) }
    }
}
