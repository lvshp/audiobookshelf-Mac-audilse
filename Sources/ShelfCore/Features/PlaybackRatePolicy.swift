import Foundation

/// ABS v2.37.1's speed range. Engine capabilities can narrow the effective range
/// without overwriting the account's preferred speed.
public enum PlaybackRatePolicy {
    public static let minimum = 0.5
    public static let maximum = 10.0
    public static let presets: [Double] = [0.5, 0.75, 1, 1.1, 1.2, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8, 10]

    public static func normalized(_ value: Double) -> Double {
        min(maximum, max(minimum, value.isFinite ? value : 1))
    }

    public static func adjusted(_ value: Double, by amount: Double) -> Double {
        guard value.isFinite, amount.isFinite else { return normalized(value) }
        return ((value + amount) * 100).rounded() / 100
    }

    public static func rates(step: Double, minimum lower: Double = minimum, maximum upper: Double = maximum) -> [Double] {
        let increment = step == 0.05 ? 5 : 10
        return stride(from: 50, through: 1_000, by: increment).map { Double($0) / 100 }
            .filter { $0 >= lower && $0 <= upper }
    }
}
