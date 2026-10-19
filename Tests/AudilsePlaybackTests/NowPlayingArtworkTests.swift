import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import AppKit
@preconcurrency import MediaPlayer
import Testing
@testable import AudilsePlayback

private func artworkPNG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8,
                                        bytesPerRow: 16 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

// The test deliberately calls the real MediaPlayer API across the queue
// boundary that crashed in production. Only observations cross back to MainActor.
private struct BackgroundArtwork: @unchecked Sendable {
    let value: MPMediaItemArtwork
}
private struct ArtworkObservation: Sendable {
    let ranOffMain: Bool
    let width: Int
    let height: Int
    let encodedBytes: Int
}

@MainActor @Test func nowPlayingArtworkCreatedOnMainActorSupportsRealBackgroundImageRequests() async throws {
    let artwork = try #require(NowPlayingArtworkFactory.make(data: artworkPNG()))
    let shared = BackgroundArtwork(value: artwork)
    for side in [12, 24, 48, 96] {
        let observation: ArtworkObservation = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    let image = shared.value.image(at: CGSize(width: side, height: side))
                    let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    continuation.resume(returning: ArtworkObservation(ranOffMain: !Thread.isMainThread,
                        width: pixels?.width ?? 0, height: pixels?.height ?? 0,
                        encodedBytes: image?.tiffRepresentation?.count ?? 0))
                }
            }
        }
        #expect(observation.ranOffMain)
        #expect(observation.width == 16 && observation.height == 12)
        #expect(observation.encodedBytes > 0)
    }
}

@Test func nowPlayingArtworkRejectsInvalidImageData() {
    #expect(NowPlayingArtworkFactory.make(data: Data()) == nil)
    #expect(NowPlayingArtworkFactory.make(data: Data("not an image".utf8)) == nil)
}
