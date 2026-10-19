import Foundation

/// The library-file representation includes supplementary status omitted by audio files.
public struct ManagedLibraryFile: Decodable, Hashable, Sendable, Identifiable {
    public let ino: String
    public let metadata: FileMetadata
    public let fileType: String?
    public let isSupplementary: Bool?
    public var id: String { ino }
    public var isEBook: Bool { fileType == "ebook" }
    public var isMetadataSidecar: Bool {
        let filename = metadata.filename.lowercased()
        return filename == "metadata.json" || filename == "metadata.abs" || filename.hasSuffix(".opf")
    }
}

public enum LibraryMetadataFileKind: String, CaseIterable, Sendable {
    case json, abs
    public var filename: String { "metadata." + rawValue }
}
public struct MetadataFileRemovalResult: Decodable, Hashable, Sendable {
    public let found: Int
    public let removed: Int?
}

/// Nil means untouched; empty strings and arrays explicitly clear enabled fields.
public struct BatchMetadataEdits: Sendable {
    public var subtitle: String?
    public var authors: [String]?
    public var series: [NamedEntity]?
    public var publishedYear: String?
    public var publishedDate: String?
    public var description: String?
    public var isbn: String?
    public var asin: String?
    public var abridged: Bool?
    public var narrators: [String]?
    public var genres: [String]?
    public var tags: [String]?
    public var publisher: String?
    public var language: String?
    public var explicit: Bool?
    public init() {}
    public var isEmpty: Bool {
        subtitle == nil && authors == nil && series == nil && publishedYear == nil && publishedDate == nil && description == nil && isbn == nil && asin == nil && abridged == nil && narrators == nil && genres == nil && tags == nil && publisher == nil && language == nil && explicit == nil
    }
    public func applying(to item: LibraryItem, appendLists: Bool) -> BatchMediaUpdate {
        let old = item.media.metadata
        func strings(_ new: [String], _ old: [String]) -> [String] {
            var result = appendLists ? old : []
            for value in new where !result.contains(value) { result.append(value) }
            return result
        }
        func entities(_ new: [NamedEntity], _ old: [NamedEntity]) -> [NamedEntity] {
            var result = appendLists ? old : []
            for entity in new {
                guard !result.contains(where: { $0.name.caseInsensitiveCompare(entity.name) == .orderedSame }) else { continue }
                let existing = old.first { $0.name.caseInsensitiveCompare(entity.name) == .orderedSame }
                result.append(NamedEntity(id: existing?.id ?? "", name: entity.name, sequence: entity.sequence))
            }
            return result
        }
        var metadata = MetadataUpdate()
        if item.mediaType == "book" {
            metadata.subtitle = subtitle
            metadata.publishedYear = publishedYear
            metadata.publishedDate = publishedDate
            metadata.isbn = isbn
            metadata.asin = asin
            metadata.abridged = abridged
            if let authors { metadata.authors = entities(authors.map { NamedEntity(name: $0) }, old.authors) }
            if let series { metadata.series = entities(series, old.series) }
            if let narrators { metadata.narrators = strings(narrators, old.narrators) }
        }
        metadata.description = description
        metadata.publisher = publisher
        metadata.language = language
        metadata.explicit = explicit
        if let genres { metadata.genres = strings(genres, old.genres) }
        return BatchMediaUpdate(id: item.id, mediaPayload: MediaUpdate(metadata: metadata, tags: tags.map { strings($0, item.media.tags) }))
    }
}
