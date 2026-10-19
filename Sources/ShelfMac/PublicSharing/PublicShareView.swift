import AppKit
import ImageIO
import ShelfCore
import ShelfPlayback
import SwiftUI

struct PublicShareView: View {
    @Bindable var store: AppStore
    @State private var linkText = ""
    @State private var chapterPage = 0
    @State private var coverImage: NSImage?
    @State private var exporter = PublicShareExportCoordinator()
    private var sharing: PublicShareCoordinator { store.publicSharing }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Label(L10n.tr("公开分享"), systemImage: "link").font(.title2.bold())
                Text(L10n.tr("粘贴 Audiobookshelf 分享链接，无需登录即可播放。"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("https://…/share/…", text: $linkText)
                    .accessibilityLabel(L10n.tr("分享链接"))
                    .onSubmit { open() }
                Button(L10n.tr("打开分享")) { open() }
                    .buttonStyle(.borderedProminent)
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sharing.isOpening || sharing.isTransitioning || store.isConnecting || store.recoveryBusy)
            }
            if sharing.isOpening {
                HStack { ProgressView().controlSize(.small); Text(L10n.tr("正在打开分享…")); Spacer(); Button(L10n.tr("取消")) { sharing.cancelOpening() } }
            }
            if let issue = sharing.diagnostic {
                Text(L10n.diagnostic(issue)).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let snapshot = sharing.snapshot, let player = sharing.player {
                HStack(alignment: .top, spacing: 22) {
                    Group {
                        if let coverImage { Image(nsImage: coverImage).resizable().scaledToFit() }
                        else { Image(systemName: "headphones").font(.system(size: 40)).foregroundStyle(ShelfTheme.accent) }
                    }.frame(width: 130, height: 160)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(snapshot.title).font(.title.bold()).lineLimit(3)
                        Text(snapshot.author).foregroundStyle(.secondary)
                        controls(player)
                        PlaybackProgressView(player: player, useChapterProgress: false)
                        Text(L10n.tr("播放位置单独保存在本机，不计入已登录账户的收听记录。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let issue = (player.errorDiagnostic ?? player.syncDiagnostic) {
                    Text(L10n.diagnostic(issue)).font(.caption).foregroundStyle(.orange)
                }
                if snapshot.isDownloadable {
                    HStack {
                        if exporter.isBusy {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("正在准备分享文件…"))
                            Button(L10n.tr("取消")) { exporter.cancel() }
                        } else {
                            Button(L10n.tr("保存分享文件"), systemImage: "square.and.arrow.down") { exporter.start(from: sharing) }
                            if exporter.saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        Spacer()
                    }
                }
                chapters(snapshot, player: player)
            } else if !sharing.isOpening {
                ContentUnavailableView(L10n.tr("打开一段分享的故事"), systemImage: "headphones",
                                       description: Text(L10n.tr("分享的发布和撤销仍由服务器管理。")))
            }
            if let error = exporter.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }
        .padding(26).frame(minWidth: 690, minHeight: 540)
        .onAppear {
            if linkText.isEmpty { linkText = sharing.link?.absoluteString ?? "" }
            updateCover(sharing.coverData)
        }
        .onChange(of: sharing.coverData) { _, data in updateCover(data) }
        .onChange(of: sharing.identity) { _, _ in chapterPage = 0; exporter.reset() }
        .onDisappear { exporter.cancel(); if sharing.isOpening { sharing.cancelOpening() } }
    }

    private func open() {
        guard !sharing.isOpening, !sharing.isTransitioning else { return }
        exporter.cancel()
        let value = linkText
        Task { await store.openPublicShare(value) }
    }

    private func controls(_ player: PlaybackController) -> some View {
        HStack(spacing: 18) {
            Button { Task { await player.skip(by: -Double(store.playbackPreferences.jumpBackwardAmount)) } } label: {
                PlaybackSkipLabel(forward: false, seconds: store.playbackPreferences.jumpBackwardAmount)
            }
                .help(L10n.format("后退 %1$@ 秒", String(store.playbackPreferences.jumpBackwardAmount)))
            Button { player.togglePlayPause() } label: {
                if player.isBuffering { ProgressView().controlSize(.small) }
                else { Image(systemName: player.isPlaybackRequested ? "pause.fill" : "play.fill") }
            }.frame(width: 38, height: 38).buttonStyle(.borderedProminent)
                .accessibilityLabel(player.isPlaybackRequested ? L10n.tr("暂停") : L10n.tr("播放"))
            Button { Task { await player.skip(by: Double(store.playbackPreferences.jumpForwardAmount)) } } label: {
                PlaybackSkipLabel(forward: true, seconds: store.playbackPreferences.jumpForwardAmount)
            }
                .help(L10n.format("前进 %1$@ 秒", String(store.playbackPreferences.jumpForwardAmount)))
            Menu("\(Double(player.rate).formatted())×") {
                ForEach(PlaybackRatePolicy.presets.filter { $0 >= Double(player.minimumRate) && $0 <= Double(player.maximumRate) }, id: \.self) { rate in
                    Button("\(rate.formatted())×") { sharing.setRate(rate, for: player) }
                }
            }.fixedSize()
            Spacer()
            Button(L10n.tr("停止播放")) { Task { await store.stopPlaybackAndSync() } }
        }.disabled(sharing.isTransitioning || store.isConnecting)
    }

    private func chapters(_ snapshot: PublicShareSnapshot, player: PlaybackController) -> some View {
        let count = snapshot.chapters.count
        let pages = max(1, (count + 79) / 80)
        let page = min(chapterPage, pages - 1)
        let start = min(count, page * 80), end = min(count, page * 80 + 80)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("章节")).font(.headline)
                Spacer()
                if pages > 1 {
                    Button(L10n.tr("上一页")) { chapterPage = max(0, page - 1) }.disabled(page == 0)
                    Text("\(page + 1) / \(pages)").monospacedDigit()
                    Button(L10n.tr("下一页")) { chapterPage = min(pages - 1, page + 1) }.disabled(page + 1 >= pages)
                }
            }
            if count == 0 { Text(L10n.tr("此分享没有章节信息")).foregroundStyle(.secondary) }
            else {
                List {
                    ForEach(start..<end, id: \.self) { index in
                        let chapter = snapshot.chapters[index]
                        Button { Task { await player.seek(to: chapter.start) } } label: {
                            HStack { Text(chapter.title); Spacer(); Text(chapter.start.shelfTime).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                }.listStyle(.inset).frame(minHeight: 150)
            }
        }
    }

    private func updateCover(_ data: Data?) {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { coverImage = nil; return }
        coverImage = NSImage(cgImage: image, size: .zero)
    }
}
