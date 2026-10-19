import SwiftUI
import ShelfCore

struct ServerSettingOption: Identifiable, Hashable, Sendable {
    let value: String
    let title: String
    let localizesTitle: Bool
    var id: String { value }
    init(_ value: String, _ title: String, localizesTitle: Bool = true) { self.value = value; self.title = title; self.localizesTitle = localizesTitle }
}

/// A future server value remains selectable and is never replaced merely by opening a form.
struct ServerSettingPicker: View {
    let title: String
    @Binding var selection: String
    let options: [ServerSettingOption]
    var body: some View {
        Picker(L10n.tr(title), selection: $selection) {
            ForEach(options) { Text($0.localizesTitle ? L10n.tr($0.title) : $0.title).tag($0.value) }
            if !options.contains(where: { $0.value == selection }) {
                if selection.isEmpty { Text(L10n.tr("服务器默认")).tag(selection) }
                else { Text(L10n.format("当前值：%1$@", String(describing: selection))).tag(selection) }
            }
        }.pickerStyle(.menu)
    }
}

enum ServerSettingOptions {
    // Fixed ABS 2.37.1 client/plugins/i18n.js. These are server Web languages.
    static let languages: [ServerSettingOption] = [
        .init("ar", "عربي"), .init("be", "Беларуская"), .init("bg", "Български"), .init("bn", "বাংলা"),
        .init("ca", "Català"), .init("cs", "Čeština"), .init("da", "Dansk"), .init("de", "Deutsch"),
        .init("en-us", "English"), .init("es", "Español"), .init("et", "Eesti"), .init("fi", "Suomi"),
        .init("fr", "Français"), .init("he", "עברית"), .init("hr", "Hrvatski"), .init("it", "Italiano"),
        .init("ja", "日本語"), .init("lt", "Lietuvių"), .init("hu", "Magyar"), .init("ko", "한국어"),
        .init("nl", "Nederlands"), .init("no", "Norsk"), .init("pl", "Polski"), .init("pt-br", "Português (Brasil)"),
        .init("ru", "Русский"), .init("sk", "Slovenčina"), .init("sl", "Slovenščina"), .init("sv", "Svenska"),
        .init("tr", "Türkçe"), .init("uk", "Українська"), .init("vi-vn", "Tiếng Việt"),
        .init("zh-cn", "简体中文"), .init("zh-tw", "正體中文")
    ]
    // Values use ABS/date-fns tokens, rather than Foundation date format tokens.
    static let dateFormats: [ServerSettingOption] = [
        .init("MM/dd/yyyy", "MM/DD/YYYY"), .init("dd/MM/yyyy", "DD/MM/YYYY"),
        .init("dd.MM.yyyy", "DD.MM.YYYY"), .init("yyyy-MM-dd", "YYYY-MM-DD"),
        .init("MMM do, yyyy", "MMM do, yyyy"), .init("MMMM do, yyyy", "MMMM do, yyyy"),
        .init("dd MMM yyyy", "dd MMM yyyy"), .init("dd MMMM yyyy", "dd MMMM yyyy")
    ]
    static let timeFormats: [ServerSettingOption] = [.init("h:mma", "12 小时制（h:mma）"), .init("HH:mm", "24 小时制（HH:mm）")]
    static let bookshelfViews: [ServerSettingOption] = [.init("0", "标准书架"), .init("1", "详细信息")]
    static let logLevels: [ServerSettingOption] = ServerLogLevel.allCases.map { .init(String($0.rawValue), $0.settingsLabel) }
    // Fixed ABS CronExpressionBuilder.vue presets; daily retains its hour/minute controls.
    static let backupIntervals: [ServerSettingOption] = [
        .init("daily", "每天"), .init("0 */12 * * *", "每 12 小时"), .init("0 */6 * * *", "每 6 小时"),
        .init("0 */2 * * *", "每 2 小时"), .init("0 * * * *", "每小时"),
        .init("*/30 * * * *", "每 30 分钟"), .init("*/15 * * * *", "每 15 分钟"), .init("custom", "自定义 Cron")
    ]
    static let deviceAvailability: [ServerSettingOption] = [
        .init("adminOrUp", "管理员"), .init("userOrUp", "普通用户及管理员"),
        .init("guestOrUp", "所有账户"), .init("specificUsers", "指定用户")
    ]
    static let notificationTypes: [ServerSettingOption] = [
        .init("info", "信息"), .init("success", "成功"), .init("warning", "警告"), .init("failure", "失败")
    ]
    static let accountTypes: [ServerSettingOption] = [.init("admin", "管理员"), .init("user", "普通用户"), .init("guest", "访客")]
    static let existingUserMatches: [ServerSettingOption] = [.init("", "不自动关联"), .init("username", "用户名"), .init("email", "电子邮件")]

    static func dailyTime(_ cron: String) -> (hour: Int, minute: Int)? {
        let pieces = cron.split(whereSeparator: \.isWhitespace)
        guard pieces.count == 5, pieces[2...4].allSatisfy({ $0 == "*" }),
              let minute = Int(pieces[0]), (0...59).contains(minute),
              let hour = Int(pieces[1]), (0...23).contains(hour) else { return nil }
        return (hour, minute)
    }
    static func backupInterval(for cron: String) -> String {
        if backupIntervals.contains(where: { $0.value == cron }) { return cron }
        return dailyTime(cron) == nil ? "custom" : "daily"
    }
}

extension ServerLogLevel {
    var settingsLabel: String {
        switch self {
        case .trace: "跟踪（TRACE）"
        case .debug: "调试（DEBUG）"
        case .info: "信息（INFO）"
        case .warning: "警告（WARN）"
        case .error: "错误（ERROR）"
        case .fatal: "严重错误（FATAL）"
        case .note: "备注（NOTE）"
        }
    }
}

/// GET /auth/openid/config returns the issuer discovery document through ABS.
struct ServerOIDCConfiguration: Decodable, Sendable {
    var issuer: String?
    var authorization_endpoint: String?
    var token_endpoint: String?
    var userinfo_endpoint: String?
    var jwks_uri: String?
    var end_session_endpoint: String?
    var id_token_signing_alg_values_supported: [String]?
}
