import Foundation
import ShelfCore
import ShelfPlayback

// Translate only typed errors owned by this client. Server messages, file names,
// archive diagnostics, and unknown system errors remain verbatim arguments.
extension ABSError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidServerURL: L10n.tr("服务器地址必须是有效的 HTTP 或 HTTPS 地址。")
        case .invalidResourcePath: L10n.tr("无效的服务器资源路径。")
        case .untrustedResource: L10n.tr("资源地址不属于当前服务器，已阻止发送认证信息。")
        case .notAuthenticated: L10n.tr("登录已过期，请重新登录。")
        case .sessionChanged: L10n.tr("账户已切换，请重新执行操作。")
        case let .http(status, message): L10n.format("服务器返回 %1$@：%2$@", String(status), message)
        case .invalidResponse: L10n.tr("服务器返回了无效的数据。")
        case .unsupportedVersion(let version): L10n.format("服务器版本 %1$@ 低于支持的 2.26.0。", version)
        case .invalidOIDCCallback: L10n.tr("单点登录回调验证失败。")
        }
    }
}
extension ServerRestoreArchiveError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidBatch: L10n.tr("备份恢复隔离记录无效。")
        case .missingBatch: L10n.tr("找不到备份恢复隔离记录。")
        case .scopeChanged: L10n.tr("备份恢复隔离范围已变化，请重新读取记录。")
        case .pendingRestore: L10n.tr("服务器恢复尚未完成，请确认服务器重启后重新连接。")
        case .retiredSource: L10n.tr("此本地数据连接已因服务器恢复退役，请重新载入账户。")
        case .incompleteArchive: L10n.tr("本机进度尚未完整归档，不能重新连接服务器。")
        }
    }
}
extension LocalCredentialError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidStorage: L10n.tr("本地凭据目录或文件不安全，已停止读取。")
        case .invalidCredentials: L10n.tr("本地凭据文件无法解密，请重新登录或检查本地凭据备份。")
        case .missingKey: L10n.tr("本地凭据加密密钥缺失，已保留原有凭据文件。")
        case .busy: L10n.tr("另一个 ShelfMac 进程正在使用本地凭据，请稍后重试。")
        case .io(let code): L10n.format("无法读写本地凭据（%1$@）。", String(code))
        }
    }
}
extension OfflineStorageError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidSession: L10n.tr("离线播放记录无效。")
        case .sessionIdentityChanged: L10n.tr("播放会话身份已改变，无法覆盖原有记录。")
        case .unsafePath: L10n.tr("下载文件路径无效。")
        case .incompleteDownload: L10n.tr("下载尚未完成，或本地文件已改变。")
        case .insufficientSpace: L10n.tr("磁盘可用空间不足。")
        case .accountChanged: L10n.tr("账户已切换，先前的下载操作已取消。")
        }
    }
}
extension OfflineSyncError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .verificationFailed: L10n.tr("同步后播放位置校验失败，记录已保留。")
        case .progressChangedDuringResolution: L10n.tr("其他设备再次更新了进度，请重新选择播放位置。")
        case .alreadyRunning: L10n.tr("同步正在进行。")
        }
    }
}
extension ReadingError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .noEbook: L10n.tr("此内容没有可阅读的电子书。")
        case .unavailableOffline: L10n.tr("电子书尚未缓存，请联网打开一次后再离线阅读。")
        case .unsupportedFormat(let format): L10n.format("暂不支持此电子书格式：%1$@。", format)
        case .invalidDownload: L10n.tr("电子书原件下载失败或文件不完整。")
        case .invalidArchive(let detail): L10n.format("无法打开压缩书籍：%1$@", detail)
        case .oversizedArchive: L10n.tr("压缩书籍超出本地安全解包限制。")
        case .missingLibrary: L10n.tr("系统 libarchive 不可用，无法解包漫画。")
        case .sourceChanged: L10n.tr("阅读位置在其他设备发生变化，请选择要保留的位置。")
        }
    }
}
extension PersonalFeatureError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidSlug: L10n.tr("链接名称须为 1–120 位英文字母、数字、连字符或下划线。")
        case .invalidAddress: L10n.tr("服务器地址无效。")
        case .invalidDevice: L10n.tr("阅读器需要名称、有效电子邮件地址，且只能关联当前用户。")
        case .duplicateDevice: L10n.tr("阅读器名称不能重复。")
        case .unavailable: L10n.tr("当前内容不支持此操作。")
        }
    }
}
extension AdminFeatureError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case let .unavailable(feature, minimumVersion):
            let name: String
            switch feature {
            case "API Key 管理": name = L10n.tr("API Key 管理")
            case "活跃登录会话": name = L10n.tr("活跃登录会话")
            default: name = feature
            }
            return L10n.format("%1$@需要 Audiobookshelf %2$@ 或更高版本。", name, minimumVersion)
        case .invalidUpload: return L10n.tr("上传文件或表单字段无效。")
        case .permissionDenied: return L10n.tr("账户没有执行此操作的权限。")
        }
    }
}
extension LibraryBrowsingError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .unsupportedSort(.progress, let version): L10n.format("服务器版本 %1$@ 仅在按收听进度筛选时支持最近进度排序，请选择进度筛选或其他排序。", version ?? L10n.tr("未知"))
        case .unsupportedSort(_, let version): L10n.format("服务器版本 %1$@ 尚未验证支持按进度开始或完成时间排序，请选择其他排序。", version ?? L10n.tr("未知"))
        }
    }
}
extension PlaybackFailure: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .noTracks: L10n.tr("没有可播放的音轨。")
        case .invalidTimeline: L10n.tr("音轨的时长或时间轴无效。")
        case .invalidStartPosition: L10n.tr("播放起始位置必须是有效的非负秒数。")
        case .unsupportedLocalFormat(let format): L10n.format("本地音频格式 %1$@ 需要 VLCKit 3.7.3；当前构建未包含兼容引擎。", format)
        case .unavailableService: L10n.tr("尚未连接播放服务器。")
        case .invalidLocalFile: L10n.tr("下载文件不存在或不完整，请重新下载。")
        case .invalidHLSManifest: L10n.tr("服务器返回的音频播放清单无效。")
        case .streamNotReady: L10n.tr("服务器尚未生成可播放的音频片段，请稍后重试。")
        case .seekInterrupted: L10n.tr("播放定位被中断，请重试。")
        }
    }
}

extension L10n {
    /// Render at the UI boundary so an already displayed diagnostic follows the
    /// current language. Raw messages and arguments never become lookup keys.
    static func diagnostic(_ issue: ClientDiagnostic) -> String { diagnostic(issue, depth: 0) }
    private static func diagnostic(_ issue: ClientDiagnostic, depth: Int) -> String {
        guard issue.schemaVersion == 1, depth < 8 else { return issue.fallbackMessage }
        if issue.code == "playback.localPersistenceFailed" {
            guard issue.arguments.isEmpty, issue.causes.count == 2 else { return issue.fallbackMessage }
            return format("%1$@；本地保存失败：%2$@", diagnostic(issue.causes[0], depth: depth + 1), diagnostic(issue.causes[1], depth: depth + 1))
        }
        if issue.code == "publicShare.progressPending" || issue.code == "publicShare.progressAckPersistenceFailed" {
            guard issue.arguments.isEmpty, issue.causes.count == 1 else { return issue.fallbackMessage }
            let message = issue.code == "publicShare.progressPending"
                ? tr("匿名播放位置已保存在本机，尚未确认服务器进度。")
                : tr("服务器已确认位置，但本机确认标记保存失败；原检查点仍保留。")
            return format("%1$@\n%2$@", message, diagnostic(issue.causes[0], depth: depth + 1))
        }
        guard issue.causes.isEmpty else { return issue.fallbackMessage }
        let key: String
        let count: Int
        switch issue.code {
        case "publicShare.invalidLink": key = "公开分享链接无效。"; count = 0
        case "publicShare.untrustedResource": key = "分享资源地址超出了允许的来源或路径。"; count = 0
        case "publicShare.unavailable": key = "分享不存在、已失效或当前不可用。"; count = 0
        case "publicShare.downloadForbidden": key = "此分享不允许下载。"; count = 0
        case "publicShare.sessionChanged": key = "匿名分享上下文已关闭或发生变化。"; count = 0
        case "publicShare.closed": key = "匿名分享上下文已关闭或发生变化。"; count = 0
        case "publicShare.stateConflict": key = "匿名进度已被其他上下文更新，请重新打开分享。"; count = 0
        case "publicShare.localStateUnavailable": key = "无法保存匿名分享的本机检查点。"; count = 0
        case "publicShare.invalidResponse": key = "分享服务器返回了无效的数据。"; count = 0
        case "publicShare.responseTooLarge": key = "分享响应超过允许的大小。"; count = 0
        case "publicShare.invalidRange": key = "音轨字节范围无效。"; count = 0
        case "publicShare.rangeIgnored": key = "服务器没有遵守有界音轨范围请求。"; count = 0
        case "publicShare.rangeNotSatisfiable": key = "音轨范围超出文件长度。"; count = 0
        case "publicShare.progressSuperseded": key = "此进度已被更新的本机检查点替代。"; count = 0
        case "publicShare.http": key = "公开分享请求失败（HTTP %1$@）。"; count = 1
        case "publicShare.transport": key = "无法连接公开分享服务器（%1$@）。"; count = 1
        case "publicShare.storage.invalidStorage": key = "匿名分享的本机状态目录或文件不安全。"; count = 0
        case "publicShare.storage.invalidState": key = "匿名分享的本机状态无法解密或读取。"; count = 0
        case "publicShare.storage.missingKey": key = "匿名分享的加密密钥缺失，原状态已保留。"; count = 0
        case "publicShare.storage.busy": key = "另一个进程正在更新匿名分享状态，请稍后重试。"; count = 0
        case "publicShare.storage.io": key = "无法读写匿名分享的本机状态（%1$@）。"; count = 1
        case "abs.invalidServerURL": key = "服务器地址必须是有效的 HTTP 或 HTTPS 地址。"; count = 0
        case "abs.invalidResourcePath": key = "无效的服务器资源路径。"; count = 0
        case "abs.untrustedResource": key = "资源地址不属于当前服务器，已阻止发送认证信息。"; count = 0
        case "abs.notAuthenticated": key = "登录已过期，请重新登录。"; count = 0
        case "abs.sessionChanged": key = "账户已切换，请重新执行操作。"; count = 0
        case "abs.http": key = "服务器返回 %1$@：%2$@"; count = 2
        case "abs.invalidResponse": key = "服务器返回了无效的数据。"; count = 0
        case "abs.unsupportedVersion": key = "服务器版本 %1$@ 低于支持的 2.26.0。"; count = 1
        case "abs.invalidOIDCCallback": key = "单点登录回调验证失败。"; count = 0
        case "storage.invalidSession": key = "离线播放记录无效。"; count = 0
        case "storage.sessionIdentityChanged": key = "播放会话身份已改变，无法覆盖原有记录。"; count = 0
        case "storage.unsafePath": key = "下载文件路径无效。"; count = 0
        case "storage.incompleteDownload": key = "下载尚未完成，或本地文件已改变。"; count = 0
        case "storage.insufficientSpace": key = "磁盘可用空间不足。"; count = 0
        case "storage.accountChanged": key = "账户已切换，先前的下载操作已取消。"; count = 0
        case "sync.verificationFailed": key = "同步后播放位置校验失败，记录已保留。"; count = 0
        case "sync.percentageDiverged":
            guard issue.arguments.count == 2 else { return issue.fallbackMessage }
            return tr("服务器返回的收听百分比与播放位置不一致，记录已保留。")
        case "sync.progressChangedDuringResolution": key = "其他设备再次更新了进度，请重新选择播放位置。"; count = 0
        case "sync.alreadyRunning": key = "同步正在进行。"; count = 0
        case "download.invalidResponse": key = "下载服务器返回了无效响应。"; count = 0
        case "download.invalidRange": key = "下载服务器返回的续传范围无效。"; count = 0
        case "download.sourceChanged": key = "服务器原始文件已改变，请移除下载后重新下载。"; count = 0
        case "download.http": key = "下载请求失败（HTTP %1$@）。"; count = 1
        case "playback.noTracks": key = "没有可播放的音轨。"; count = 0
        case "playback.invalidTimeline": key = "音轨的时长或时间轴无效。"; count = 0
        case "playback.invalidStartPosition": key = "播放起始位置必须是有效的非负秒数。"; count = 0
        case "playback.unsupportedLocalFormat": key = "本地音频格式 %1$@ 需要 VLCKit 3.7.3；当前构建未包含兼容引擎。"; count = 1
        case "playback.unavailableService": key = "尚未连接播放服务器。"; count = 0
        case "playback.invalidLocalFile": key = "下载文件不存在或不完整，请重新下载。"; count = 0
        case "playback.invalidHLSManifest": key = "服务器返回的音频播放清单无效。"; count = 0
        case "playback.streamNotReady": key = "服务器尚未生成可播放的音频片段，请稍后重试。"; count = 0
        case "playback.seekInterrupted": key = "播放定位被中断，请重试。"; count = 0
        case "playback.engineFailed": key = "音频播放失败，请检查网络或重新下载。"; count = 0
        case "playback.localEngineFailed": key = "本地兼容引擎无法播放此文件。"; count = 0
        case "playback.savedForRecovery": key = "播放记录已保存在本地，停止播放后将重新同步。"; count = 0
        case "playback.finalSnapshotNotDurable": key = "完整播放记录尚未安全保存，请重试。"; count = 0
        case "playback.managementPendingHistory": key = "所选记录仍有本机待同步内容。请先停止播放并同步，再重新操作。"; count = 0
        default: return issue.fallbackMessage
        }
        guard issue.arguments.count == count else { return issue.fallbackMessage }
        return String(format: tr(key), locale: AppLanguageStore.shared.selection.locale,
                      arguments: issue.arguments.map { $0 as any CVarArg })
    }
}

extension ClientDiagnostic: ClientLocalizedError {
    var clientErrorDescription: String { L10n.diagnostic(self) }
}

extension AdminPlaybackSessionInputError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidUserID: L10n.tr("收听会话的用户筛选标识无效。请重新选择用户。")
        case .invalidSessionIDs: L10n.tr("收听会话标识无效。请刷新后重新选择。")
        }
    }
}

extension AccountProfileReuseError: ClientLocalizedError {
    var clientErrorDescription: String {
        L10n.tr("此服务器存在多个属于同一账户的本机配置，请从账户菜单选择目标配置后重试登录。")
    }
}

extension PublicShareError: ClientLocalizedError {
    var clientErrorDescription: String { L10n.diagnostic(clientDiagnostic) }
}
extension PublicShareStorageError: ClientLocalizedError {
    var clientErrorDescription: String { L10n.diagnostic(clientDiagnostic) }
}
extension PublicShareProgressSyncFailure: ClientLocalizedError {
    var clientErrorDescription: String { L10n.diagnostic(clientDiagnostic) }
}
