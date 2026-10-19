import SwiftUI
import ShelfCore

struct SettingsChoice: Identifiable, Hashable, Sendable {
    let value: String
    let label: String
    let localizesLabel: Bool
    var id: String { value }
    var displayLabel: String { localizesLabel ? L10n.tr(label) : label }
    init(_ value: String, _ label: String, localizesLabel: Bool = true) {
        self.value = value; self.label = label; self.localizesLabel = localizesLabel
    }
}

/// A server upgrade may introduce values that this client does not yet know.
/// Keep that value selected until the user explicitly chooses another option.
struct SettingsChoicePicker: View {
    let title: String
    @Binding var selection: String
    let choices: [SettingsChoice]

    var body: some View {
        Picker(L10n.tr(title), selection: $selection) {
            ForEach(choices) { choice in Text(choice.displayLabel).tag(choice.value) }
            if !choices.contains(where: { $0.value == selection }) {
                Text(selection.isEmpty ? L10n.tr("未设置") : L10n.format("当前值：%@", selection)).tag(selection)
            }
        }
        .pickerStyle(.menu)
    }
}

enum EditableSettingChoice: Hashable, Sendable {
    case value(String)
    case custom

    var wireValue: String? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// Selecting Custom opens a draft; the bound wire value changes only on Apply.
struct EditableSettingsChoicePicker: View {
    let title: String
    @Binding var selection: String
    let choices: [SettingsChoice]
    @State private var isEditingCustom = false
    @State private var customValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.tr(title), selection: menuSelection) {
                ForEach(choices) { choice in Text(choice.displayLabel).tag(EditableSettingChoice.value(choice.value)) }
                if !choices.contains(where: { $0.value == selection }) {
                    Text(selection.isEmpty ? L10n.tr("未设置") : L10n.format("当前值：%1$@", selection)).tag(EditableSettingChoice.value(selection))
                }
                Text(L10n.tr("自定义…")).tag(EditableSettingChoice.custom)
            }.pickerStyle(.menu)
            if isEditingCustom {
                HStack {
                    TextField(L10n.tr(title), text: $customValue).onSubmit { applyCustom() }
                    Button(L10n.tr("应用")) { applyCustom() }.disabled(customValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.tr("取消")) { isEditingCustom = false }
                }
            }
        }
        .onChange(of: selection) { _, _ in isEditingCustom = false }
    }

    private var menuSelection: Binding<EditableSettingChoice> {
        Binding(get: { isEditingCustom ? .custom : .value(selection) }, set: { choice in
            if let value = choice.wireValue { selection = value }
            switch choice {
            case .value: isEditingCustom = false
            case .custom: customValue = selection; isEditingCustom = true
            }
        })
    }
    private func applyCustom() {
        let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = value; isEditingCustom = false
    }
}

enum CronScheduleChoice: Hashable, Sendable {
    case disabled
    case daily
    case interval(String)
    case current(String)
    case custom

    static func current(_ cron: String, allowsDisabled: Bool) -> Self {
        if cron.isEmpty && allowsDisabled { return .disabled }
        if ServerSettingOptions.dailyTime(cron) != nil { return .daily }
        if ServerSettingOptions.backupIntervals.contains(where: { $0.value == cron && $0.value != "daily" && $0.value != "custom" }) { return .interval(cron) }
        return .current(cron)
    }

    func wireValue(current: String) -> String? {
        switch self {
        case .disabled: ""
        case .daily: ServerSettingOptions.dailyTime(current) == nil ? "0 0 * * *" : current
        case .interval(let value): value
        case .current, .custom: nil
        }
    }
}

/// The same official ABS intervals as the backup editor, with daily time controls.
/// Opening an arbitrary existing expression does not rewrite or normalize it.
struct CronSchedulePicker: View {
    let title: String
    @Binding var selection: String
    var allowsDisabled = false
    @State private var isEditingCustom = false
    @State private var customValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.tr(title), selection: menuSelection) {
                if allowsDisabled { Text(L10n.tr("关闭")).tag(CronScheduleChoice.disabled) }
                ForEach(ServerSettingOptions.backupIntervals.filter { $0.value != "custom" }) { option in
                    Text(L10n.tr(option.title)).tag(option.value == "daily" ? CronScheduleChoice.daily : .interval(option.value))
                }
                if case .current = CronScheduleChoice.current(selection, allowsDisabled: allowsDisabled) {
                    Text(selection.isEmpty ? L10n.tr("未设置") : L10n.format("当前值：%1$@", selection)).tag(CronScheduleChoice.current(selection))
                }
                Text(L10n.tr("自定义 Cron")).tag(CronScheduleChoice.custom)
            }.pickerStyle(.menu)
            if isEditingCustom {
                HStack {
                    TextField(L10n.tr("Cron 表达式"), text: $customValue).onSubmit { applyCustom() }
                    Button(L10n.tr("应用")) { applyCustom() }.disabled(customValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.tr("取消")) { isEditingCustom = false }
                }
            } else if ServerSettingOptions.dailyTime(selection) != nil {
                HStack {
                    Picker(L10n.tr("小时"), selection: dailyComponent(isHour: true)) {
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.pickerStyle(.menu)
                    Picker(L10n.tr("分钟"), selection: dailyComponent(isHour: false)) {
                        ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                    }.pickerStyle(.menu)
                }
            }
            if !selection.isEmpty {
                Text(L10n.format("服务器时区 · %1$@", selection)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .onChange(of: selection) { _, _ in isEditingCustom = false }
    }

    private var menuSelection: Binding<CronScheduleChoice> {
        Binding(get: { isEditingCustom ? .custom : CronScheduleChoice.current(selection, allowsDisabled: allowsDisabled) }, set: { choice in
            if choice == .custom { customValue = selection; isEditingCustom = true }
            else {
                if let value = choice.wireValue(current: selection) { selection = value }
                isEditingCustom = false
            }
        })
    }
    private func dailyComponent(isHour: Bool) -> Binding<Int> {
        Binding(get: {
            let time = ServerSettingOptions.dailyTime(selection)
            return isHour ? time?.hour ?? 0 : time?.minute ?? 0
        }, set: { value in
            let time = ServerSettingOptions.dailyTime(selection)
            let hour = isHour ? value : time?.hour ?? 0
            let minute = isHour ? time?.minute ?? 0 : value
            guard (0...23).contains(hour), (0...59).contains(minute) else { return }
            selection = "\(minute) \(hour) * * *"
        })
    }
    private func applyCustom() {
        let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = value; isEditingCustom = false
    }
}

private enum MetadataLanguageChoice: Hashable {
    case value(String)
    case custom
}

/// ABS metadata language is free text. Suggestions never normalize an existing value.
struct MetadataLanguagePicker: View {
    @Binding var selection: String
    @State private var isEditingCustom = false
    @State private var customValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L10n.tr("语言"), selection: menuSelection) {
                Text(L10n.tr("未设置")).tag(MetadataLanguageChoice.value(""))
                ForEach(ClientSettingsChoices.metadataLanguages) { language in
                    Text(L10n.tr(language.label)).tag(MetadataLanguageChoice.value(language.value))
                }
                if !selection.isEmpty, !ClientSettingsChoices.metadataLanguages.contains(where: { $0.value == selection }) {
                    Text(L10n.format("当前值：%@", selection)).tag(MetadataLanguageChoice.value(selection))
                }
                Text(L10n.tr("自定义…")).tag(MetadataLanguageChoice.custom)
            }.pickerStyle(.menu)
            if isEditingCustom {
                HStack {
                    TextField(L10n.tr("自定义语言"), text: $customValue).onSubmit { applyCustom() }
                    Button(L10n.tr("应用")) { applyCustom() }.disabled(customValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.tr("取消")) { isEditingCustom = false }
                }
            }
        }
        .onChange(of: selection) { _, _ in isEditingCustom = false }
    }

    private var menuSelection: Binding<MetadataLanguageChoice> {
        Binding(get: { isEditingCustom ? .custom : .value(selection) }, set: { choice in
            switch choice {
            case .value(let value): selection = value; isEditingCustom = false
            case .custom: customValue = selection; isEditingCustom = true
            }
        })
    }
    private func applyCustom() {
        let value = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = value; isEditingCustom = false
    }
}

enum ClientSettingsChoices {
    static func preserving<Value: Equatable>(_ current: Value, in values: [Value]) -> [Value] {
        values.contains(current) ? values : values + [current]
    }

    static let playbackRates = PlaybackRatePolicy.presets
    static let jumpSeconds = [10, 15, 30, 60, 120, 300]
    static let rateSteps = [0.1, 0.05]
    // These are suggestions with explicit, unchanged language-name wire values.
    // The ABS field accepts arbitrary text, not an ISO-code enum.
    static let metadataLanguages: [SettingsChoice] = [
        .init("Chinese", "中文"), .init("English", "英语"), .init("Spanish", "西班牙语"),
        .init("French", "法语"), .init("German", "德语"), .init("Italian", "意大利语"),
        .init("Japanese", "日语"), .init("Korean", "韩语"), .init("Portuguese", "葡萄牙语"),
        .init("Russian", "俄语"), .init("Arabic", "阿拉伯语"), .init("Hindi", "印地语")
    ]

    // ABS v2.37.1 client/plugins/i18n.js; retain its complete directory list.
    static let podcastRegionCodes = ["au", "br", "be", "by", "cz", "dk", "de", "ee", "es", "fr", "hr", "il", "it", "jp", "lu", "hu", "nl", "no", "nz", "at", "pl", "pt", "ru", "ch", "sk", "se", "vn", "ua", "gb", "us", "cn"]
    static var podcastRegions: [SettingsChoice] {
        let locale = AppLanguageStore.shared.selection.locale
        return podcastRegionCodes.map { .init($0, locale.localizedString(forRegionCode: $0.uppercased()) ?? $0.uppercased(), localizesLabel: false) }
    }
    // ABS v2.37.1 client/store/globals.js.
    static let libraryIcons: [SettingsChoice] = [
        .init("database", "数据库"), .init("audiobookshelf", "Audiobookshelf"),
        .init("books-1", "书架一"), .init("books-2", "书架二"), .init("book-1", "书本"),
        .init("microphone-1", "麦克风一"), .init("microphone-3", "麦克风二"), .init("radio", "收音机"),
        .init("podcast", "播客"), .init("rss", "RSS"), .init("headphones", "耳机"), .init("music", "音乐"),
        .init("file-picture", "图片"), .init("rocket", "火箭"), .init("power", "电源"), .init("star", "星标"), .init("heart", "爱心")
    ]
    static let episodeTypes: [SettingsChoice] = [.init("full", "正片"), .init("trailer", "预告"), .init("bonus", "加更")]
    static let audioCodecs: [SettingsChoice] = [.init("copy", "保留原编码"), .init("aac", "AAC"), .init("opus", "OPUS")]
    static let audioBitrates: [SettingsChoice] = [.init("32k", "32k"), .init("64k", "64k"), .init("128k", "128k"), .init("192k", "192k")]
    static let audioChannels: [SettingsChoice] = [.init("1", "单声道"), .init("2", "立体声")]
}
