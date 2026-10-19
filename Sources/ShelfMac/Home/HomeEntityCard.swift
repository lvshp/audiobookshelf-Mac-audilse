import SwiftUI
import ShelfCore
import ImageIO
import CryptoKit

struct HomeEntityCard: View {
    let store: AppStore
    let shelf: PersonalizedLibraryShelf
    let entity: PersonalizedShelfEntity
    let model: HomeModel
    let actions: HomeActions
    let source: HomeSource
    let continuation: ContinueListeningModel?
    private var enabled: Bool { model.isBound(to: store, libraryID: source.libraryID) && source.isCurrent(store) && !actions.isWorking }

    var body: some View {
        Group {
            switch entity {
            case .item(let entry):
                HomeItemCard(store: store, shelf: shelf, entry: entry, model: model, actions: actions, source: source, enabled: enabled, continuation: continuation)
            case .series(let series):
                VStack(alignment: .leading, spacing: 9) {
                    Button { actions.start(.series(series), store: store, source: source) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(ShelfTheme.accent.opacity(0.08))
                            HStack(spacing: -35) {
                                ForEach(Array(series.books.prefix(3).enumerated()), id: \.offset) { index, book in
                                    let cover = source.isCurrent(store) ? source.coverSource.request(item: book, store: store) : nil
                                    CoverView(item: book, url: cover?.url, client: cover?.client,
                                              accountKey: cover?.accountKey ?? "none")
                                        .frame(width: 90, height: 128).rotationEffect(.degrees(Double(index - 1) * 7))
                                        .shadow(color: .black.opacity(0.12), radius: 4, y: 3)
                                }
                                if series.books.isEmpty { Image(systemName: "books.vertical").font(.system(size: 44, weight: .light)).foregroundStyle(ShelfTheme.accent) }
                            }
                        }.frame(height: 195)
                    }.buttonStyle(.plain).accessibilityLabel(series.name)
                    Text(series.name).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
                    Text(L10n.format("%1$@ 本书", String(series.books.count))).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.tr("查看系列"), systemImage: "arrow.up.right") { actions.start(.series(series), store: store, source: source) }
                            .buttonStyle(.borderless).font(.caption)
                        Spacer(minLength: 0)
                        if shelf.kind == .continueSeries, series.libraryId == source.libraryID {
                            Menu { continuationMenu(for: series) } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel(Text(series.name) + Text(" — ") + Text(L10n.tr("续听管理…")))
                                .help(L10n.tr("续听管理…"))
                        }
                    }
                }.disabled(!enabled).contextMenu { continuationMenu(for: series) }
            case .author(let author):
                VStack(alignment: .leading, spacing: 9) {
                    Button { actions.start(.author(author), store: store, source: source) } label: {
                        HomeAuthorArtwork(store: store, author: author, source: source).frame(height: 195)
                    }.buttonStyle(.plain).accessibilityLabel(author.name)
                    Text(author.name).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
                    Text(L10n.format("%1$@ 本书", String(author.numBooks))).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("查看作者"), systemImage: "arrow.up.right") { actions.start(.author(author), store: store, source: source) }
                        .buttonStyle(.borderless).font(.caption)
                }.disabled(!enabled)
            case .unsupported(let value):
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.035))
                        .overlay { Image(systemName: "rectangle.stack.badge.questionmark").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary) }
                        .frame(height: 195).accessibilityHidden(true)
                    Text(Self.unsupportedTitle(value)).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(L10n.tr("此内容类型暂不支持打开")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    @ViewBuilder
    private func continuationMenu(for series: BookSeries) -> some View {
        if shelf.kind == .continueSeries, series.libraryId == source.libraryID {
            Button(L10n.tr("隐藏系列续听…"), systemImage: "eye.slash") { continuation?.hide(series: series) }
                .disabled(!enabled || continuation?.scope.available != true || continuation?.scope.isWorking == true)
        }
    }

    private static func unsupportedTitle(_ value: ABSDiagnosticValue) -> String {
        if case .object(let object) = value {
            for key in ["title", "name"] { if case .string(let title) = object[key], !title.isEmpty { return title } }
        }
        return L10n.tr("未识别的内容")
    }
}

private struct HomeReadingRequest: Hashable { let source: HomeSource; let mediaID: String; let readingActivityID: UUID? }

private struct HomeItemCard: View {
    let store: AppStore
    let shelf: PersonalizedLibraryShelf
    let entry: LibraryBrowseEntry
    let model: HomeModel
    let actions: HomeActions
    let source: HomeSource
    let enabled: Bool
    let continuation: ContinueListeningModel?
    @State private var readingCheckpoint: ReadingCheckpoint?
    @State private var readingPending = false
    private var item: ShelfCore.LibraryItem { entry.item }
    private var episode: PodcastEpisode? { entry.recentEpisode }
    private var mediaID: String { item.id + (episode.map { ":" + $0.id } ?? "") }
    private var isReading: Bool { shelf.kind == .continueReading || shelf.kind == .readAgain || (!hasAudio && hasEbook) }
    private var hasAudio: Bool { episode.map(HomeActions.isPlayable) ?? (item.mediaType == "book" && HomeActions.hasAudio(entry)) }
    private var hasEbook: Bool { episode == nil && (item.media.ebookFile != nil || entry.mediaSummary?.ebookFormat != nil) }
    private var remote: MediaProgress? { store.progressByItem[mediaID] }
    private var progress: MediaProgress? { source.offline ? HomeActions.latestProgress(local: model.localResumeByID[mediaID], current: remote) : remote }
    private var fraction: Double {
        let value: Double
        if isReading {
            if let checkpoint = readingCheckpoint, readingPending || !checkpoint.format.supportsServerProgress || checkpoint.updatedAt >= (remote?.lastUpdate ?? 0) {
                value = checkpoint.progress
            } else { value = remote?.isFinished == true ? 1 : remote?.ebookProgress ?? 0 }
        } else if let player = store.player, player.currentMedia?.id == mediaID, player.duration > 0 {
            value = player.position / player.duration
        } else { value = progress?.isFinished == true ? 1 : progress?.progress ?? 0 }
        return value.isFinite ? min(1, max(0, value)) : 0
    }
    private var downloaded: Bool {
        guard store.downloads?.partition == source.partition else { return false }
        let key = episode.map { PodcastDownloadIdentity.key(itemID: item.id, episodeID: $0.id) } ?? item.id
        return store.downloads?.records.contains { $0.itemID == key && $0.state == .ready } == true
    }
    private var canAct: Bool { enabled && !item.isInvalid && !item.isMissing }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { actions.start(.open(entry), store: store, source: source) } label: {
                let cover = source.isCurrent(store) ? source.coverSource.request(item: item, store: store) : nil
                CoverView(item: item, url: cover?.url, client: cover?.client,
                          accountKey: cover?.accountKey ?? "none")
                    .frame(height: 195)
                    .overlay(alignment: .topTrailing) {
                        if downloaded { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white).padding(7).background(.black.opacity(0.55), in: Circle()).padding(7).accessibilityLabel(L10n.tr("已下载")) }
                    }
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(episode?.title ?? item.title)
            Text(episode?.title ?? item.title).font(.callout.weight(.semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
            HStack {
                Text(episode == nil ? item.authorName : item.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if hasContinuationMenu {
                    Menu { continuationMenu } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(Text(episode?.title ?? item.title) + Text(" — ") + Text(L10n.tr("续听管理…")))
                        .help(L10n.tr("续听管理…"))
                        .disabled(!enabled)
                }
            }
            if let episode {
                HStack(spacing: 5) {
                    if let season = episode.season, !season.isEmpty { Text(L10n.format("第 %1$@ 季", season)) }
                    if let number = episode.episode, !number.isEmpty { Text(L10n.format("第 %1$@ 集", number)) }
                    if episode.season == nil && episode.episode == nil, let stamp = episode.publishedAt, stamp.isFinite {
                        Text(Date(timeIntervalSince1970: stamp / 1000), style: .date)
                    }
                }.font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 7) {
                ProgressView(value: fraction).tint(ShelfTheme.accent).accessibilityLabel(isReading ? L10n.tr("阅读进度") : L10n.tr("收听进度"))
                Text("\(Int(fraction * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }.frame(height: 10)
            HStack(spacing: 11) {
                if isReading && hasEbook {
                    Button { actions.start(.read(entry), store: store, source: source) } label: { Image(systemName: "book.fill") }
                        .help(L10n.tr("阅读")).accessibilityLabel(L10n.tr("阅读"))
                } else if hasAudio {
                    Button { actions.start(.play(entry), store: store, source: source) } label: { Image(systemName: "play.fill") }
                        .help(L10n.tr("播放")).accessibilityLabel(L10n.tr("播放"))
                } else if item.mediaType == "podcast" {
                    Button { actions.start(.open(entry), store: store, source: source) } label: { Image(systemName: "list.bullet") }
                        .help(L10n.tr("全部单集")).accessibilityLabel(L10n.tr("全部单集"))
                }
                if hasAudio {
                    Button { actions.start(.enqueue(entry), store: store, source: source) } label: { Image(systemName: "text.badge.plus") }
                        .help(L10n.tr("加入待播队列")).accessibilityLabel(L10n.tr("加入待播队列"))
                }
                if hasEbook && !isReading {
                    Button { actions.start(.read(entry), store: store, source: source) } label: { Image(systemName: "book") }.help(L10n.tr("阅读")).accessibilityLabel(L10n.tr("阅读"))
                }
                if shelf.kind == .continueSeries, let series = item.media.metadata.series.first, !series.id.isEmpty {
                    Button { actions.start(.continueSeries(entry), store: store, source: source) } label: { Image(systemName: "books.vertical") }
                        .help(series.name).accessibilityLabel(L10n.tr("查看系列"))
                }
                Spacer(minLength: 0)
                if fraction >= 1 { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.tr("已完成")) }
            }.font(.callout).buttonStyle(.borderless).foregroundStyle(ShelfTheme.accent).disabled(!canAct)
        }
        .contextMenu { continuationMenu }
        .task(id: HomeReadingRequest(source: source, mediaID: mediaID, readingActivityID: store.readingActivityID)) {
            guard !Task.isCancelled, source.isCurrent(store) else { return }
            readingCheckpoint = nil; readingPending = false
            guard isReading, source.isCurrent(store), let partition = source.partition,
                  let repository = store.readingRepository else { return }
            do {
                let saved = try await repository.position(itemID: item.id, partition: partition)
                guard !Task.isCancelled, source.isCurrent(store) else { return }
                let pending = try await repository.pending(partition: partition).contains { $0.itemID == item.id }
                guard !Task.isCancelled, source.isCurrent(store) else { return }
                readingCheckpoint = saved; readingPending = pending
            } catch { /* A missing local checkpoint leaves the server snapshot visible. */ }
        }
    }

    private var hasContinuationMenu: Bool {
        if shelf.kind == .continueListening || shelf.kind == .continueReading { return true }
        if shelf.kind == .continueSeries, let series = item.media.metadata.series.first, !series.id.isEmpty { return true }
        return false
    }

    @ViewBuilder
    private var continuationMenu: some View {
        if shelf.kind == .continueListening || shelf.kind == .continueReading {
            Button(L10n.tr("隐藏此项续听…"), systemImage: "eye.slash") { continuation?.hide(item: item, episodeID: episode?.id) }
                .disabled(!enabled || continuation?.scope.available != true || continuation?.scope.isWorking == true)
        } else if shelf.kind == .continueSeries, let series = item.media.metadata.series.first, !series.id.isEmpty {
            Button(L10n.tr("隐藏系列续听…"), systemImage: "eye.slash") {
                continuation?.hide(series: BookSeries(id: series.id, name: series.name, libraryId: item.libraryId))
            }.disabled(!enabled || continuation?.scope.available != true || continuation?.scope.isWorking == true)
        }
    }
}

private struct HomeAuthorImageRequest: Hashable {
    let source: HomeSource
    let authorID: String
    let updatedAt: Double?
    let imagePath: String?
}

private struct HomeAuthorArtwork: View {
    let store: AppStore
    let author: Author
    let source: HomeSource
    @State private var image: NSImage?
    @State private var imageSource: HomeAuthorImageRequest?
    private var request: HomeAuthorImageRequest { .init(source: source, authorID: author.id, updatedAt: author.updatedAt, imagePath: author.imagePath) }
    var body: some View {
        ZStack {
            LinearGradient(colors: [ShelfTheme.accent.opacity(0.12), .secondary.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "person.crop.circle").font(.system(size: 75, weight: .ultraLight)).foregroundStyle(ShelfTheme.accent.opacity(0.6))
            if imageSource == request, let image { Image(nsImage: image).resizable().scaledToFill() }
        }.frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(author.name)
        .task(id: request) {
            guard !Task.isCancelled, source.isCurrent(store) else { return }
            let requested = request
            image = nil; imageSource = nil
            guard source.isCurrent(store), let profile = store.profile,
                  let url = try? ServerEndpoint(baseURL: profile.baseURL).url(path: "api/authors/\(ServerEndpoint.component(author.id))/image") else { return }
            let key = (source.partition?.directoryName ?? "none") + "|" + url.absoluteString + "|" + String(author.updatedAt ?? 0) + "|" + (author.imagePath ?? "")
            guard let data = await HomeAuthorImageCache.shared.load(key: key, url: url, client: source.offline ? nil : store.client),
                  !Task.isCancelled, source.isCurrent(store),
                  let origin = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(origin, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
            image = NSImage(cgImage: thumbnail, size: .zero); imageSource = requested
        }
    }
}

private actor HomeAuthorImageCache {
    static let shared = HomeAuthorImageCache()
    func load(key: String, url: URL, client: ABSClient?) async -> Data? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let directory = support.appendingPathComponent("ShelfMac/HomeArtwork", isDirectory: true)
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        guard let client, let data = try? await client.requestData(path: url.absoluteString), !data.isEmpty, data.count < 12 * 1024 * 1024 else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
