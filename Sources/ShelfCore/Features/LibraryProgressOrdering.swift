import Foundation

/// Client-side percentage ordering. The ABS `progress` wire sort means update time.
public enum LibraryProgressOrdering: Sendable {
    public static func fraction(for progress: MediaProgress?) -> Double {
        guard let progress else { return 0 }
        if progress.isFinished { return 1 }
        let raw = progress.progress != 0 ? progress.progress : (progress.ebookProgress ?? 0)
        return raw.isFinite ? min(1, max(0, raw)) : 0
    }

    public static func sorted(_ entries: [LibraryBrowseEntry], progress: [String: MediaProgress], descending: Bool) -> [LibraryBrowseEntry] {
        let scored = entries.map { entry in
            (entry: entry, fraction: fraction(for: progress[entry.item.id]))
        }
        return scored.sorted { lhs, rhs in
            if lhs.fraction != rhs.fraction { return descending ? lhs.fraction > rhs.fraction : lhs.fraction < rhs.fraction }
            let titleOrder = lhs.entry.item.title.localizedStandardCompare(rhs.entry.item.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.entry.id < rhs.entry.id
        }.map(\.entry)
    }
}
