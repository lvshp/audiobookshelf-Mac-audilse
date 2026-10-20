import SwiftUI
import AudilseCore
import ImageIO
import CryptoKit

enum ShelfTheme {
    static let accent = Color(red: 0.22, green: 0.40, blue: 0.91)
    static let quiet = Color.secondary
    static let corner: CGFloat = 14
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: L10n.tr("跟随系统"); case .light: L10n.tr("浅色"); case .dark: L10n.tr("深色") } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

enum ShelfRoute: Hashable {
    case home, library(String), downloads, feature(FeatureKind)
    var title: String {
        switch self { case .home: L10n.tr("现在收听"); case .library: L10n.tr("书库"); case .downloads: L10n.tr("下载"); case .feature(let kind): kind.title }
    }
}

enum FeatureKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case authors, series, collections, playlists, history, statistics
    var id: String { rawValue }
    var title: String { switch self { case .authors: L10n.tr("作者"); case .series: L10n.tr("系列"); case .collections: L10n.tr("集合"); case .playlists: L10n.tr("播放列表"); case .history: L10n.tr("收听历史"); case .statistics: L10n.tr("收听统计") } }
    var symbol: String { switch self { case .authors: "person.2"; case .series: "books.vertical"; case .collections: "square.stack"; case .playlists: "music.note.list"; case .history: "clock.arrow.circlepath"; case .statistics: "chart.bar.xaxis" } }
}

struct CoverView: View {
    var item: AudilseCore.LibraryItem
    var url: URL?
    var client: ABSClient? = nil
    var accountKey = "demo"
    var showTitle = true
    @State private var artwork: NSImage?

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.13, green: 0.24, blue: 0.25), Color(red: 0.34, green: 0.46, blue: 0.38)],
            [Color(red: 0.71, green: 0.36, blue: 0.27), Color(red: 0.88, green: 0.66, blue: 0.45)],
            [Color(red: 0.18, green: 0.23, blue: 0.41), Color(red: 0.40, green: 0.46, blue: 0.66)],
            [Color(red: 0.73, green: 0.63, blue: 0.45), Color(red: 0.88, green: 0.82, blue: 0.64)],
            [Color(red: 0.28, green: 0.36, blue: 0.48), Color(red: 0.49, green: 0.61, blue: 0.68)],
            [Color(red: 0.37, green: 0.21, blue: 0.29), Color(red: 0.65, green: 0.41, blue: 0.45)]
        ]
        let index = item.id.utf8.reduce(0) { ($0 &+ Int($1)) % palettes.count }
        return palettes[index]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(.white.opacity(0.15), lineWidth: 1)
                    .frame(width: geometry.size.width * 1.15)
                    .offset(x: geometry.size.width * 0.25, y: geometry.size.height * 0.25)
                Circle().fill(.black.opacity(0.08))
                    .frame(width: geometry.size.width * 0.85)
                    .offset(x: -geometry.size.width * 0.35, y: geometry.size.height * 0.35)
                if showTitle {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform").font(.system(size: max(9, geometry.size.width * 0.06)))
                            Text("SHELF LIBRARY").font(.system(size: max(7, geometry.size.width * 0.045), weight: .medium, design: .rounded)).tracking(1.8)
                        }.opacity(0.75)
                        Spacer(minLength: 10)
                        Text(item.title)
                            .font(.system(size: min(32, max(14, geometry.size.width * 0.15)), weight: .medium, design: .serif))
                            .lineLimit(3).minimumScaleFactor(0.6)
                        Rectangle().fill(.white.opacity(0.55)).frame(width: 30, height: 1)
                        Text(item.authorName).font(.system(size: max(9, geometry.size.width * 0.06))).lineLimit(1).opacity(0.8)
                        Spacer(minLength: 0)
                    }.padding(geometry.size.width * 0.12).foregroundStyle(.white)
                }
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(L10n.format("%1$@ 封面", String(describing: item.title)))
        .task(id: accountKey + "|" + (url?.absoluteString ?? "")) {
            artwork = nil
            guard let url else { return }
            let key = accountKey + "|" + url.absoluteString
            if let cached = CoverArtworkCache.shared.images.object(forKey: key as NSString) { artwork = cached; return }
            guard let data = await CoverDataCache.shared.load(key: key, url: url, client: client), !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            let image = NSImage(cgImage: cg, size: .zero)
            CoverArtworkCache.shared.images.setObject(image, forKey: key as NSString, cost: cg.width * cg.height * 4)
            artwork = image
        }
    }
}

@MainActor private final class CoverArtworkCache {
    static let shared = CoverArtworkCache()
    let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200; cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
}

actor CoverDataCache {
    static let shared = CoverDataCache()
    private var tasks: [String: Task<Data?, Never>] = [:]
    func load(key: String, url: URL, client: ABSClient?) async -> Data? {
        if let task = tasks[key] { return await task.value }
        let task = Task<Data?, Never> {
            guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Audilse/Covers", isDirectory: true) else { return nil }
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent(hash)
            if let cached = try? Data(contentsOf: file), !cached.isEmpty { return cached }
            guard let client, let data = try? await client.requestData(path: url.absoluteString), data.count < 12 * 1024 * 1024 else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        tasks[key] = task
        let result = await task.value
        tasks.removeValue(forKey: key)
        return result
    }
}

struct SectionHeading: View {
    var title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 22, weight: .bold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle).font(.callout).foregroundStyle(ShelfTheme.accent) }
                    .buttonStyle(.plain)
            }
        }
    }
}

struct QuietEmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(ShelfTheme.accent.opacity(0.7))
                .frame(width: 88, height: 88).background(ShelfTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(50).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Double {
    var shelfTime: String {
        let seconds = max(0, Int(isFinite ? self : 0))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var shelfDuration: String {
        if isFinite, self > 0, self < 60 {
            return L10n.format("%1$@ 秒", String(max(1, Int(self))))
        }
        let minutes = max(0, Int(isFinite ? self / 60 : 0))
        return minutes >= 60 ? L10n.format("%1$@ 小时 %2$@ 分钟", String(describing: minutes / 60), String(describing: minutes % 60)) : L10n.format("%1$@ 分钟", String(describing: minutes))
    }
}
