import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var name: String { switch self { case .simplifiedChinese: "简体中文"; case .english: "English" } }
    var locale: Locale { Locale(identifier: rawValue) }
}

/// Localization is read by view bodies and by errors produced outside MainActor.
/// The registrar makes language changes observable; the lock protects those reads.
final class AppLanguageStore: Observable, @unchecked Sendable {
    static let shared = AppLanguageStore()
    static let defaultsKey = "Audilse.interfaceLanguage"
    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var stored: AppLanguage

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = defaults.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }

    var selection: AppLanguage {
        get {
            registrar.access(self, keyPath: \.selection)
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        set {
            registrar.withMutation(of: self, keyPath: \.selection) {
                lock.lock(); defer { lock.unlock() }
                stored = newValue
                defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
            }
        }
    }
}

protocol ClientLocalizedError: Error {
    var clientErrorDescription: String { get }
}

enum L10n {
    private static let bundles: [AppLanguage: Bundle] = {
        var result: [AppLanguage: Bundle] = [:]
        let candidates = [AppResources.bundle, Bundle.main]
        for language in AppLanguage.allCases {
            for base in candidates {
                if let resource = base.resourceURL?.appendingPathComponent(language.rawValue + ".lproj"),
                   let bundle = Bundle(url: resource) {
                    result[language] = bundle
                    break
                }
            }
        }
        return result
    }()

    static func error(_ error: any Error) -> String {
        (error as? any ClientLocalizedError)?.clientErrorDescription ?? error.localizedDescription
    }

    static func tr(_ key: String) -> String {
        tr(key, language: AppLanguageStore.shared.selection)
    }

    static func tr(_ key: String, language: AppLanguage) -> String {
        return bundles[language]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    /// Only official notification descriptions are translated; server extensions stay verbatim.
    static func notificationDescription(raw: String, key: String?) -> String {
        let message: String
        switch key {
        case "NotificationOnBackupCompletedDescription": message = "备份完成时触发"
        case "NotificationOnBackupFailedDescription": message = "备份失败时触发"
        case "NotificationOnEpisodeDownloadedDescription": message = "当播客节目自动下载完成时触发"
        case "NotificationOnRSSFeedDisabledDescription": message = "由于尝试失败次数过多而导致剧集自动下载被禁用时触发"
        case "NotificationOnRSSFeedFailedDescription": message = "当用于自动下载剧集的 RSS 源请求失败时触发"
        case "NotificationOnTestDescription": message = "测试通知系统的事件"
        default: return raw
        }
        return tr(message)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: AppLanguageStore.shared.selection.locale, arguments: arguments)
    }
}

struct AppLanguagePicker: View {
    @Bindable private var languages = AppLanguageStore.shared
    var body: some View {
        Picker(L10n.tr("客户端界面语言"), selection: $languages.selection) {
            ForEach(AppLanguage.allCases) { language in Text(language.name).tag(language) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.interface-language")
    }
}
