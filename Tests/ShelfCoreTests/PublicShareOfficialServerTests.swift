import Foundation
import Testing
@testable import ShelfCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PUBLIC_SHARE_OFFICIAL_MANIFEST"] != nil))
struct PublicShareOfficialServerTests {
    @Test func fixedReleaseAnonymousContract() async throws {
        let manifest = ProcessInfo.processInfo.environment["PUBLIC_SHARE_OFFICIAL_MANIFEST"]!
        let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as! [[String: Any]]
        #expect(entries.count == 2)
        for entry in entries {
            let location = try PublicShareLocation(link: URL(string: entry["link"] as! String)!)
            let store = MemoryPublicShareStateStore(), client = PublicShareClient(location: location, stateStore: MemoryPublicShareStateStore())
            let snapshot = try await client.open()
            #expect(snapshot.serverVersion == entry["version"] as? String)
            #expect(snapshot.tracks.count == 2 && snapshot.isDownloadable)
            let files = entry["trackFiles"] as! [String]
            for (offset, track) in snapshot.tracks.enumerated() {
                let original = try Data(contentsOf: URL(fileURLWithPath: files[offset]))
                let read = try await client.readTrackRange(index: track.index, offset: 0, length: 1024, handle: snapshot.handle)
                #expect(read.data == original.prefix(1024)); #expect(read.totalLength == Int64(original.count))
            }
            #expect(try await client.cover(handle: snapshot.handle) != nil)
            let ack = try await client.syncProgress(currentTime: 1.25, handle: snapshot.handle)
            #expect(ack.remoteAcknowledged)
            let reopened = try await client.reopen(); #expect(abs(reopened.currentTime - 1.25) < 0.01)
            let download = try await client.download(handle: reopened.handle)
            let archive = try Data(contentsOf: download.fileURL)
            #expect(archive.prefix(2) == Data("PK".utf8))
            try FileManager.default.removeItem(at: download.fileURL.deletingLastPathComponent())
            try await client.retire(handle: reopened.handle)
            // A fresh independent anonymous namespace has no account progress or cookie.
            let fresh = PublicShareClient(location: location, stateStore: store)
            #expect(try await fresh.open().currentTime == 0)
        }
    }
}
