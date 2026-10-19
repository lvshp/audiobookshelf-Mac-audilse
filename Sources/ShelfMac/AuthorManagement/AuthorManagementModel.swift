import Foundation
import AppKit
import Observation
import ShelfCore

struct AuthorManagementChange {
    enum Kind { case updated, merged, deleted }
    let source: LibraryPersonalSource
    let client: ABSClient
    let previousID: String
    let author: Author?
    let kind: Kind
    @MainActor func isCurrent(_ store: AppStore) -> Bool { source.isCurrent(store) && store.client === client }
}

@MainActor @Observable final class AuthorManagementModel {
    let scope: LibraryPersonalScope
    private(set) var authorID: String
    private(set) var author: Author?
    private(set) var imageData: Data?
    private(set) var imageError: String?
    private(set) var isLoadingImage = false
    private(set) var isDeleted = false
    var name = ""
    var asin = ""
    var description = ""
    var imageURL = ""
    private(set) var matchRegion = "us"
    @ObservationIgnored private var imageRequestID = UUID()
    @ObservationIgnored private let onChange: @MainActor (AuthorManagementChange) -> Void
    init(store: AppStore, authorID: String, libraryID: String, onChange: @escaping @MainActor (AuthorManagementChange) -> Void = { _ in }) {
        self.authorID = authorID; scope = .init(store: store, libraryID: libraryID); self.onChange = onChange
    }
    var canUpdate: Bool { scope.available && scope.store.user.map { AdminPolicy.allows(.updateContent, user: $0) } == true }
    var canDelete: Bool { scope.available && scope.store.user.map { AdminPolicy.allows(.deleteContent, user: $0) } == true }
    var canUploadImage: Bool { canUpdate && scope.store.user.map { AdminPolicy.allows(.upload, user: $0) } == true }
    var canRename: Bool { AuthorManagementPolicy.allowsRename(serverVersion: scope.source?.serverVersion) }
    var draft: AuthorUpdate {
        guard let author else { return .init() }
        return .init(name: canRename && name != author.name ? name : nil,
                     description: description != (author.description ?? "") ? description : nil,
                     asin: asin != (author.asin ?? "") ? asin : nil)
    }
    var hasChanges: Bool { let value = draft; return value.name != nil || value.description != nil || value.asin != nil }
    var validImageURL: Bool { Self.validImageURL(imageURL) }
    static func validImageURL(_ text: String) -> Bool {
        guard let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return false }; return true
    }
    static func region(provider: String?) -> String {
        guard let provider, provider.hasPrefix("audible."), let suffix = provider.split(separator: ".").last, !suffix.isEmpty else { return "us" }
        return String(suffix)
    }
    func load(expectedSource: LibraryPersonalSource? = nil) async {
        guard !Task.isCancelled, expectedSource == nil || expectedSource == scope.identity else { return }
        imageRequestID = UUID(); scope.bind(); author = nil; imageData = nil; imageError = nil; isLoadingImage = false; isDeleted = false
        name = ""; asin = ""; description = ""; imageURL = ""
        guard let (source, client, generation) = try? scope.context() else { return }
        let id = authorID
        let loaded = await scope.run(source: source, generation: generation) {
            let library = try await client.libraryDetails(id: source.libraryID); try self.scope.check(source, generation)
            guard library.id == source.libraryID, library.mediaType == "book" else { throw ABSError.invalidResponse }
            let author = try await client.author(id: id); try self.scope.check(source, generation)
            guard author.id == id, author.libraryId == source.libraryID else { throw ABSError.invalidResponse }
            return (author, library.provider)
        } apply: { value in
            self.adopt(value.0); self.matchRegion = Self.region(provider: value.1)
        }
        if loaded { await loadImage(source: source, client: client, generation: generation) }
    }
    func save() {
        guard let author, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasChanges,
              let (source, client, generation) = try? scope.context(requiring: [.updateContent]) else { return }
        // A stale/forged text binding cannot bypass the old-server rename restriction.
        guard canRename || name == author.name else { scope.error = L10n.tr("此服务端版本的作者改名可能跨书库合并。请升级到 2.36.1 或更新版本后改名。"); return }
        let update = draft
        scope.confirm(.init(title: L10n.tr("保存作者"), message: L10n.tr("保存作者资料；改为同库已有作者的名称会合并作者，并更新关联书籍。"), action: {
            await self.mutate(source, client, generation, id: author.id) { try await client.updateAuthorResult(id: author.id, update: update) }
        }))
    }
    func match() {
        guard let author, !asin.isEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let (source, client, generation) = try? scope.context(requiring: [.updateContent]) else { return }
        let payload = AuthorMatch(query: asin.isEmpty ? name : nil, asin: asin.isEmpty ? nil : asin, region: matchRegion)
        scope.confirm(.init(title: L10n.tr("快速匹配作者"), message: L10n.tr("立即从 Audible 更新 ASIN、简介和符合条件的头像；不会改名。未保存的资料草稿将替换为匹配结果。"), action: {
            await self.mutate(source, client, generation, id: author.id) { try await client.matchAuthorResult(id: author.id, match: payload) }
        }))
    }
    func uploadImage() {
        guard let author, validImageURL, let (source, client, generation) = try? scope.context(requiring: [.updateContent, .upload]) else { return }
        let url = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        scope.confirm(.init(title: L10n.tr("更换作者头像"), message: L10n.tr("服务器将下载该网页图片并替换作者头像。"), action: {
            await self.mutate(source, client, generation, id: author.id) { try await client.setAuthorImageResult(id: author.id, url: url) }
        }))
    }
    func deleteImage() {
        guard let author, author.imagePath != nil, let (source, client, generation) = try? scope.context(requiring: [.deleteContent]) else { return }
        scope.confirm(.init(title: L10n.tr("删除作者头像"), message: L10n.tr("删除服务器上的作者头像。"), destructive: true, action: {
            await self.mutate(source, client, generation, id: author.id) { try await client.deleteAuthorImageResult(id: author.id) }
        }))
    }
    func deleteAuthor() {
        guard let author, let (source, client, generation) = try? scope.context(requiring: [.deleteContent]) else { return }
        scope.confirm(.init(title: L10n.tr("删除作者"), message: L10n.tr("删除作者及所有书籍中的此作者关联，并更新元数据文件。不会删除书籍、音频或播放进度。"), destructive: true, action: {
            await self.scope.run(source: source, generation: generation) {
                try await client.deleteAuthor(id: author.id); try self.scope.check(source, generation)
                return true
            } apply: { _ in
                self.imageRequestID = UUID(); self.isLoadingImage = false; self.imageError = nil
                self.isDeleted = true; self.author = nil; self.imageData = nil
                self.onChange(.init(source: source, client: client, previousID: author.id, author: nil, kind: .deleted))
            }
        }))
    }
    private func mutate(_ source: LibraryPersonalSource, _ client: ABSClient, _ generation: UUID, id: String,
                        operation: @escaping @MainActor () async throws -> AuthorMutationResult) async {
        let changed = await scope.run(source: source, generation: generation) {
            let result = try await operation(); try self.scope.check(source, generation)
            guard result.author.libraryId == source.libraryID,
                  result.author.id == id || result.merged == true else { throw ABSError.invalidResponse }
            return result
        } apply: { result in
            self.adopt(result.author)
            self.scope.notice = result.merged == true ? L10n.tr("作者已合并，已切换到保留的作者。") : (result.updated == false ? L10n.tr("服务器资料没有变化。") : L10n.tr("作者资料已更新。"))
            self.onChange(.init(source: source, client: client, previousID: id, author: result.author, kind: result.merged == true ? .merged : .updated))
        }
        // Confirmed mutation remains visible even if image loading fails.
        if changed { await loadImage(source: source, client: client, generation: generation) }
    }
    private func adopt(_ author: Author) {
        imageRequestID = UUID(); isLoadingImage = false
        self.author = author; authorID = author.id; name = author.name; asin = author.asin ?? ""; description = author.description ?? ""; imageURL = ""
        imageData = nil; imageError = nil
    }
    func retryImage() async {
        guard let (source, client, generation) = try? scope.context() else { return }
        await loadImage(source: source, client: client, generation: generation)
    }
    private func loadImage(source: LibraryPersonalSource, client: ABSClient, generation: UUID) async {
        guard let author, author.imagePath != nil, (try? scope.check(source, generation)) != nil else { return }
        let id = author.id; let requestID = UUID(); imageRequestID = requestID; isLoadingImage = true; imageError = nil
        defer { if scope.generation == generation, imageRequestID == requestID, self.author?.id == id { isLoadingImage = false } }
        do {
            var components = URLComponents(); components.percentEncodedPath = "api/authors/" + ServerEndpoint.component(id) + "/image"
            if let updated = author.updatedAt { components.queryItems = [.init(name: "ts", value: String(updated))] }
            guard let path = components.string else { throw ABSError.invalidResourcePath }
            let data = try await client.requestData(path: path)
            try scope.check(source, generation); guard self.author?.id == id, imageRequestID == requestID else { return }
            guard data.count <= 12 * 1024 * 1024, NSImage(data: data) != nil else { throw ABSError.invalidResponse }; imageData = data
        } catch is CancellationError {
        } catch ABSError.sessionChanged {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch { if scope.source == source, scope.generation == generation, source.isCurrent(scope.store), self.author?.id == id, imageRequestID == requestID { imageError = L10n.error(error) } }
    }
}
