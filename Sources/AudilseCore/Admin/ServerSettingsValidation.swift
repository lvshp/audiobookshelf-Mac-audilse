import Foundation

/// ABS Web backup boundaries and integer notification inputs. Values are
/// validated when submitted; opening a form must never clamp server settings.
public enum ServerSettingsValidation {
    public static func validBackup(maximumSizeGB: Double, retainedCount: Int) -> Bool {
        maximumSizeGB.isFinite && maximumSizeGB >= 0 && (1...99).contains(retainedCount)
    }

    public static func positiveInteger(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }
}
