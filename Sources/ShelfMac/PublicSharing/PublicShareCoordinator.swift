import Foundation
import Observation
import ShelfCore
import ShelfPlayback

@MainActor @Observable
final class PublicShareCoordinator {
    private(set) var player: PlaybackController?
    private(set) var snapshot: PublicShareSnapshot?
    private(set) var link: URL?
    private(set) var coverData: Data?
    private(set) var isActive = false
    private(set) var isOpening = false
    private(set) var isTransitioning = false
    private(set) var diagnostic: ClientDiagnostic?
    private(set) var identity = UUID()
    @ObservationIgnored private var client: PublicShareClient?
    @ObservationIgnored private var openingID = UUID()
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private let stateStore: any PublicShareStateStore

    init(stateStore: any PublicShareStateStore = LocalPublicShareStateStore.shared) {
        self.stateStore = stateStore
    }
    private var requestedRate: Double {
        get { PlaybackRatePolicy.normalized(UserDefaults.standard.object(forKey: "publicShare.playbackRate") as? Double ?? 1) }
        set { UserDefaults.standard.set(PlaybackRatePolicy.normalized(newValue), forKey: "publicShare.playbackRate") }
    }

    func cancelOpening() {
        openingTask?.cancel()
        openingID = UUID()
        isOpening = false
    }

    /// The caller checkpoints its account player and validates its account epoch
    /// before allowing this independent context to take the system controls.
    func open(_ url: URL, acquire: @escaping @MainActor () async -> Bool) async {
        guard !isTransitioning else { return }
        let previous = openingTask
        previous?.cancel()
        let operation = UUID()
        openingID = operation
        isOpening = true
        diagnostic = nil
        let task = Task { [weak self] in
            // Finish cancellation/retirement before another client touches the
            // same anonymous state file, including rapid reopen after Cancel.
            if let previous { await previous.value }
            guard let self, !Task.isCancelled, self.openingID == operation else { return }
            await self.performOpen(url, operation: operation, acquire: acquire)
        }
        openingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if openingID == operation { openingTask = nil; isOpening = false }
    }

    private func performOpen(_ url: URL, operation: UUID, acquire: @MainActor () async -> Bool) async {
        var candidate: PublicShareClient?
        var prepared: PublicShareSnapshot?
        var adopted = false
        defer { if openingID == operation { isOpening = false } }
        do {
            let location = try PublicShareLocation(link: url)
            let sameSource = link.flatMap { try? PublicShareLocation(link: $0).storageKey } == location.storageKey && player != nil
            if sameSource {
                // Opening another client first would invalidate the current
                // client's CAS baseline before its final checkpoint can save.
                guard await acquire() else { throw CancellationError() }
                try requireOpening(operation)
                guard await stop() else { throw CancellationError() }
                try requireOpening(operation)
            }
            let source = PublicShareClient(location: location, stateStore: stateStore)
            candidate = source
            let loaded = try await source.open()
            prepared = loaded
            try requireOpening(operation)
            if !sameSource {
                // Both contexts must be safe before retiring the old share.
                guard await acquire() else { throw CancellationError() }
                try requireOpening(operation)
                guard await stop() else { throw CancellationError() }
                try requireOpening(operation)
            }
            let service = PublicSharePlaybackService(client: source, snapshot: loaded)
            let controller = PlaybackController(ownsSystemMediaControls: false, service: service, persist: { session in
                try await service.persist(session)
            })
            controller.setRate(Float(requestedRate))
            controller.onRemoteRateChange = { [weak self, weak controller] value in
                guard let self, let controller, self.player === controller, self.isActive else { return }
                self.setRate(Double(value), for: controller)
            }
            identity = UUID()
            player = controller
            client = source
            snapshot = loaded
            link = url
            coverData = nil
            isActive = true
            isOpening = false
            adopted = true
            controller.setSystemMediaControlsActive(true)
            await controller.play(media: service.media)
            guard openingID == operation, player === controller else { return }
            diagnostic = controller.errorDiagnostic
            if loaded.hasCover {
                let expected = identity
                coverTask?.cancel()
                coverTask = Task { [weak self] in
                    let data = try? await source.cover(handle: loaded.handle)
                    guard !Task.isCancelled, let self, self.identity == expected,
                          self.player === controller else { return }
                    self.coverData = data
                }
            }
        } catch is CancellationError {
            // The new request may be superseded; its results cannot acquire controls.
        } catch {
            if openingID == operation { diagnostic = .capture(error) }
        }
        if !adopted, let candidate, let prepared {
            // No playback used this candidate, so no playback receipt is lost.
            try? await candidate.retire(handle: prepared.handle)
        }
    }

    func setRate(_ value: Double, for expected: PlaybackController) {
        guard player === expected, isActive, !isTransitioning, value.isFinite else { return }
        requestedRate = value
        expected.setRate(Float(requestedRate))
    }

    /// Stop and retire only after the controller has a safe final position receipt.
    /// Anonymous positions are durable; anonymous listening time is not account history.
    @discardableResult func checkpoint() async -> Bool {
        guard !isTransitioning else { return false }
        guard let previous = player else { return true }
        isTransitioning = true
        defer { isTransitioning = false }
        let expected = identity
        let receipt = await previous.checkpointForTransition()
        guard identity == expected, player === previous else { return false }
        if !receipt.mayQuit { diagnostic = receipt.diagnostic }
        return receipt.mayQuit
    }

    @discardableResult func stop() async -> Bool {
        guard !isTransitioning else { return false }
        guard let previous = player else { return true }
        isTransitioning = true
        defer { isTransitioning = false }
        let source = client, document = snapshot, expected = identity
        let checkpoint = await previous.checkpointForTransition()
        guard identity == expected, player === previous else { return false }
        guard checkpoint.mayQuit else {
            diagnostic = checkpoint.diagnostic
            return false
        }
        let terminal = await previous.shutdownForQuit()
        guard identity == expected, player === previous else { return false }
        guard terminal.mayQuit else { diagnostic = terminal.diagnostic; return false }
        do {
            if let source, let document { try await source.retire(handle: document.handle) }
            guard identity == expected, player === previous else { return false }
            previous.setSystemMediaControlsActive(false)
            coverTask?.cancel(); coverTask = nil
            player = nil; client = nil; snapshot = nil; coverData = nil
            isActive = false
            identity = UUID()
            return true
        } catch {
            // Keep both references so a failed retirement can be retried.
            diagnostic = .capture(error)
            return false
        }
    }

    func export() async throws -> PublicShareExport {
        guard !isOpening, !isTransitioning, let client, let snapshot,
              snapshot.isDownloadable else { throw PublicShareError.downloadForbidden }
        let expected = identity
        let result = try await client.download(handle: snapshot.handle)
        guard identity == expected, self.client === client, self.snapshot?.handle == snapshot.handle,
              !Task.isCancelled else {
            try? FileManager.default.removeItem(at: result.fileURL.deletingLastPathComponent())
            throw CancellationError()
        }
        return result
    }

    private func requireOpening(_ operation: UUID) throws {
        guard openingID == operation, !Task.isCancelled else { throw CancellationError() }
    }
}
