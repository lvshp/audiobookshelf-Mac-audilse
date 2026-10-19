import Foundation
import ShelfCore

extension PlaybackFailure: ClientDiagnosticRepresentable {
    public var clientDiagnostic: ClientDiagnostic {
        let code: String
        var arguments: [String] = []
        switch self {
        case .noTracks: code = "playback.noTracks"
        case .invalidTimeline: code = "playback.invalidTimeline"
        case .invalidStartPosition: code = "playback.invalidStartPosition"
        case .unsupportedLocalFormat(let format): code = "playback.unsupportedLocalFormat"; arguments = [format]
        case .unavailableService: code = "playback.unavailableService"
        case .invalidLocalFile: code = "playback.invalidLocalFile"
        case .invalidHLSManifest: code = "playback.invalidHLSManifest"
        case .streamNotReady: code = "playback.streamNotReady"
        case .seekInterrupted: code = "playback.seekInterrupted"
        }
        return .init(code: code, arguments: arguments, fallbackMessage: localizedDescription)
    }
}

#if canImport(VLCKit)
extension NativePCMCompatibilityFailure: ClientDiagnosticRepresentable {
    public var clientDiagnostic: ClientDiagnostic {
        .init(code: "playback.localEngineFailed", fallbackMessage: "本地兼容引擎无法播放此文件。")
    }
}
#endif
