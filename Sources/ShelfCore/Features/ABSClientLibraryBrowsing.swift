import Foundation

public enum LibraryBrowsingError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSort(LibraryBrowseSort, serverVersion: String?)
    public var errorDescription: String? {
        switch self {
        case .unsupportedSort(.progress, let version): "服务器版本 \(version ?? "未知") 仅在按收听进度筛选时支持最近进度排序，请选择进度筛选或其他排序。"
        case .unsupportedSort(_, let version): "服务器版本 \(version ?? "未知") 尚未验证支持按进度开始或完成时间排序，请选择其他排序。"
        }
    }
}

extension ABSClient {
    public func browseLibrary(libraryID: String, options: LibraryBrowseOptions = .init()) async throws -> LibraryBrowsePage {
        let capabilities = LibraryBrowsingCapabilities(serverVersion: profile.serverVersion)
        if [.progressStarted, .progressFinished].contains(options.sort), !capabilities.hasProgressDateSorting {
            throw LibraryBrowsingError.unsupportedSort(options.sort, serverVersion: profile.serverVersion)
        }
        if options.sort == .progress, !capabilities.supportsProgressSorting(filter: options.filter) {
            throw LibraryBrowsingError.unsupportedSort(options.sort, serverVersion: profile.serverVersion)
        }
        var query: [URLQueryItem] = [
            .init(name: "page", value: String(max(0, options.page))),
            .init(name: "limit", value: String(min(500, max(1, options.limit)))),
            .init(name: "sort", value: options.sort.rawValue),
            .init(name: "desc", value: options.descending ? "1" : "0"),
            .init(name: "collapseseries", value: options.collapseSeries ? "1" : "0"),
            .init(name: "minified", value: options.minified ? "1" : "0")
        ]
        if let filter = options.filter.queryValue { query.append(.init(name: "filter", value: filter)) }
        let includes = Set(options.includes).map(\.rawValue).sorted().joined(separator: ",")
        if !includes.isEmpty { query.append(.init(name: "include", value: includes)) }
        return try await getJSON(path: FeaturePath.query("api/libraries/\(FeaturePath.id(libraryID))/items", query))
    }
    public func libraryFilterMetadata(libraryID: String) async throws -> LibraryFilterMetadata {
        try await getJSON(path: "api/libraries/\(FeaturePath.id(libraryID))/filterdata")
    }
    public func personalizedShelves(libraryID: String, limit: Int = 10, includes: [LibraryBrowseInclude] = [.rssFeed, .share, .numEpisodesIncomplete]) async throws -> [PersonalizedLibraryShelf] {
        var query = [URLQueryItem(name: "limit", value: String(min(500, max(1, limit))))]
        let include = Set(includes).map(\.rawValue).sorted().joined(separator: ",")
        if !include.isEmpty { query.append(.init(name: "include", value: include)) }
        return try await getJSON(path: FeaturePath.query("api/libraries/\(FeaturePath.id(libraryID))/personalized", query))
    }
}
