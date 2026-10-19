import Foundation

/// Packaged apps resolve resources inside their own Contents/Resources folder.
/// SwiftPM's generated accessor may instead use the app root or an absolute
/// build-machine path, so it is only used for an unbundled development executable.
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "Audilse_Audilse", withExtension: "bundle"),
           let packaged = Bundle(url: url) {
            return packaged
        }
        #if SWIFT_PACKAGE
        if Bundle.main.bundleURL.pathExtension != "app" { return Bundle.module }
        #endif
        return Bundle.main
    }()

    static var readerURL: URL? {
        bundle.url(forResource: "reader", withExtension: "html", subdirectory: "Reader")
            ?? bundle.url(forResource: "reader", withExtension: "html")
    }

    /// Called by packaging from a relocated app, with the source tree unreadable.
    /// This uses the same localization and reader lookup paths as the interface.
    static func verifyPackagedResources() throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ResourceFailure(message: message) }
        }
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        try require(Bundle.main.bundleURL.pathExtension == "app", "Expected a packaged application.")
        try require(bundle.resourceURL?.resolvingSymlinksInPath().path.hasPrefix(root) == true, "Resources resolved outside the application.")
        for language in AppLanguage.allCases {
            guard let url = bundle.resourceURL?.appendingPathComponent(language.rawValue + ".lproj/Localizable.strings") else {
                throw ResourceFailure(message: "Missing localization: \(language.rawValue)")
            }
            try require(FileManager.default.isReadableFile(atPath: url.path), "Missing localization: \(language.rawValue)")
            let expected = language == .english ? "Play" : "播放"
            try require(L10n.tr("播放", language: language) == expected, "Localization lookup failed: \(language.rawValue)")
        }
        guard let reader = readerURL else { throw ResourceFailure(message: "Missing reader.html") }
        let directory = reader.deletingLastPathComponent()
        try require(directory.resolvingSymlinksInPath().path.hasPrefix(root), "Reader resolved outside the application.")
        for name in ["reader.html", "reader-bridge.js", "epub.min.js", "jszip.min.js", "foliate-mobi.js",
                     "EPUB-LICENSE.txt", "JSZIP-LICENSE.txt", "FOLIATE-LICENSE.txt", "VERSIONS.txt"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            try require(!data.isEmpty, "Empty reader resource: \(name)")
        }
    }

    private struct ResourceFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
