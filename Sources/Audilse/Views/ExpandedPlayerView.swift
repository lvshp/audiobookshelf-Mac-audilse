import SwiftUI
import ImageIO
import AudilseCore
import AudilsePlayback

/// A detail-column presentation of the existing player, not a new playback session.
struct ExpandedPlayerView: View {
    @Bindable var store: AppStore
    let player: PlaybackController
    let media: PlaybackMedia
    let onCollapse: () -> Void
    let onToggleSidebar: () -> Void
    @State private var artwork: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let coverSize = min(360, max(160, min(geometry.size.width - 80, geometry.size.height * 0.43)))
            VStack(spacing: 0) {
                HStack {
                    Button(action: onToggleSidebar) { Image(systemName: "sidebar.left") }
                        .help(L10n.tr("切换侧边栏")).accessibilityLabel(L10n.tr("切换侧边栏"))
                        .accessibilityIdentifier("player.sidebar")
                    Spacer()
                    Text(L10n.tr("现在收听")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onCollapse) { Image(systemName: "chevron.down") }
                        .help(L10n.tr("收起播放页")).accessibilityLabel(L10n.tr("收起播放页"))
                        .accessibilityIdentifier("player.collapse")
                }.buttonStyle(.plain).font(.title3).padding(24)
                ScrollView {
                    VStack(spacing: 24) {
                        cover.frame(width: coverSize, height: coverSize)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
                            .accessibilityLabel(L10n.format("%1$@ 封面", media.title))
                        VStack(spacing: 10) {
                            Text(media.title).font(.system(size: 26, weight: .semibold)).textSelection(.enabled)
                            if !media.author.isEmpty { Text(media.author).foregroundStyle(.secondary) }
                            if let chapter = player.currentChapter {
                                Text(chapter.title).font(.callout).foregroundStyle(.secondary)
                            }
                        }.multilineTextAlignment(.center).frame(maxWidth: 640).padding(.horizontal, 28)
                        PlayerBar(store: store, expanded: true)
                            .frame(maxWidth: 640)
                    }.padding(.top, 16).padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - 76))
                }
            }
        }
        .background {
            LinearGradient(colors: [ShelfTheme.accent.opacity(0.1), ShelfTheme.canvas], startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(ShelfTheme.canvas)
        }
        .onExitCommand(perform: onCollapse)
        .task(id: (store.profile?.id.uuidString ?? "public") + "|" + media.id + "|" + (media.coverURL?.absoluteString ?? "")) {
            artwork = nil
            guard let url = media.coverURL else { return }
            let key = (store.profile?.id.uuidString ?? "public") + "|" + url.absoluteString
            guard let data = await CoverDataCache.shared.load(key: key, url: url, client: store.client),
                  !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 900,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return }
            artwork = NSImage(cgImage: image, size: .zero)
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(ShelfTheme.accent.opacity(0.12))
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "headphones").font(.system(size: 72, weight: .ultraLight))
                    .foregroundStyle(ShelfTheme.accent)
            }
        }
    }
}
