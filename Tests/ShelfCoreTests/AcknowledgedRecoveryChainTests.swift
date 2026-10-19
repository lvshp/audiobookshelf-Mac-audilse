import Foundation
import Testing
@testable import ShelfCore

private func recoveryChainRow(id: String, start: Double, update: Double, position: Double,
                              acknowledgedPosition: Double? = nil, baseline: Double = 10) -> OfflinePlaybackSession {
    let acknowledged = acknowledgedPosition.map { position in
        PlaybackSyncAcknowledgement(session: .init(id: id, libraryItemId: "chain-book", duration: 100,
            currentTime: position, startedAt: start, updatedAt: update, timeListening: 10))
    }
    return .init(id: id, itemID: "chain-book", startedAt: start, updatedAt: update, currentTime: position,
        timeListening: 10, duration: 100, serverProgressUpdatedAt: 500, serverCurrentTime: baseline,
        serverFinished: false, ownAcknowledgement: acknowledged)
}

@Test func acknowledgedRecoveryChainUsesNewestEvidenceAndRejectsBrokenLinks() {
    let old = recoveryChainRow(id: "old", start: 1000, update: 2000, position: 40, acknowledgedPosition: 30)
    let recent = recoveryChainRow(id: "recent", start: 3000, update: 4000, position: 55, acknowledgedPosition: 50)
    let next = recoveryChainRow(id: "offline-one", start: 5000, update: 6000, position: 60)
    let latest = recoveryChainRow(id: "offline-two", start: 7000, update: 8000, position: 65)
    let remoteOld = SyncProgressSnapshot(itemID: "chain-book", currentTime: 30, duration: 100, isFinished: false, updatedAt: 9000)
    var remoteNewest = remoteOld; remoteNewest.currentTime = 50
    let chain = [old, recent, next, latest]
    #expect(OfflineSyncPolicy.conflicts(local: latest, remote: remoteOld, pendingSessions: chain))
    #expect(!OfflineSyncPolicy.conflicts(local: latest, remote: remoteNewest, pendingSessions: chain))
    let incompatible = recoveryChainRow(id: "offline-one", start: 5000, update: 6000, position: 60, baseline: 20)
    #expect(OfflineSyncPolicy.conflicts(local: latest, remote: remoteNewest, pendingSessions: [old, recent, incompatible, latest]))
    let overlapping = recoveryChainRow(id: "offline-one", start: 3500, update: 6000, position: 60)
    #expect(OfflineSyncPolicy.conflicts(local: latest, remote: remoteNewest, pendingSessions: [old, recent, overlapping, latest]))
}
