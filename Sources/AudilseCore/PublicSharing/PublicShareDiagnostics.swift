import Foundation

extension PublicShareError: ClientDiagnosticRepresentable {
    public var clientDiagnostic: ClientDiagnostic {
        let suffix: String
        var arguments: [String] = []
        switch self {
        case .invalidLink: suffix = "invalidLink"
        case .untrustedResource: suffix = "untrustedResource"
        case .unavailable: suffix = "unavailable"
        case .downloadForbidden: suffix = "downloadForbidden"
        case .sessionChanged: suffix = "sessionChanged"
        case .stateConflict: suffix = "stateConflict"
        case .localStateUnavailable: suffix = "localStateUnavailable"
        case .invalidResponse: suffix = "invalidResponse"
        case .responseTooLarge: suffix = "responseTooLarge"
        case .invalidRange: suffix = "invalidRange"
        case .rangeIgnored: suffix = "rangeIgnored"
        case .closed: suffix = "closed"
        case .progressSuperseded: suffix = "progressSuperseded"
        case .rangeNotSatisfiable: suffix = "rangeNotSatisfiable"
        case .http(let status): suffix = "http"; arguments = [String(status)]
        case .transport(let code): suffix = "transport"; arguments = [String(code)]
        }
        return .init(code: "publicShare." + suffix, arguments: arguments, fallbackMessage: errorDescription ?? "公开分享操作失败。")
    }
}
extension PublicShareProgressSyncFailure: ClientDiagnosticRepresentable, LocalizedError {
    public var clientDiagnostic: ClientDiagnostic {
        .init(code: checkpoint.remoteAcknowledged ? "publicShare.progressAckPersistenceFailed" : "publicShare.progressPending",
              fallbackMessage: checkpoint.remoteAcknowledged
                ? "服务器已确认位置，但本机确认标记保存失败；原检查点仍保留。"
                : "匿名播放位置已保存在本机，尚未确认服务器进度。",
              causes: [reason.clientDiagnostic])
    }
    public var errorDescription: String? { clientDiagnostic.fallbackMessage }
}
extension PublicShareStorageError: ClientDiagnosticRepresentable, LocalizedError {
    public var clientDiagnostic: ClientDiagnostic {
        let suffix: String, message: String
        var arguments: [String] = []
        switch self {
        case .invalidStorage: suffix = "invalidStorage"; message = "匿名分享的本机状态目录或文件不安全。"
        case .invalidState: suffix = "invalidState"; message = "匿名分享的本机状态无法解密或读取。"
        case .missingKey: suffix = "missingKey"; message = "匿名分享的加密密钥缺失，原状态已保留。"
        case .busy: suffix = "busy"; message = "另一个进程正在更新匿名分享状态，请稍后重试。"
        case .io(let code): suffix = "io"; arguments = [String(code)]; message = "无法读写匿名分享的本机状态（\(code)）。"
        }
        return .init(code: "publicShare.storage." + suffix, arguments: arguments, fallbackMessage: message)
    }
    public var errorDescription: String? { clientDiagnostic.fallbackMessage }
}
