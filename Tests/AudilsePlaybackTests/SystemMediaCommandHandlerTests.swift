import Foundation
@preconcurrency import MediaPlayer
import Testing
@testable import AudilsePlayback

@MainActor @Test func remoteCommandHandlerRunsOffMainAndDeliversOnMainActor() async throws {
    var delivered = false
    // MediaPlayer forbids constructing its event objects outside the framework.
    // Exercise the same generic callback with a value event, without private APIs.
    let handler = SystemMediaCommandHandler.make(extract: { (_: Int) in .rate(2.5) }) { command in
        #expect(Thread.isMainThread)
        if case .rate(let rate) = command { #expect(rate == 2.5) }
        else { Issue.record("Unexpected command") }
        delivered = true
    }
    let accepted = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            #expect(!Thread.isMainThread)
            continuation.resume(returning: handler(1) == .success)
        }
    }
    #expect(accepted)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !delivered && ContinuousClock.now < deadline { await Task.yield() }
    #expect(delivered)
}

@MainActor @Test func invalidRemoteEventFailsSynchronouslyWithoutSchedulingControllerWork() async {
    let handler = SystemMediaCommandHandler.make(extract: { (_: Int) in nil }) { _ in
        Issue.record("Invalid event reached controller")
    }
    let rejected = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: handler(0) == .commandFailed)
        }
    }
    #expect(rejected)
}
