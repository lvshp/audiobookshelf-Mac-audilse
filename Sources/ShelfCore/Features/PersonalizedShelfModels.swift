import Foundation
import CryptoKit

public enum PersonalizedShelfKind: String, Codable, CaseIterable, Sendable {
    case continueListening = "continue-listening"
    case continueReading = "continue-reading"
    case continueSeries = "continue-series"
    case recentlyAdded = "recently-added"
    case recentSeries = "recent-series"
    case discover
    case listenAgain = "listen-again"
    case readAgain = "read-again"
    case newestAuthors = "newest-authors"
    case newestEpisodes = "newest-episodes"
}

extension PersonalizedLibraryShelf {
    public var kind: PersonalizedShelfKind? { PersonalizedShelfKind(rawValue: id) }

    /// Includes the recommendation context: the same book can be next in two different series.
    public func entityIdentifier(for entity: PersonalizedShelfEntity) -> String {
        let identity: [String]
        switch entity {
        case .item(let entry):
            if kind == .continueSeries, let seriesID = entry.item.media.metadata.series.first?.id, !seriesID.isEmpty {
                identity = ["item", entry.id, "series", seriesID]
            } else { identity = ["item", entry.id] }
        case .series(let series): identity = ["series", series.id]
        case .author(let author): identity = ["author", author.id]
        case .unsupported(let value):
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = (try? encoder.encode(value)) ?? Data()
            identity = ["unsupported", SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        return ([id] + identity).map { "\($0.utf8.count):\($0)" }.joined()
    }
}
