import Foundation

public enum LogoutScope: Hashable, Sendable {
    case currentDevice
    case allDevices
}

/// A 2xx logout response contains no session count. This records that the
/// request completed, not that existing access JWTs or API keys were revoked.
public enum LogoutResult: Hashable, Sendable {
    case currentDevice
    case allDevicesRequested
}

public enum AllDevicesLogoutEligibility: Hashable, Sendable {
    case available
    case unsupportedServer
    case missingRefreshToken
    case accountMismatch
}

public enum LogoutPolicyError: Error, Hashable, Sendable {
    case unavailable(AllDevicesLogoutEligibility)
}

/// Scoped and automatic reauthentication failures distinguish local credential
/// cleanup from a failed remote request. Default logout preserves its old errors.
public struct LogoutError: Error, Sendable {
    public let localCredentialsRemoved: Bool
    public let underlyingError: any Error

    public init(localCredentialsRemoved: Bool, underlyingError: any Error) {
        self.localCredentialsRemoved = localCredentialsRemoved
        self.underlyingError = underlyingError
    }
}

/// credentialOperation checks retirement again after the awaited store call.
/// Preserve the completed removal's receipt even when that final check throws.
final class LogoutCredentialRemovalReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func recordCompletion() { lock.withLock { completed = true } }
    var isComplete: Bool { lock.withLock { completed } }
}
