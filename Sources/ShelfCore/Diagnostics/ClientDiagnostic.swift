import Foundation

/// A language-independent snapshot of a client-owned error. Arbitrary server or
/// system text stays in arguments/fallback and is never used as a resource key.
public struct ClientDiagnostic: Codable, Hashable, Sendable, LocalizedError {
    public let schemaVersion: Int
    public let code: String
    public let arguments: [String]
    public let fallbackMessage: String
    public let causes: [ClientDiagnostic]

    public init(code: String, arguments: [String] = [], fallbackMessage: String,
                causes: [ClientDiagnostic] = [], schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.code = code; self.arguments = arguments
        self.fallbackMessage = fallbackMessage; self.causes = causes
    }
    public var errorDescription: String? { fallbackMessage }

    public static func capture(_ error: any Error) -> ClientDiagnostic {
        if let diagnostic = error as? ClientDiagnostic { return diagnostic }
        if let represented = error as? any ClientDiagnosticRepresentable { return represented.clientDiagnostic }
        let fallback = error.localizedDescription
        func make(_ code: String, _ arguments: [String] = []) -> ClientDiagnostic {
            .init(code: code, arguments: arguments, fallbackMessage: fallback)
        }
        if let error = error as? ABSError {
            switch error {
            case .invalidServerURL: return make("abs.invalidServerURL")
            case .invalidResourcePath: return make("abs.invalidResourcePath")
            case .untrustedResource: return make("abs.untrustedResource")
            case .notAuthenticated: return make("abs.notAuthenticated")
            case .sessionChanged: return make("abs.sessionChanged")
            case let .http(status, message): return make("abs.http", [String(status), message])
            case .invalidResponse: return make("abs.invalidResponse")
            case .unsupportedVersion(let version): return make("abs.unsupportedVersion", [version])
            case .invalidOIDCCallback: return make("abs.invalidOIDCCallback")
            }
        }
        if let error = error as? OfflineStorageError {
            switch error {
            case .invalidSession: return make("storage.invalidSession")
            case .sessionIdentityChanged: return make("storage.sessionIdentityChanged")
            case .unsafePath: return make("storage.unsafePath")
            case .incompleteDownload: return make("storage.incompleteDownload")
            case .insufficientSpace: return make("storage.insufficientSpace")
            case .accountChanged: return make("storage.accountChanged")
            }
        }
        if let error = error as? OfflineSyncError {
            switch error {
            case .verificationFailed: return make("sync.verificationFailed")
            case .progressChangedDuringResolution: return make("sync.progressChangedDuringResolution")
            case .alreadyRunning: return make("sync.alreadyRunning")
            }
        }
        if let error = error as? DownloadTransferError {
            switch error {
            case .invalidResponse: return make("download.invalidResponse")
            case .invalidRange: return make("download.invalidRange")
            case .sourceChanged: return make("download.sourceChanged")
            case .http(let status): return make("download.http", [String(status)])
            }
        }
        return make("system.verbatim")
    }
}

/// Feature modules can preserve their own typed errors without coupling Core to them.
public protocol ClientDiagnosticRepresentable: Error {
    var clientDiagnostic: ClientDiagnostic { get }
}
