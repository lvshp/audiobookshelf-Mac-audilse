import Foundation
@preconcurrency import MediaPlayer

enum SystemMediaCommandHandler {
    /// MediaPlayer may invoke these synchronous callbacks from a private queue.
    /// Extract only Sendable command values there; controller work stays on MainActor.
    nonisolated static func make<Event>(
        extract: @escaping @Sendable (Event) -> PlaybackSystemMediaCommand?,
        deliver: @escaping @MainActor @Sendable (PlaybackSystemMediaCommand) -> Void
    ) -> @Sendable (Event) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let command = extract(event) else { return .commandFailed }
            Task { @MainActor in deliver(command) }
            return .success
        }
    }
}
