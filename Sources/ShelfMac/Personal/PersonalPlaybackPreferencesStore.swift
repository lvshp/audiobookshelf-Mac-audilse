import Foundation
import Observation
import ShelfCore

extension Notification.Name {
    static let shelfPlaybackPreferencesDidChange = Notification.Name("ShelfMac.PlaybackPreferencesDidChange")
}

/// ABS Web stores these locally. ShelfMac additionally partitions them by account.
@MainActor @Observable final class PersonalPlaybackPreferencesStore {
    static let shared = PersonalPlaybackPreferencesStore()
    private let defaults: UserDefaults
    private(set) var revision = UUID()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func preferences(for partition: AccountPartition) -> ClientPreferences {
        guard let data = defaults.data(forKey: key(partition)), let value = try? JSONDecoder().decode(ClientPreferences.self, from: data) else { return .init() }
        return normalized(value)
    }
    func save(_ preferences: ClientPreferences, for partition: AccountPartition) throws {
        let value = normalized(preferences)
        defaults.set(try JSONEncoder().encode(value), forKey: key(partition))
        revision = UUID()
        NotificationCenter.default.post(name: .shelfPlaybackPreferencesDidChange, object: partition)
    }
    private func normalized(_ preferences: ClientPreferences) -> ClientPreferences {
        var value = preferences
        value.playbackRate = PlaybackRatePolicy.normalized(value.playbackRate)
        value.jumpForwardAmount = min(300, max(5, value.jumpForwardAmount)); value.jumpBackwardAmount = min(300, max(5, value.jumpBackwardAmount))
        if !value.playbackRateIncrementDecrement.isFinite || value.playbackRateIncrementDecrement <= 0 { value.playbackRateIncrementDecrement = 0.1 }
        return value
    }
    private func key(_ partition: AccountPartition) -> String { "ShelfMac.playbackPreferences." + partition.directoryName }
}
