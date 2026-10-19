import Foundation

/// A server-confirmed change to recommendation visibility, never a position update.
public enum ContinuationMetadataChange: Sendable {
    case progress(MediaProgress)
    case series(id: String, hidden: Bool)

    public func applying(to user: UserAccount) -> UserAccount {
        var result = user
        switch self {
        case .progress(let progress):
            if let index = result.mediaProgress.firstIndex(where: { $0.id == progress.id }) {
                result.mediaProgress[index] = result.mediaProgress[index].withContinuationMetadata(from: progress)
            } else { result.mediaProgress.append(progress) }
        case .series(let id, let hidden):
            result.seriesHideFromContinueListening.removeAll { $0 == id }
            if hidden { result.seriesHideFromContinueListening.append(id) }
        }
        return result
    }

    public func applying(to progress: [MediaProgress]) -> [MediaProgress] {
        guard case .progress(let metadata) = self else { return progress }
        var result = progress
        if let index = result.firstIndex(where: { $0.id == metadata.id }) {
            result[index] = result[index].withContinuationMetadata(from: metadata)
        } else { result.append(metadata) }
        return result
    }
}

extension MediaProgress {
    public func preservingLocalContinuationMetadata(from previous: MediaProgress) -> MediaProgress {
        guard id == previous.id, serverID == nil else { return self }
        var result = self
        result.serverID = previous.serverID
        if currentTime == previous.currentTime { result.hideFromContinueListening = previous.hideFromContinueListening }
        return result
    }

    public func withContinuationMetadata(from metadata: MediaProgress) -> MediaProgress {
        guard id == metadata.id else { return self }
        var result = self
        result.serverID = metadata.serverID
        result.hideFromContinueListening = metadata.hideFromContinueListening
        return result
    }
}

extension PersonalizedLibraryShelf {
    /// Cached shelves may precede a confirmed hide. Other shelf types and their
    /// server totals stay intact; a podcast episode has its own progress identity.
    public func applyingContinuationVisibility(user: UserAccount?, progressByID: [String: MediaProgress]) -> Self {
        guard kind == .continueListening || kind == .continueReading || kind == .continueSeries else { return self }
        let userProgress = Dictionary((user?.mediaProgress ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let hiddenSeries = Set(user?.seriesHideFromContinueListening ?? [])
        var result = self
        result.entities = entities.filter { entity in
            switch entity {
            case .item(let entry):
                if kind == .continueSeries {
                    guard let id = entry.item.media.metadata.series.first?.id else { return true }
                    return !hiddenSeries.contains(id)
                }
                let id = entry.item.id + (entry.recentEpisode.map { ":" + $0.id } ?? "")
                let current = progressByID[id]
                // Audio checkpoints have no server UUID. A stationary checkpoint
                // must not clear a hidden flag; advancing audio may reveal it again.
                if let current, current.serverID != nil { return !current.hideFromContinueListening }
                if let current, let saved = userProgress[id], current.currentTime != saved.currentTime { return !current.hideFromContinueListening }
                return !(userProgress[id]?.hideFromContinueListening ?? current?.hideFromContinueListening ?? false)
            case .series(let series): return kind != .continueSeries || !hiddenSeries.contains(series.id)
            default: return true
            }
        }
        return result
    }
}
