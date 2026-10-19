import Foundation
import Testing
@testable import AudilseCore

struct PlaybackRatePolicyTests {
    @Test(arguments: [0.5, 0.75, 1, 1.2, 3, 4, 7.33, 10])
    func preservesSupportedSpeed(_ rate: Double) {
        #expect(PlaybackRatePolicy.normalized(rate) == rate)
    }

    @Test func boundsInvalidValues() {
        #expect(PlaybackRatePolicy.normalized(0.1) == 0.5)
        #expect(PlaybackRatePolicy.normalized(20) == 10)
        #expect(PlaybackRatePolicy.normalized(.nan) == 1)
        #expect(PlaybackRatePolicy.normalized(.infinity) == 1)
        #expect(PlaybackRatePolicy.normalized(-.infinity) == 1)
    }

    @Test func remoteRatesHaveExactStepsAndEngineBounds() {
        let fine = PlaybackRatePolicy.rates(step: 0.05)
        let coarse = PlaybackRatePolicy.rates(step: 0.1)
        #expect(fine.count == 191 && coarse.count == 96)
        #expect(fine.first == 0.5 && fine.last == 10)
        #expect(coarse.first == 0.5 && coarse.last == 10)
        #expect(Set(fine).count == fine.count && Set(coarse).count == coarse.count)
        #expect(PlaybackRatePolicy.rates(step: 0.05, maximum: 4).count == 71)
        #expect(PlaybackRatePolicy.rates(step: 0.1, minimum: 1, maximum: 2).count == 11)
        #expect(PlaybackRatePolicy.rates(step: .nan) == coarse)
    }

    @Test func presetsAreSharedAndIncludeWebValuesAndUpperBound() {
        let presets = PlaybackRatePolicy.presets
        #expect(presets == presets.sorted())
        #expect(Set(presets).count == presets.count)
        #expect([0.5, 1, 1.2, 1.5, 2, 4, 10].allSatisfy(presets.contains))
        #expect(presets.allSatisfy { (0.5...10).contains($0) })
    }

    @Test func adjustmentRoundsWithoutHidingAnUnsupportedStep() {
        #expect(PlaybackRatePolicy.adjusted(9.95, by: 0.05) == 10)
        #expect(PlaybackRatePolicy.adjusted(9.95, by: 0.1) > 10)
        #expect(PlaybackRatePolicy.adjusted(0.55, by: -0.05) == 0.5)
        #expect(PlaybackRatePolicy.adjusted(3.95, by: 0.05) == 4)
        #expect(PlaybackRatePolicy.adjusted(1.1, by: 0.1) == 1.2)
    }
}
