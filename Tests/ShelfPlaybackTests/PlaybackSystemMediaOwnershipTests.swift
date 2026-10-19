import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import ShelfPlayback

@Suite(.serialized) @MainActor struct PlaybackSystemMediaOwnershipTests {
    @Test func inactiveControllerCannotConfigureOrClearAnotherOwnersNowPlaying() async throws {
        let owner = PlaybackController()
        let inactive = PlaybackController(ownsSystemMediaControls: false)
        #expect(owner.ownsSystemMediaControls && !inactive.ownsSystemMediaControls)
        owner.configureRemoteCommands(jumpForward: 45, jumpBackward: 15, rateStep: 0.05)
        inactive.configureRemoteCommands(jumpForward: 90, jumpBackward: 90, rateStep: 0.1)
        #expect(MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals == [45])
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Owned sentinel"]
        _ = await inactive.stop()
        if owner.ownsSystemMediaControls {
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Owned sentinel")
        }
        _ = await inactive.shutdownForQuit(); _ = await owner.shutdownForQuit()
    }
    @Test func oldQueuedCommandsAndWakeCannotSurviveOwnershipTransferOrReacquisition() async throws {
        let first = PlaybackController()
        let token = try #require(first.systemMediaControlToken)
        first.enqueueSystemMediaCommand(.rate(3), token: token)
        let second = PlaybackController()
        #expect(!first.ownsSystemMediaControls && second.ownsSystemMediaControls)
        first.setSystemMediaControlsActive(true)
        #expect(first.systemMediaControlToken != token && !second.ownsSystemMediaControls)
        first.enqueueSystemMediaCommand(.rate(4), token: token)
        first.enqueueSystemMediaCommand(.wake, token: token)
        await Task.yield()
        #expect(first.requestedRate == 1 && !first.isPlaybackRequested)
        _ = await second.shutdownForQuit(); _ = await first.shutdownForQuit()
    }
}
