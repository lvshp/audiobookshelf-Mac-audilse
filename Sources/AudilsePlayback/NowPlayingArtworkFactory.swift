import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import AppKit
@preconcurrency import MediaPlayer

/// MediaPlayer requests artwork synchronously on its own queues. Construct the
/// handler outside MainActor and share only immutable decoded pixels, never an
/// NSImage whose representations or size could be mutated by another caller.
enum NowPlayingArtworkFactory {
    private struct Pixels: @unchecked Sendable {
        // CGImage is immutable. This wrapper also supports SDKs that predate its
        // explicit Sendable annotation; no mutable ImageIO source is retained.
        let image: CGImage
    }

    nonisolated static func make(data: Data) -> MPMediaItemArtwork? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let pixels = Pixels(image: image)
        let size = CGSize(width: image.width, height: image.height)
        let request: @Sendable (CGSize) -> NSImage = { _ in
            NSImage(cgImage: pixels.image, size: size)
        }
        return MPMediaItemArtwork(boundsSize: size, requestHandler: request)
    }
}
