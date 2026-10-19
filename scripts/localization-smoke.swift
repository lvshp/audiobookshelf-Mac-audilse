import Foundation
import Observation
import ShelfCore
import ShelfPlayback

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct LocalizationSmoke {
    static func main() async throws {
        let domain = "ShelfMac.LocalizationSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppLanguageStore(defaults: defaults)
        precondition(store.selection == .simplifiedChinese)
        store.selection = .english
        precondition(AppLanguageStore(defaults: defaults).selection == .english)
        print("PASS language selection survives a fresh store")

        defaults.set("unknown", forKey: AppLanguageStore.defaultsKey)
        precondition(AppLanguageStore(defaults: defaults).selection == .simplifiedChinese)
        print("PASS invalid saved language falls back to Simplified Chinese")

        let changes = Counter()
        withObservationTracking { _ = store.selection } onChange: { changes.increment() }
        store.selection = .simplifiedChinese
        precondition(changes.value == 1)
        print("PASS language mutations notify observed view dependencies")

        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        AppLanguageStore.shared.selection = .simplifiedChinese
        precondition(L10n.tr("个人设置") == "个人设置")
        AppLanguageStore.shared.selection = .english
        let english = L10n.tr("个人设置")
        precondition(english != "个人设置" && !english.isEmpty)
        print("PASS both real language packs resolve independently of system language")

        let text = L10n.format("前进 %1$@ 秒", "30")
        precondition(text.contains("30") && !text.contains("前进") && !text.contains("%@"))
        precondition(L10n.tr("unregistered.user.content") == "unregistered.user.content")
        print("PASS translated interpolation preserves arguments and missing-key fallback")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let text = L10n.tr("个人设置")
                    precondition(!text.isEmpty)
                    store.selection = index.isMultiple(of: 2) ? .english : .simplifiedChinese
                    precondition(AppLanguage.allCases.contains(store.selection))
                }
            }
        }
        print("PASS concurrent localization reads and preference writes")
        AppLanguageStore.shared.selection = .english
        precondition(L10n.error(ABSError.notAuthenticated) == "Your sign-in has expired. Sign in again.")
        precondition(L10n.error(OfflineStorageError.incompleteDownload) == "The download is incomplete, or the local file has changed.")
        precondition(L10n.error(LocalCredentialError.missingKey) == "The local credential encryption key is missing. Existing credential files were kept.")
        print("PASS typed authentication, download storage, and credential errors use English")

        let formatName = "自定义格式%"
        precondition(L10n.error(ReadingError.unsupportedFormat(formatName)) == "This ebook format is not supported: " + formatName + ".")
        precondition(L10n.error(PlaybackFailure.noTracks) == "There are no playable audio tracks.")
        print("PASS typed reading and playback failures preserve dynamic values")

        let serverMessage = "服务器自定义信息：个人设置 %@ 100%"
        precondition(L10n.error(ABSError.http(status: 418, message: serverMessage)) == "The server returned 418: " + serverMessage)
        let systemError = NSError(domain: "LocalizationSmoke.System", code: 1, userInfo: [NSLocalizedDescriptionKey: serverMessage])
        precondition(L10n.error(systemError) == serverMessage)
        precondition(L10n.error(ReadingError.invalidArchive(serverMessage)) == "Could not open the archived book: " + serverMessage)
        AppLanguageStore.shared.selection = .simplifiedChinese
        precondition(L10n.error(ABSError.notAuthenticated) == ABSError.notAuthenticated.localizedDescription)
        print("PASS server and system messages remain verbatim; typed errors switch back to Chinese")
        let unsaved = ClientDiagnostic(code: "playback.finalSnapshotNotDurable", fallbackMessage: "完整播放记录尚未安全保存，请重试退出。")
        precondition(L10n.diagnostic(unsaved) == "完整播放记录尚未安全保存，请重试。")
        AppLanguageStore.shared.selection = .english
        precondition(L10n.diagnostic(unsaved) == "The complete playback record has not been saved safely. Please try again.")
        precondition(L10n.tr("没有搜索结果") == "No search results")
        print("PASS retained playback diagnostics and reader empty search state switch languages")
        let notificationDescriptions: [(String, String, String)] = [
            ("NotificationOnBackupCompletedDescription", "备份完成时触发", "Triggered when a backup is completed"),
            ("NotificationOnBackupFailedDescription", "备份失败时触发", "Triggered when a backup fails"),
            ("NotificationOnEpisodeDownloadedDescription", "当播客节目自动下载完成时触发", "Triggered when a podcast episode is auto-downloaded"),
            ("NotificationOnRSSFeedDisabledDescription", "由于尝试失败次数过多而导致剧集自动下载被禁用时触发", "Triggered when automatic episode downloads are disabled due to too many failed attempts"),
            ("NotificationOnRSSFeedFailedDescription", "当用于自动下载剧集的 RSS 源请求失败时触发", "Triggered when the RSS feed request fails for an automatic episode download"),
            ("NotificationOnTestDescription", "测试通知系统的事件", "Event for testing the notification system"),
        ]
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.selection = language
            for (key, chinese, english) in notificationDescriptions {
                precondition(L10n.notificationDescription(raw: "server fallback", key: key) == (language == .english ? english : chinese))
            }
            let raw = "Custom server description %@ 100%"
            precondition(L10n.notificationDescription(raw: raw, key: "NotificationFutureDescription") == raw)
            precondition(L10n.notificationDescription(raw: raw, key: nil) == raw)
            precondition(L10n.notificationDescription(raw: raw, key: "") == raw)
        }
        print("PASS six official notification descriptions in both languages and unknown/missing key fallbacks")
        let publicShareDiagnostics: [(String, String, String)] = [
            ("publicShare.invalidLink", "公开分享链接无效。", "The public share link is invalid."),
            ("publicShare.untrustedResource", "分享资源地址超出了允许的来源或路径。", "The shared resource is outside the allowed origin or path."),
            ("publicShare.unavailable", "分享不存在、已失效或当前不可用。", "This share does not exist, has expired, or is unavailable."),
            ("publicShare.downloadForbidden", "此分享不允许下载。", "Downloads are not allowed for this share."),
            ("publicShare.sessionChanged", "匿名分享上下文已关闭或发生变化。", "The anonymous share context has closed or changed."),
            ("publicShare.closed", "匿名分享上下文已关闭或发生变化。", "The anonymous share context has closed or changed."),
            ("publicShare.stateConflict", "匿名进度已被其他上下文更新，请重新打开分享。", "Anonymous progress was updated by another context. Reopen the share."),
            ("publicShare.localStateUnavailable", "无法保存匿名分享的本机检查点。", "The local checkpoint for this anonymous share could not be saved."),
            ("publicShare.invalidResponse", "分享服务器返回了无效的数据。", "The share server returned invalid data."),
            ("publicShare.responseTooLarge", "分享响应超过允许的大小。", "The share response exceeds the allowed size."),
            ("publicShare.invalidRange", "音轨字节范围无效。", "The audio track byte range is invalid."),
            ("publicShare.rangeIgnored", "服务器没有遵守有界音轨范围请求。", "The server did not honor the bounded audio range request."),
            ("publicShare.rangeNotSatisfiable", "音轨范围超出文件长度。", "The requested audio range is beyond the file length."),
            ("publicShare.progressSuperseded", "此进度已被更新的本机检查点替代。", "A newer local checkpoint has replaced this progress."),
            ("publicShare.http", "公开分享请求失败（HTTP %1$@）。", "The public share request failed (HTTP %1$@)."),
            ("publicShare.transport", "无法连接公开分享服务器（%1$@）。", "Could not connect to the public share server (%1$@)."),
            ("publicShare.storage.invalidStorage", "匿名分享的本机状态目录或文件不安全。", "The local anonymous share state directory or file is unsafe."),
            ("publicShare.storage.invalidState", "匿名分享的本机状态无法解密或读取。", "The local anonymous share state could not be decrypted or read."),
            ("publicShare.storage.missingKey", "匿名分享的加密密钥缺失，原状态已保留。", "The anonymous share encryption key is missing. Existing state was kept."),
            ("publicShare.storage.busy", "另一个进程正在更新匿名分享状态，请稍后重试。", "Another process is updating anonymous share state. Try again shortly."),
            ("publicShare.storage.io", "无法读写匿名分享的本机状态（%1$@）。", "Could not read or write local anonymous share state (%1$@).")
        ]
        let publicShareUI: [(String, String)] = [
            ("打开公开分享…", "Open public share…"),
            ("停止播放并保存位置", "Stop playback and save position"),
            ("公开分享", "Public shares"),
            ("粘贴 Audiobookshelf 分享链接，无需登录即可播放。", "Paste an Audiobookshelf share link to play without signing in."),
            ("分享链接", "Share link"),
            ("打开分享", "Open share"),
            ("正在打开分享…", "Opening share…"),
            ("播放位置单独保存在本机，不计入已登录账户的收听记录。", "Playback position is saved separately on this Mac and is not added to the signed-in account’s listening history."),
            ("正在准备分享文件…", "Preparing shared files…"),
            ("保存分享文件", "Save shared files"),
            ("打开一段分享的故事", "Open a shared story"),
            ("分享的发布和撤销仍由服务器管理。", "The server manages publishing and revoking shares."),
            ("此分享没有章节信息", "This share has no chapter information")
        ]
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.selection = language
            for (code, chinese, english) in publicShareDiagnostics {
                let arguments = chinese.contains("%1$@") ? ["503"] : []
                let issue = ClientDiagnostic(code: code, arguments: arguments, fallbackMessage: "UNEXPECTED FALLBACK")
                let expected = (language == .english ? english : chinese).replacingOccurrences(of: "%1$@", with: "503")
                precondition(L10n.diagnostic(issue) == expected)
            }
            for (chinese, english) in publicShareUI { precondition(L10n.tr(chinese) == (language == .english ? english : chinese)) }
            precondition(L10n.error(PublicShareError.http(503)) == L10n.diagnostic(PublicShareError.http(503).clientDiagnostic))
            precondition(L10n.error(PublicShareStorageError.io(5)) == L10n.diagnostic(PublicShareStorageError.io(5).clientDiagnostic))
            let cause = ClientDiagnostic(code: "publicShare.http", arguments: ["503"], fallbackMessage: "UNEXPECTED FALLBACK")
            do {
                let issue = ClientDiagnostic(code: "publicShare.progressPending", fallbackMessage: "UNEXPECTED FALLBACK", causes: [cause])
                precondition(L10n.diagnostic(issue) == (language == .english ? "The anonymous playback position is saved locally but has not been acknowledged by the server." : "匿名播放位置已保存在本机，尚未确认服务器进度。") + "\n" + L10n.diagnostic(cause))
            }
            do {
                let issue = ClientDiagnostic(code: "publicShare.progressAckPersistenceFailed", fallbackMessage: "UNEXPECTED FALLBACK", causes: [cause])
                precondition(L10n.diagnostic(issue) == (language == .english ? "The server acknowledged the position, but the local acknowledgment could not be saved. The original checkpoint was kept." : "服务器已确认位置，但本机确认标记保存失败；原检查点仍保留。") + "\n" + L10n.diagnostic(cause))
            }
            let malformed = ClientDiagnostic(code: "publicShare.http", fallbackMessage: "original %@ 100%")
            precondition(L10n.diagnostic(malformed) == "original %@ 100%")
            let malformedProgress = ClientDiagnostic(code: "publicShare.progressPending", fallbackMessage: "original")
            precondition(L10n.diagnostic(malformedProgress) == "original")
        }
        print("PASS 23 public-share diagnostics, typed errors, nested causes, and 13 UI strings in both languages")
        let podcastManagementUI: [(String, String)] = [
            ("自定义", "Custom"),
            ("详情刷新失败，请重试刷新。", "Details could not be refreshed. Please try refreshing again."),
            ("重试刷新", "Retry Refresh"),
            ("检查起始日期已保存。", "The episode check start date has been saved."),
            ("每次检查下载数量", "Downloads per check"),
            ("指定检查起始日期", "Choose check start date"),
            ("查找此日期之后的新单集", "Look for new episodes after"),
            ("保留最近单集数量", "Episodes to keep"),
            ("每次自动下载数量", "Downloads per automatic check"),
            ("非负整数，0 表示不限", "Non-negative integer; 0 means unlimited")
        ]
        for language in AppLanguage.allCases {
            AppLanguageStore.shared.selection = language
            for (chinese, english) in podcastManagementUI {
                precondition(L10n.tr(chinese) == (language == .english ? english : chinese), "Podcast translation mismatch: \(chinese) in \(language)")
            }
        }
        print("PASS podcast management counts, dates, and refresh recovery in both languages")
        print("Localization smoke: 13 checks passed")
    }
}
