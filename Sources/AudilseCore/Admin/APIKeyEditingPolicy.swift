import Foundation

public enum APIKeyLifetimeUnit: String, CaseIterable, Codable, Sendable {
    case seconds, minutes, hours, days
    public var multiplier: Double {
        switch self { case .seconds: 1; case .minutes: 60; case .hours: 3_600; case .days: 86_400 }
    }
}

/// The existing JWT name and expiry are immutable. Only identity and activation
/// are supported by PATCH. Callers must obtain fresh keys/users after confirmation.
public enum APIKeyEditingPolicy {
    public static func lifetime(value: Double, unit: APIKeyLifetimeUnit) -> Double? {
        let seconds = value * unit.multiplier
        // The server stores expiry in a JavaScript Date; reject overflow rather
        // than emitting a non-finite JSON number or an invalid expiration date.
        guard value.isFinite, value > 0, seconds.isFinite, seconds >= 1,
              seconds.rounded(.towardZero) == seconds, seconds <= 8_000_000_000_000 else { return nil }
        return seconds
    }

    public static func mayAssign(userType: String, administratorType: String) -> Bool {
        (administratorType == "admin" || administratorType == "root") && (userType != "root" || administratorType == "root")
    }

    public static func unchanged(_ current: APIKeyRecord, since original: APIKeyRecord) -> Bool {
        current.id == original.id && current.userId == original.userId && current.isActive == original.isActive &&
        current.expiresAt == original.expiresAt && current.name == original.name && current.updatedAt == original.updatedAt
    }

    public static func mayEnable(_ key: APIKeyRecord, now: Date = Date()) -> Bool {
        guard !key.isActive, let expiry = key.expiresAt else { return true }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry)
        return date.map { $0 > now } ?? false
    }
}
