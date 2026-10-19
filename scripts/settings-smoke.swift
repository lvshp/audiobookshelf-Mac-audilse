import Foundation
import AudilseCore

@main @MainActor struct SettingsSmoke {
    static func main() throws {
        let domain = "Audilse.SettingsSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = AccountPartition(serverID: UUID(), userID: "fixture")
        let store = PersonalPlaybackPreferencesStore(defaults: defaults)
        var preferences = ClientPreferences()
        preferences.playbackRate = 1.3
        preferences.jumpForwardAmount = 7
        preferences.playbackRateIncrementDecrement = 0.2
        try store.save(preferences, for: account)
        let restored = PersonalPlaybackPreferencesStore(defaults: defaults).preferences(for: account)
        precondition(restored.playbackRate == 1.3 && restored.jumpForwardAmount == 7 && restored.playbackRateIncrementDecrement == 0.2)
        precondition(ClientSettingsChoices.preserving(restored.jumpForwardAmount, in: ClientSettingsChoices.jumpSeconds).contains(7))
        precondition(ClientSettingsChoices.preserving(restored.playbackRate, in: ClientSettingsChoices.playbackRates).contains(1.3))
        print("PASS valid custom playback values survive save/restart and remain selectable")

        preferences.playbackRateIncrementDecrement = .nan
        try store.save(preferences, for: account)
        precondition(store.preferences(for: account).playbackRateIncrementDecrement == 0.1)
        print("PASS invalid playback step is repaired before persistence")

        precondition(ServerSettingOptions.backupInterval(for: "15 8 * * *") == "daily")
        precondition(ServerSettingOptions.dailyTime("15 8 * * *")?.hour == 8)
        precondition(ServerSettingOptions.dailyTime("15 8 * * *")?.minute == 15)
        for value in ["*/15 * * * *", "*/30 * * * *", "0 * * * *", "0 */2 * * *", "0 */6 * * *", "0 */12 * * *"] {
            precondition(ServerSettingOptions.backupInterval(for: value) == value)
        }
        print("PASS official backup intervals and daily times are recognized")

        for value in ["15 8 * * 1", "@weekly", "0 0 1 * *", "0 25 * * *"] {
            precondition(ServerSettingOptions.backupInterval(for: value) == "custom")
        }
        print("PASS custom schedules remain custom instead of becoming daily")

        precondition(ServerSettingOptions.languages.contains { $0.value == "zh-cn" })
        precondition(ServerSettingOptions.languages.contains { $0.value == "en-us" })
        precondition(ServerSettingOptions.dateFormats.contains { $0.value == "yyyy-MM-dd" })
        precondition(ServerSettingOptions.timeFormats.contains { $0.value == "HH:mm" })
        precondition(ServerSettingOptions.bookshelfViews.map(\.value) == ["0", "1"])
        print("PASS server language/date/time/bookshelf choices retain official wire values")

        precondition(ClientSettingsChoices.podcastRegionCodes.count == 31)
        precondition(Set(ClientSettingsChoices.podcastRegionCodes).count == 31)
        precondition(ClientSettingsChoices.libraryIcons.count == 17)
        print("PASS complete podcast region and library icon catalogs")

        precondition(ClientSettingsChoices.audioBitrates.map(\.value) == ["32k", "64k", "128k", "192k"])
        for original in ["96k", "245k", "128k"] {
            var bitrate = original
            if let value = EditableSettingChoice.custom.wireValue { bitrate = value }
            precondition(bitrate == original)
            if let value = EditableSettingChoice.value("64k").wireValue { bitrate = value }
            precondition(bitrate == "64k")
        }
        print("PASS official bitrate presets and choosing Custom preserve the current bitrate")

        let intervalValues = ["*/15 * * * *", "*/30 * * * *", "0 * * * *", "0 */2 * * *", "0 */6 * * *", "0 */12 * * *"]
        for value in intervalValues {
            precondition(CronScheduleChoice.current(value, allowsDisabled: false) == .interval(value))
            precondition(CronScheduleChoice.interval(value).wireValue(current: "arbitrary") == value)
        }
        for original in ["15 8 * * 1", "@weekly", "0 0 1 * *", " 05 08 * * * ", "daily", "custom"] {
            var cron = original
            if let value = CronScheduleChoice.custom.wireValue(current: cron) { cron = value }
            precondition(cron == original)
            if ServerSettingOptions.dailyTime(original) != nil {
                precondition(CronScheduleChoice.current(original, allowsDisabled: false) == .daily)
                precondition(CronScheduleChoice.daily.wireValue(current: original) == original)
            } else {
                precondition(CronScheduleChoice.current(original, allowsDisabled: false) == .current(original))
            }
        }
        precondition(CronScheduleChoice.current("", allowsDisabled: true) == .disabled)
        precondition(CronScheduleChoice.current("", allowsDisabled: false) == .current(""))
        precondition(CronScheduleChoice.disabled.wireValue(current: "0 * * * *") == "")
        precondition(CronScheduleChoice.daily.wireValue(current: "15 8 * * 1") == "0 0 * * *")
        print("PASS Cron presets, daily times, disabled state and Custom preserve exact existing wire values")

        let customProvider = SettingsChoice("synthetic-provider", "书库", localizesLabel: false)
        do {
            let previousLanguage = AppLanguageStore.shared.selection
            defer { AppLanguageStore.shared.selection = previousLanguage }
            AppLanguageStore.shared.selection = .english
            precondition(L10n.tr("书库") == "Library")
            precondition(SettingsChoice("fixed-label", "书库").displayLabel == "Library")
            precondition(customProvider.displayLabel == "书库" && !customProvider.localizesLabel)
            precondition(ClientSettingsChoices.libraryIcons.allSatisfy(\.localizesLabel))
            precondition(ClientSettingsChoices.podcastRegions.allSatisfy { !$0.localizesLabel })
        }
        print("PASS server provider names bypass interface translation while fixed option labels remain localized")
        print("Settings smoke: 9 checks passed")
    }
}
