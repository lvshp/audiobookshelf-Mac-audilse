import Foundation
import Observation
import SwiftUI
import AudilseCore
import AudilsePlayback

/// Keep the lifecycle marker while any old task still owns its client, without
/// retaining every client or confusing a reused ObjectIdentifier with its source.
@MainActor final class TrackedServerClient {
    let endpoint: String
    weak var client: ABSClient?
    var isRetired = false
    init(endpoint: String, client: ABSClient) { self.endpoint = endpoint; self.client = client }
}

private struct PlaybackSessionMutationLease {
    let id = UUID()
    let ids: Set<String>
    let source: ServerPlaybackSessionsSource
    let sync: SyncCoordinator
    let database: ShelfDatabase
    let player: PlaybackController?
    let deleting: Bool
}

@MainActor @Observable
final class AppStore {
    var profiles: [ServerProfile] = []
    var profile: ServerProfile?
    var user: UserAccount? {
        didSet {
            if user?.id != oldValue?.id || user.map({ AdminPolicy.allows(.manageServer, user: $0) }) != true {
                clearServerTaskActivity()
            }
        }
    }
    var libraries: [Library] = []
    var items: [AudilseCore.LibraryItem] = []
    var progressByItem: [String: MediaProgress] = [:]
    var browsingLibraryID: String?
    var route: ShelfRoute = .home {
        didSet {
            if case let .library(id) = route { browsingLibraryID = id }
            if let browseNavigation, route != .library(browseNavigation.libraryID) { self.browseNavigation = nil }
        }
    }
    var search = ""
    private(set) var browseNavigation: LibraryBrowseNavigation?
    var totalItems = 0
    var libraryRevision = UUID()
    var isLoading = false
    var isConnecting = false
    var isOffline = false
    var isDemo = false
    var showConnection = false
    var selectedItem: AudilseCore.LibraryItem?
    var detailLoadingItemID: String?
    var errorMessage: String? { didSet { errorDiagnostic = nil } }
    private(set) var errorDiagnostic: ClientDiagnostic?
    var displayErrorMessage: String? { errorDiagnostic.map(L10n.diagnostic) ?? errorMessage }

    func presentError(_ diagnostic: ClientDiagnostic) {
        errorMessage = diagnostic.fallbackMessage
        errorDiagnostic = diagnostic
    }
    private(set) var serverTaskActivity = ServerTaskActivitySession()
    @ObservationIgnored private var taskActivitySubscribers: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]
    var notice: String?
    var conflicts: [SyncConflict] = []
    var readingConflicts: [ReadingConflict] = []
    var readingIsActive = false
    var readingActivityID: UUID?
    var player: PlaybackController?
    let publicSharing = PublicShareCoordinator()
    var activePlayer: PlaybackController? { publicSharing.isActive ? publicSharing.player : player }
    private(set) var playbackPreferences = ClientPreferences()
    var downloads: DownloadManager?
    private(set) var serverRecovery: ServerRestoreBatch?
    private(set) var recoveryBusy = false
    private(set) var recoveryError: String?
    private(set) var restoreArchives: [ServerRestoreBatch] = []
    private(set) var accountReauthenticationRequired = false
    var appearance: Appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "system") ?? .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }
    @ObservationIgnored var client: ABSClient?
    @ObservationIgnored var database: ShelfDatabase?
    @ObservationIgnored var sync: SyncCoordinator?
    @ObservationIgnored var readingRepository: ReadingRepository?
    @ObservationIgnored var readingShutdown: (@MainActor @Sendable () async throws -> Void)?
    @ObservationIgnored private var hasBootstrapped = false
    @ObservationIgnored private var page = 0
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var accountEpoch = UUID()
    @ObservationIgnored private var accountRefreshID = UUID()
    @ObservationIgnored private var accountAccessRefreshPending = false
    @ObservationIgnored private var forcedSignOutOperations: Set<UUID> = []
    @ObservationIgnored private var accountUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryReadingShutdown: (@MainActor @Sendable () async throws -> Void)?
    @ObservationIgnored private var playbackCallbackEpoch = UUID()
    @ObservationIgnored private var playRequestID = UUID()
    @ObservationIgnored private var playbackSessionMutations: [UUID: PlaybackSessionMutationLease] = [:]
    private var hasCurrentPlaybackSessionMutation: Bool {
        playbackSessionMutations.values.contains { $0.source.isCurrent(store: self) }
    }
    @ObservationIgnored private var detailRequestID = UUID()
    private struct RetiredPlayback {
        let handle: PlaybackRecoveryHandle
        let partition: AccountPartition?
    }
    @ObservationIgnored private var retiredPlayback: [UUID: RetiredPlayback] = [:]
    @ObservationIgnored private var playbackBaselines: [AccountPartition: [String: MediaProgress]] = [:]
    @ObservationIgnored private var remoteProgressByItem: [String: MediaProgress] = [:]
    @ObservationIgnored private var serverProgressIsFresh = false
    @ObservationIgnored private var downloadDirectory: URL?
    @ObservationIgnored private var supportDirectory: URL?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryRestartConfirmed: UUID?
    @ObservationIgnored private var restoringEndpoints: Set<String> = []
    @ObservationIgnored private var trackedClients: [ObjectIdentifier: TrackedServerClient] = [:]
    @ObservationIgnored private var credentialWrites: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored private var restoreEvents: ABSRealtimeClient?
    @ObservationIgnored private var restoreEventTask: Task<Void, Never>?

    var partition: AccountPartition? {
        guard let profile, let userID = profile.userID else { return nil }
        return AccountPartition(serverID: profile.id, userID: userID)
    }
    var currentLibrary: Library? {
        if case let .library(id) = route { return libraries.first { $0.id == id } }
        let candidates: [Library]
        if case let .feature(kind) = route, [.authors, .series, .collections].contains(kind) {
            candidates = libraries.filter { $0.mediaType == "book" }
        } else { candidates = libraries }
        if let browsingLibraryID, let selected = candidates.first(where: { $0.id == browsingLibraryID }) { return selected }
        return candidates.first { $0.mediaType == "book" } ?? candidates.first
    }
    var canDownload: Bool { user?.isActive == true && user?.permissions.download == true }
    var accountOperationID: UUID { accountEpoch }

    func browse(libraryID: String, filter: LibraryBrowseFilter) {
        guard !isDemo, !isConnecting, user?.isActive == true, let partition,
              let library = libraries.first(where: { $0.id == libraryID }),
              filter.isAvailable(mediaType: library.mediaType, user: user) else { return }
        browseNavigation = .init(partition: partition, client: client.map(ObjectIdentifier.init), libraryID: libraryID, filter: filter)
        search = ""
        route = .library(libraryID)
    }

    @discardableResult func consumeBrowseNavigation(id: UUID, libraryID: String) -> Bool {
        guard let navigation = browseNavigation, navigation.id == id,
              navigation.isCurrent(in: self, libraryID: libraryID) else { return false }
        browseNavigation = nil
        return true
    }

    var canPublish: Bool {
        guard !isDemo, !isOffline, client != nil, let user else { return false }
        return PersonalCapabilities(user: user, version: profile?.serverVersion).canPublish
    }

    func savePlaybackPreferences(_ preferences: ClientPreferences, for account: AccountPartition) throws {
        guard partition == account, user?.isActive == true, !isDemo, !isConnecting else { throw CancellationError() }
        try PersonalPlaybackPreferencesStore.shared.save(preferences, for: account)
        playbackPreferences = PersonalPlaybackPreferencesStore.shared.preferences(for: account)
        applyPlaybackPreferences()
    }

    func setPlaybackRate(_ rate: Double, for expectedPlayer: PlaybackController) {
        if publicSharing.isActive, publicSharing.player === expectedPlayer {
            publicSharing.setRate(rate, for: expectedPlayer)
            return
        }
        guard player === expectedPlayer, rate.isFinite, !isConnecting, let partition else { return }
        var preferences = playbackPreferences
        preferences.playbackRate = rate
        do { try savePlaybackPreferences(preferences, for: partition) }
        catch is CancellationError { }
        catch { errorMessage = L10n.error(error) }
    }

    func adjustPlaybackRate(_ direction: Double, for expectedPlayer: PlaybackController) {
        let step = playbackPreferences.playbackRateIncrementDecrement
        let rate = ((Double(expectedPlayer.rate) + direction * step) * 100).rounded() / 100
        setPlaybackRate(rate, for: expectedPlayer)
    }

    private func applyPlaybackPreferences() {
        player?.setRate(Float(playbackPreferences.playbackRate))
        player?.configureRemoteCommands(jumpForward: Double(playbackPreferences.jumpForwardAmount),
                                       jumpBackward: Double(playbackPreferences.jumpBackwardAmount),
                                       rateStep: playbackPreferences.playbackRateIncrementDecrement)
        publicSharing.player?.configureRemoteCommands(jumpForward: Double(playbackPreferences.jumpForwardAmount),
                                                      jumpBackward: Double(playbackPreferences.jumpBackwardAmount),
                                                      rateStep: playbackPreferences.playbackRateIncrementDecrement)
    }

    func openPublicShare(_ value: String) async {
        guard !isConnecting, !recoveryBusy, !hasCurrentPlaybackSessionMutation else { return }
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            presentError(.capture(PublicShareError.invalidLink)); return
        }
        let epoch = accountEpoch
        let request = UUID(); playRequestID = request
        await publicSharing.open(url) { [weak self] in
            guard let self, self.accountEpoch == epoch, self.playRequestID == request,
                  !self.isConnecting, !self.recoveryBusy, !self.hasCurrentPlaybackSessionMutation, !Task.isCancelled else { return false }
            let previous = self.player
            if let previous {
                let receipt = await previous.checkpointForTransition()
                guard self.accountEpoch == epoch, self.playRequestID == request,
                      self.player === previous, !self.isConnecting, !self.recoveryBusy,
                      !self.hasCurrentPlaybackSessionMutation, !Task.isCancelled else { return false }
                guard receipt.mayQuit else {
                    if let diagnostic = receipt.diagnostic { self.presentError(diagnostic) }
                    return false
                }
            }
            return true
        }
        if !publicSharing.isActive { player?.setSystemMediaControlsActive(true) }
        else {
            publicSharing.player?.configureRemoteCommands(jumpForward: Double(playbackPreferences.jumpForwardAmount),
                                                          jumpBackward: Double(playbackPreferences.jumpBackwardAmount),
                                                          rateStep: playbackPreferences.playbackRateIncrementDecrement)
        }
    }

    private func acquireAccountPlayback(_ expected: PlaybackController, epoch: UUID, request: UUID) async -> Bool {
        guard accountEpoch == epoch, playRequestID == request, player === expected,
              !isConnecting, !recoveryBusy, !hasCurrentPlaybackSessionMutation, !Task.isCancelled else { return false }
        guard await publicSharing.stop() else {
            if let diagnostic = publicSharing.diagnostic { presentError(diagnostic) }
            return false
        }
        guard accountEpoch == epoch, playRequestID == request, player === expected,
              !isConnecting, !recoveryBusy, !hasCurrentPlaybackSessionMutation, !Task.isCancelled else { return false }
        expected.setSystemMediaControlsActive(true)
        return true
    }
    var continueItems: [AudilseCore.LibraryItem] {
        items.filter { item in
            guard let progress = progressByItem[item.id] else { return false }
            return progress.currentTime > 0 && !progress.isFinished
        }.sorted { (progressByItem[$0.id]?.lastUpdate ?? 0) > (progressByItem[$1.id]?.lastUpdate ?? 0) }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Audilse", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            supportDirectory = support
            let db = try ShelfDatabase(path: support.appendingPathComponent("Audilse.sqlite"))
            database = db
            let downloadRoot = support.appendingPathComponent("Downloads", isDirectory: true)
            downloadDirectory = downloadRoot
            downloads = DownloadManager(database: db, rootDirectory: downloadRoot)
            sync = SyncCoordinator(database: db)
            readingRepository = try ReadingRepository(rootDirectory: support.appendingPathComponent("Reading", isDirectory: true))
            try await reconcileCompletedRestores()
        } catch { errorMessage = L10n.format("无法打开本地书库：%1$@", String(describing: L10n.error(error))) }
        if let data = UserDefaults.standard.data(forKey: "serverProfiles") {
            profiles = (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") { await enterDemo(); return }
        if UserDefaults.standard.bool(forKey: "explicitSignedOut") { showConnection = true; return }
        if let saved = profiles.first { await restore(saved) }
    }

    func connect(name: String, address: String, username: String, password: String) async throws {
        guard !isConnecting, !recoveryBusy else { return }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConnectionFailure.invalidAddress
        }
        let checkpointEpoch = accountEpoch
        isConnecting = true
        do { try await checkpointReadingBeforeTransition(); try await checkpointPlaybackBeforeTransition() }
        catch { if accountEpoch == checkpointEpoch { isConnecting = false }; throw error }
        let epoch = beginAccountChange()
        defer { if accountEpoch == epoch { isConnecting = false } }
        let recovery = try await recoveryBeforeAuthentication(url: url)
        try requireCurrent(epoch)
        let endpoint = try ServerRestoreBatch.canonicalURL(url.absoluteString)
        let namedProfiles = profiles.filter { (try? ServerRestoreBatch.canonicalURL($0.baseURL.absoluteString)) == endpoint && $0.username == username }
        let preferredID = namedProfiles.first(where: { $0.id == profile?.id })?.id ??
            (namedProfiles.count == 1 ? namedProfiles[0].id : nil) ??
            ((try? profile.map { try ServerRestoreBatch.canonicalURL($0.baseURL.absoluteString) }) == endpoint ? profile?.id : nil)
        var next = namedProfiles.first(where: { $0.id == preferredID })
            ?? ServerProfile(name: name.isEmpty ? (url.host ?? "Audiobookshelf") : name, baseURL: url, username: username)
        // Keep authentication provisional until the server identifies the user;
        // a renamed or reassigned username must never overwrite another profile.
        let authorizationClient = trackedClient(profile: next, tokenStore: MemoryTokenStore())
        defer { Task { await authorizationClient.retireForServerRestore() } }
        _ = try await authorizationClient.status()
        try requireCurrent(epoch)
        let response = try await authorizationClient.login(username: username, password: password)
        let loginTokens = AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken, userID: response.user.id)
        try requireCurrent(epoch)
        next = await authorizationClient.profile
        try requireCurrent(epoch)
        next.username = response.user.username
        next = try AccountUpdatePolicy.reusingProfile(next, profiles: profiles, preferredID: preferredID)
        let loginAccount = next.id.uuidString
        try await persistOIDCCredentials(loginTokens, profile: next)
        guard accountEpoch == epoch else {
            try await removeCancelledCredentials(account: loginAccount, tokens: loginTokens, url: url, sourceClient: authorizationClient)
            throw CancellationError()
        }
        let nextClient = trackedClient(profile: next)
        if let recovery { try await finishServerRecovery(recovery, profile: next, client: nextClient, epoch: epoch) }
        guard await configure(profile: next, user: response.user, client: nextClient, epoch: epoch) else {
            try await removeCancelledCredentials(account: loginAccount, tokens: loginTokens, url: url, sourceClient: authorizationClient)
            throw CancellationError()
        }
        profiles.removeAll { $0.id == next.id }
        profiles.insert(next, at: 0)
        saveProfiles()
        showConnection = false
        await finishConnectionRefresh(epoch: epoch, client: nextClient)
    }

    func connectOIDC(name: String, address: String,
                     present: @MainActor @Sendable (URL, String) async throws -> URL) async throws {
        guard !isConnecting, !recoveryBusy else { return }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ConnectionFailure.invalidAddress
        }
        let checkpointEpoch = accountEpoch
        isConnecting = true
        do { try await checkpointReadingBeforeTransition(); try await checkpointPlaybackBeforeTransition() }
        catch { if accountEpoch == checkpointEpoch { isConnecting = false }; throw error }
        let epoch = beginAccountChange()
        defer { if accountEpoch == epoch { isConnecting = false } }
        let recovery = try await recoveryBeforeAuthentication(url: url)
        try requireCurrent(epoch)
        // The authenticated user is not known until the callback. Keep tokens
        // in memory until its existing server/user partition can be selected.
        let provisional = ServerProfile(name: name.isEmpty ? (url.host ?? "Audiobookshelf") : name, baseURL: url)
        let authorizationClient = trackedClient(profile: provisional, tokenStore: MemoryTokenStore())
        do {
            _ = try await authorizationClient.status()
            try requireCurrent(epoch)
            let authorization = try await authorizationClient.beginOIDC()
            try requireCurrent(epoch)
            let callback = try await present(authorization.authorizationURL, authorization.callbackScheme)
            try requireCurrent(epoch)
            let response = try await authorizationClient.completeOIDC(callbackURL: callback)
            try requireCurrent(epoch)
            var next = await authorizationClient.profile
            try requireCurrent(epoch)
            if let saved = profiles.first(where: {
                $0.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) && $0.userID == response.user.id
            }) { next.id = saved.id }
            let tokens = AuthTokens(accessToken: response.accessToken, refreshToken: response.refreshToken, userID: response.user.id)
            try await persistOIDCCredentials(tokens, profile: next)
            guard accountEpoch == epoch else {
                try await removeCancelledCredentials(account: next.id.uuidString, tokens: tokens, url: url, sourceClient: authorizationClient)
                throw CancellationError()
            }
            let nextClient = trackedClient(profile: next)
            if let recovery { try await finishServerRecovery(recovery, profile: next, client: nextClient, epoch: epoch) }
            guard await configure(profile: next, user: response.user, client: nextClient, epoch: epoch) else {
                try await removeCancelledCredentials(account: next.id.uuidString, tokens: tokens, url: url, sourceClient: authorizationClient)
                throw CancellationError()
            }
            profiles.removeAll { $0.id == next.id }; profiles.insert(next, at: 0); saveProfiles()
            showConnection = false
            await finishConnectionRefresh(epoch: epoch, client: nextClient)
        } catch {
            await authorizationClient.cancelOIDC()
            throw error
        }
    }

    func restore(_ saved: ServerProfile) async {
        guard !recoveryBusy, !isConnecting else { return }
        guard let userID = saved.userID, database != nil else { showConnection = true; return }
        let checkpointEpoch = accountEpoch
        isConnecting = true
        do { try await checkpointReadingBeforeTransition(); try await checkpointPlaybackBeforeTransition() }
        catch { if accountEpoch == checkpointEpoch { isConnecting = false; errorMessage = L10n.error(error) }; return }
        let epoch = beginAccountChange()
        defer { if accountEpoch == epoch { isConnecting = false } }
        do {
            let endpoint = try ServerRestoreBatch.canonicalURL(saved.baseURL.absoluteString)
            try await repairCompletedRecoveryIfNeeded(endpoint: endpoint)
            if let batch = try await database?.restoreGuard(profileID: saved.id, canonicalBaseURL: endpoint) {
                try requireCurrent(epoch)
                beginServerRecovery(profile: saved, batch: batch)
                return
            }
        } catch { if accountEpoch == epoch { errorMessage = L10n.error(error) }; return }
        guard accountEpoch == epoch, let database else { return }
        let part = AccountPartition(serverID: saved.id, userID: userID)
        let cachedUser = try? await database.load(UserAccount.self, key: "user", partition: part)
        guard accountEpoch == epoch else { return }
        let restoredClient = trackedClient(profile: saved)
        guard await configure(profile: saved, user: cachedUser ?? .init(id: userID, username: saved.username), client: restoredClient, epoch: epoch) else { return }
        do {
            _ = try await restoredClient.status()
            try requireCurrent(epoch)
            let account = try await restoredClient.currentUser()
            try requireCurrent(epoch)
            let actualProfile = await restoredClient.profile
            try requireCurrent(epoch)
            profile = actualProfile
            profiles.removeAll { $0.id == actualProfile.id }; profiles.insert(actualProfile, at: 0); saveProfiles()
            // A valid token for another user must never remain attached to this
            // profile's local data, even when a final reader checkpoint fails.
            guard account.id == userID else {
                await requireAccountReauthentication(client: restoredClient, profileID: saved.id, userID: user?.id ?? userID, epoch: epoch,
                    message: L10n.tr("服务器返回了不同的账户身份，请重新登录。本机下载和待同步记录已保留。"), identityMismatch: true)
                return
            }
            // refresh reconciles the cached account against /me before exposing
            // updated access or continuing with credentials invalidated remotely.
            await finishConnectionRefresh(epoch: epoch, client: restoredClient)
        } catch {
            guard accountEpoch == epoch else { return }
            if Self.isNetworkFailure(error) {
                isOffline = true
                await loadCache()
                guard accountEpoch == epoch else { return }
                notice = L10n.tr("当前离线，已下载的内容仍可播放。")
            } else {
                errorMessage = L10n.error(error)
                showConnection = true
            }
        }
    }

    private func finishConnectionRefresh(epoch: UUID, client: ABSClient) async {
        guard accountEpoch == epoch, self.client === client else { return }
        await refresh()
        // Refresh holds the connection gate, so its synchronization is deferred
        // until the authenticated source and fresh progress have been validated.
        guard accountEpoch == epoch, self.client === client,
              user?.isActive == true, serverProgressIsFresh, !isOffline,
              serverRecovery == nil, !recoveryBusy else { return }
        isConnecting = false
        await synchronize()
    }

    private func configure(profile: ServerProfile, user: UserAccount, client: ABSClient, epoch: UUID) async -> Bool {
        do { try await checkpointReadingBeforeTransition(); try await checkpointPlaybackBeforeTransition() }
        catch { if accountEpoch == epoch { errorMessage = L10n.error(error) }; return false }
        guard accountEpoch == epoch else { return false }
        retainPlaybackForRecovery(player, partition: partition)
        player = nil
        do {
            let endpoint = try ServerRestoreBatch.canonicalURL(profile.baseURL.absoluteString)
            guard try await database?.restoreGuard(profileID: profile.id, canonicalBaseURL: endpoint) == nil else { return false }
        } catch { if accountEpoch == epoch { errorMessage = L10n.error(error) }; return false }
        guard accountEpoch == epoch else { return false }
        loadID = UUID()
        self.profile = profile; self.user = user; self.client = client
        accountReauthenticationRequired = false; accountAccessRefreshPending = false
        serverRecovery = nil; recoveryError = nil
        playbackPreferences = partition.map { PersonalPlaybackPreferencesStore.shared.preferences(for: $0) } ?? .init()
        isDemo = false; isOffline = false; items = []; libraries = []; progressByItem = [:]
        remoteProgressByItem = [:]; serverProgressIsFresh = false
        selectedItem = nil; conflicts = []; readingConflicts = []; readingIsActive = false; readingActivityID = nil; errorMessage = nil; notice = nil
        browsingLibraryID = nil; route = .home; search = ""; page = 0
        guard let partition, let database else { return true }
        if downloads == nil, let downloadDirectory {
            downloads = DownloadManager(database: database, rootDirectory: downloadDirectory)
        }
        try? await database.save(user, key: "user", partition: partition)
        guard accountEpoch == epoch else { return false }
        do { try await downloads?.restore(partition: partition) }
        catch { if accountEpoch == epoch { errorMessage = L10n.error(error) } }
        guard accountEpoch == epoch else { return false }
        let callbackEpoch = UUID(); playbackCallbackEpoch = callbackEpoch
        player = PlaybackController(ownsSystemMediaControls: !publicSharing.isActive,
            service: ABSPlaybackService(client: client),
            checkpoint: { [weak self] progress in
                try await database.saveResume(progress, partition: partition)
                await MainActor.run {
                    guard self?.playbackCallbackEpoch == callbackEpoch, self?.partition == partition else { return }
                    if let previous = self?.progressByItem[progress.id] {
                        self?.progressByItem[progress.id] = progress.preservingLocalContinuationMetadata(from: previous)
                    } else { self?.progressByItem[progress.id] = progress }
                }
            },
            didSynchronize: { id in try await database.removePendingSession(id: id, partition: partition) },
            localProvider: { [weak self] media in
                guard let self else { throw CancellationError() }
                return try await self.prepareLocalPlayback(media, partition: partition, callbackEpoch: callbackEpoch)
            },
            persistenceFactory: { [weak self] media in
                let baseline = self?.playbackBaselines[partition]?[media.id]
                let device = DeviceInfo(deviceId: profile.id.uuidString)
                return { session, ownAcknowledgement in
                    var attributedSession = session
                    attributedSession.deviceInfo = device
                    try await database.enqueue(attributedSession, partition: partition, baseline: baseline, ownAcknowledgement: ownAcknowledgement)
                }
            }
        )
        applyPlaybackPreferences()
        if let configuredPlayer = player {
            configuredPlayer.onRemoteRateChange = { [weak self, weak configuredPlayer] rate in
                guard let self, let configuredPlayer, self.accountEpoch == epoch,
                      self.playbackCallbackEpoch == callbackEpoch, self.partition == partition,
                      self.player === configuredPlayer else { return }
                self.setPlaybackRate(Double((rate * 100).rounded()) / 100, for: configuredPlayer)
            }
        }
        await loadCache()
        if accountEpoch == epoch { observeServerRestores(profile: profile, client: client, epoch: epoch) }
        return accountEpoch == epoch
    }

    func refresh() async {
        guard forcedSignOutOperations.isEmpty, !isDemo, serverRecovery == nil, !recoveryBusy, let client, let partition, let database else { return }
        var epoch = accountEpoch
        let request = UUID(); accountRefreshID = request
        isLoading = true
        defer { if accountEpoch == epoch { isLoading = false } }
        do {
            let account = try await client.currentUser()
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            guard let updatedEpoch = try await applyCurrentAccount(account, client: client, epoch: epoch) else { return }
            epoch = updatedEpoch
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            async let libraryResult = client.libraries()
            async let progressResult = client.progress()
            let (freshLibraries, freshProgress) = try await (libraryResult, progressResult)
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            libraries = freshLibraries
            let pending = try await database.pendingSessions(partition: partition)
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            let pendingIDs = Set(pending.map { progressID(itemID: $0.itemID, episodeID: $0.episodeID) })
            let activeID = player?.currentMedia?.id
            let localProgress = progressByItem.filter { pendingIDs.contains($0.key) || $0.key == activeID }
            remoteProgressByItem = Dictionary(freshProgress.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            progressByItem = remoteProgressByItem.merging(localProgress) { _, local in local }
            serverProgressIsFresh = true
            try await database.save(freshLibraries, key: "libraries", partition: partition)
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            try await database.save(freshProgress, key: "progress", partition: partition)
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            isOffline = false
            libraryRevision = UUID()
            await loadLibrary(reset: true)
            try requireAccountRefresh(epoch: epoch, request: request, client: client)
            if player?.isPlaying != true { await synchronize() }
        } catch {
            guard forcedSignOutOperations.isEmpty, accountEpoch == epoch, accountRefreshID == request, self.client === client else { return }
            if error is CancellationError { return }
            if (error as? ABSError) == .notAuthenticated || (error as? ABSError).map({ if case .http(status: 401, message: _) = $0 { return true }; return false }) == true {
                await requireAccountReauthentication(client: client, profileID: partition.serverID, userID: partition.userID, epoch: epoch,
                                                     message: L10n.tr("登录已失效，请重新登录。本机下载和待同步记录已保留。"))
                return
            }
            if Self.isNetworkFailure(error) {
                isOffline = true
                await loadCache()
            } else { errorMessage = L10n.error(error) }
        }
    }

    private func requireAccountRefresh(epoch: UUID, request: UUID, client: ABSClient) throws {
        try Task.checkCancellation()
        guard forcedSignOutOperations.isEmpty, accountEpoch == epoch, accountRefreshID == request, self.client === client else { throw CancellationError() }
    }

    /// Only the authoritative /me response can replace the current account.
    /// Changing access invalidates every old page before crossing an await.
    private func applyCurrentAccount(_ account: UserAccount, client: ABSClient, epoch: UUID) async throws -> UUID? {
        guard forcedSignOutOperations.isEmpty, accountEpoch == epoch, self.client === client, let previous = user, let profile,
              let partition else { throw ABSError.sessionChanged }
        if account.id != previous.id || account.id != partition.userID {
            await requireAccountReauthentication(client: client, profileID: profile.id, userID: previous.id, epoch: epoch,
                message: L10n.tr("服务器返回了不同的账户身份，请重新登录。本机下载和待同步记录已保留。"), identityMismatch: true)
            return nil
        }
        if !account.isActive || account.username != previous.username {
            await requireAccountReauthentication(client: client, profileID: profile.id, userID: previous.id, epoch: epoch,
                                                 message: L10n.tr("账户身份或状态已变化，请重新登录。本机下载和待同步记录已保留。"), username: account.username)
            return nil
        }
        if AccountUpdatePolicy.hasSameAccess(account, previous), !accountAccessRefreshPending {
            user = account
            try await database?.save(account, key: "user", partition: partition)
            try requireCurrent(epoch)
            return epoch
        }
        let next = beginAccountChange()
        let cacheKey = accessCacheInvalidationKey(partition)
        UserDefaults.standard.set(true, forKey: cacheKey)
        user = account; accountAccessRefreshPending = true; isConnecting = true
        retainPlaybackForRecovery(player, partition: partition)
        player = nil; playbackCallbackEpoch = UUID()
        items = []; libraries = []; selectedItem = nil; totalItems = 0
        browsingLibraryID = nil; browseNavigation = nil; conflicts = []; readingConflicts = []
        libraryRevision = UUID()
        defer { if accountEpoch == next { isConnecting = false } }
        do {
        await retirePlaybackRecoveryHandles()
        var cacheError: (any Error)?
        do {
            try await database?.clearCache(partition: partition)
            try requireCurrent(next)
            UserDefaults.standard.removeObject(forKey: cacheKey)
        } catch { cacheError = error }
        try requireCurrent(next)
        var preparationError: (any Error)?
        do { try await savePlaybackRecoveryHandles() }
        catch { preparationError = error }
        try requireCurrent(next)
        if let downloads {
            for record in downloads.records where record.state == .downloading || record.state == .queued {
                do { try await downloads.pause(itemID: record.itemID) }
                catch { preparationError = preparationError ?? error }
                try requireCurrent(next)
            }
        }
        if let readingShutdown {
            do { try await readingShutdown(); try requireCurrent(next); self.readingShutdown = nil }
            catch { preparationError = preparationError ?? error }
        }
        try requireCurrent(next)
        if let preparationError { throw preparationError }
        guard await configure(profile: profile, user: account, client: client, epoch: next) else { throw CancellationError() }
        if let cacheError { errorMessage = L10n.error(cacheError) }
        accountAccessRefreshPending = false
        notice = L10n.tr("账户权限已更新，播放和下载已暂停。本机下载和待同步记录已保留。")
        return next
        } catch {
            if accountEpoch == next {
                errorMessage = L10n.error(error)
                observeServerRestores(profile: profile, client: client, epoch: next)
            }
            throw error
        }
    }

    func requireAccountReauthentication(client: ABSClient, profileID: UUID, userID: String, epoch: UUID, message: String, username: String? = nil, identityMismatch: Bool = false) async {
        guard accountEpoch == epoch, self.client === client, profile?.id == profileID, user?.id == userID,
              !recoveryBusy, serverRecovery == nil else { return }
        if identityMismatch {
            guard await quarantineAccountIdentity(client: client, epoch: epoch) else { return }
            notice = message
        }
        if let username, !username.isEmpty, var updated = profile {
            updated.username = username
            profile = updated
            if let index = profiles.firstIndex(where: { $0.id == profileID && $0.userID == userID }) {
                profiles[index].username = username
                saveProfiles()
            }
        }
        let result = await performSignOut(scope: .currentDevice, source: nil, presentConnection: false)
        if case .finished = result {
            notice = message + (errorMessage.map { " " + $0 } ?? "")
            errorMessage = nil; accountReauthenticationRequired = true
        }
    }

    /// Retire the misbound network identity before any awaited local checkpoint.
    /// A failed checkpoint keeps its retry closure, while metadata and network
    /// access stay quarantined and a restart cannot silently reuse the token.
    private func quarantineAccountIdentity(client: ABSClient, epoch: UUID) async -> Bool {
        guard accountEpoch == epoch, self.client === client, let partition else { return false }
        let quarantinedEpoch = beginAccountChange()
        UserDefaults.standard.set(true, forKey: "explicitSignedOut")
        let cacheKey = accessCacheInvalidationKey(partition)
        UserDefaults.standard.set(true, forKey: cacheKey)
        isConnecting = true; isOffline = true; accountAccessRefreshPending = true
        accountReauthenticationRequired = false
        items = []; libraries = []; selectedItem = nil; totalItems = 0
        progressByItem = [:]; remoteProgressByItem = [:]; serverProgressIsFresh = false
        conflicts = []; readingConflicts = []; browsingLibraryID = nil; libraryRevision = UUID()
        retainPlaybackForRecovery(player, partition: partition)
        player = nil; playbackCallbackEpoch = UUID()
        trackedClients[ObjectIdentifier(client)]?.isRetired = true
        await retirePlaybackRecoveryHandles()
        await client.retireForServerRestore()
        guard accountEpoch == quarantinedEpoch, self.client === client else { return false }
        do { try await savePlaybackRecoveryHandles() }
        catch { if accountEpoch == quarantinedEpoch { errorMessage = L10n.error(error) } }
        guard accountEpoch == quarantinedEpoch, self.client === client else { return false }
        if let downloads {
            for record in downloads.records where record.state == .downloading || record.state == .queued {
                do { try await downloads.pause(itemID: record.itemID) }
                catch { errorMessage = L10n.error(error) }
                guard accountEpoch == quarantinedEpoch, self.client === client else { return false }
            }
        }
        do {
            try await database?.clearCache(partition: partition)
            guard accountEpoch == quarantinedEpoch, self.client === client else { return false }
            UserDefaults.standard.removeObject(forKey: cacheKey)
        } catch {
            guard accountEpoch == quarantinedEpoch, self.client === client else { return false }
            errorMessage = L10n.error(error)
        }
        isConnecting = false
        return true
    }

    func presentAccountReauthentication() {
        guard accountReauthenticationRequired, client == nil, user == nil, serverRecovery == nil,
              !recoveryBusy, !isConnecting else { return }
        accountReauthenticationRequired = false; showConnection = true
    }

    func loadLibrary(reset: Bool = true) async {
        guard forcedSignOutOperations.isEmpty, !isDemo else { return }
        guard let library = currentLibrary, let partition, let database else { return }
        let generation = UUID(); loadID = generation
        if reset { page = 0 }
        if isOffline { await loadCache(); return }
        guard let client else { return }
        let requestedPage = page
        isLoading = true
        defer { if loadID == generation { isLoading = false } }
        do {
            let result = try await client.libraryItems(libraryID: library.id, page: requestedPage, limit: 60, search: search.isEmpty ? nil : search)
            guard forcedSignOutOperations.isEmpty, loadID == generation else { return }
            if reset { items = result.results } else {
                let existing = Set(items.map(\.id)); items += result.results.filter { !existing.contains($0.id) }
            }
            totalItems = result.total
            page = requestedPage + 1
            if search.isEmpty { try await database.save(items, key: "items.\(library.id)", partition: partition) }
        } catch is CancellationError { }
        catch {
            guard forcedSignOutOperations.isEmpty, loadID == generation else { return }
            if Self.isNetworkFailure(error) { isOffline = true; await loadCache() }
            else { errorMessage = L10n.error(error) }
        }
    }

    func loadCache() async {
        guard forcedSignOutOperations.isEmpty, let partition, let database else { return }
        let epoch = accountEpoch
        let invalidationKey = accessCacheInvalidationKey(partition)
        if UserDefaults.standard.bool(forKey: invalidationKey) {
            do {
                try await database.clearCache(partition: partition)
                try requireCurrent(epoch)
                UserDefaults.standard.removeObject(forKey: invalidationKey)
            } catch {
                if accountEpoch == epoch { errorMessage = L10n.error(error) }
                return
            }
        }
        if let cached = try? await database.load([Library].self, key: "libraries", partition: partition) {
            guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }; libraries = cached
        }
        if let cached = try? await database.load([MediaProgress].self, key: "progress", partition: partition) {
            guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }
            remoteProgressByItem = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for progress in cached { progressByItem[progress.id] = progress }
        }
        if let confirmed = try? await database.confirmedProgress(partition: partition) {
            guard forcedSignOutOperations.isEmpty, accountEpoch == epoch, self.partition == partition, self.database === database else { return }
            for progress in confirmed {
                if (progress.lastUpdate ?? 0) > (remoteProgressByItem[progress.id]?.lastUpdate ?? -1) {
                    remoteProgressByItem[progress.id] = progress
                }
            }
        }
        if let library = currentLibrary,
           let cached = try? await database.load([AudilseCore.LibraryItem].self, key: "items.\(library.id)", partition: partition) {
            guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }
            items = search.isEmpty ? cached : cached.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.authorName.localizedCaseInsensitiveContains(search) }
            totalItems = items.count
        }
        for item in items {
            if let saved = try? await database.loadResume(itemID: item.id, partition: partition) {
                guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }; progressByItem[item.id] = saved
            }
            if item.mediaType == "podcast" {
                let full = (try? await database.load(AudilseCore.LibraryItem.self, key: "item.\(item.id)", partition: partition)) ?? item
                guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }
                for episode in full.media.episodes {
                    if let saved = try? await database.loadResume(itemID: item.id, episodeID: episode.id, partition: partition) {
                        guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }; progressByItem[saved.id] = saved
                    }
                }
            }
        }
        let restoredConflicts = (try? await database.conflicts(partition: partition)) ?? []
        guard forcedSignOutOperations.isEmpty, accountEpoch == epoch else { return }
        conflicts = restoredConflicts
    }

    func open(_ item: AudilseCore.LibraryItem) async {
        guard forcedSignOutOperations.isEmpty else { return }
        let request = UUID(); detailRequestID = request
        let epoch = accountEpoch
        selectedItem = item
        detailLoadingItemID = nil
        guard !isDemo, let partition, let database else { return }
        detailLoadingItemID = item.id
        defer {
            if isCurrentDetail(request: request, epoch: epoch, itemID: item.id) { detailLoadingItemID = nil }
        }
        do {
            if !isOffline, let client {
                let full = try await client.item(id: item.id)
                guard isCurrentDetail(request: request, epoch: epoch, itemID: item.id), !Task.isCancelled else { return }
                selectedItem = full
                try await database.save(full, key: "item.\(item.id)", partition: partition)
            } else if let full = try await database.load(AudilseCore.LibraryItem.self, key: "item.\(item.id)", partition: partition) {
                guard isCurrentDetail(request: request, epoch: epoch, itemID: item.id), !Task.isCancelled else { return }
                selectedItem = full
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch ABSError.sessionChanged {
        } catch {
            guard isCurrentDetail(request: request, epoch: epoch, itemID: item.id), !Task.isCancelled else { return }
            errorMessage = L10n.error(error)
        }
    }

    func cancelDetailLoading() { detailRequestID = UUID(); detailLoadingItemID = nil }

    private func isCurrentDetail(request: UUID, epoch: UUID, itemID: String) -> Bool {
        forcedSignOutOperations.isEmpty && detailRequestID == request && accountEpoch == epoch && selectedItem?.id == itemID
    }

    func playGroup(entries: [PlaylistEntry]) async {
        guard !isDemo else { showConnection = true; return }
        let plan = OrderedPlaybackPlan(entries: entries, progressByItem: progressByItem)
        guard let first = plan.entries.first, let item = first.libraryItem else {
            errorMessage = L10n.tr("这个列表没有可播放的音频内容。")
            return
        }
        let following = plan.entries.dropFirst().compactMap { entry in
            entry.libraryItem.map { playbackMedia($0, episode: entry.episode) }
        }
        await play(item, episode: first.episode, following: following)
    }

    func play(_ item: AudilseCore.LibraryItem, episode: PodcastEpisode? = nil, following: [PlaybackMedia]? = nil) async {
        guard !Task.isCancelled, !isConnecting, !hasCurrentPlaybackSessionMutation else { return }
        guard !isDemo else { showConnection = true; return }
        guard let player, let partition, let database else { return }
        let epoch = accountEpoch
        let request = UUID(); playRequestID = request
        publicSharing.cancelOpening()
        var full = item
        if !isOffline, let client {
            do {
                full = try await client.item(id: item.id)
                try requireCurrent(epoch, playRequest: request)
                try await database.save(full, key: "item.\(item.id)", partition: partition)
                try requireCurrent(epoch, playRequest: request)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), accountEpoch == epoch, playRequestID == request else { return }
                if Self.isNetworkFailure(error) { isOffline = true } else { errorMessage = L10n.error(error); return }
            }
        } else if let cached = try? await database.load(AudilseCore.LibraryItem.self, key: "item.\(item.id)", partition: partition) {
            guard !Task.isCancelled, accountEpoch == epoch, playRequestID == request else { return }; full = cached
        }
        guard !Task.isCancelled, accountEpoch == epoch, playRequestID == request else { return }
        var media = playbackMedia(full, episode: episode)
        do {
            let baseline = try await playbackBaseline(media, partition: partition, database: database)
            try requireCurrent(epoch, playRequest: request)
            playbackBaselines[partition, default: [:]][media.id] = baseline
            if !isOffline, let client {
                media.coverURL = try await client.authorizedURL(path: "api/items/\(ServerEndpoint.component(full.id))/cover?width=440&format=jpeg")
                try requireCurrent(epoch, playRequest: request)
            } else { media.coverURL = nil }
            let downloadID = episode.map { PodcastDownloadIdentity.key(itemID: full.id, episodeID: $0.id) } ?? full.id
            let local = try? await downloads?.readyTracks(partition: partition, itemID: downloadID)
            try requireCurrent(epoch, playRequest: request)
            if let local, !local.isEmpty {
                let tracks = local.enumerated().map { index, track in
                    PlaybackTrack(index: index, title: track.title, url: track.url, duration: track.duration, startOffset: track.startOffset, isLocal: true)
                }
                let resume = try await database.loadResume(itemID: media.itemID, episodeID: media.episodeID, partition: partition)
                try requireCurrent(epoch, playRequest: request)
                let pending = try await database.pendingSessions(partition: partition)
                try requireCurrent(epoch, playRequest: request)
                let hasPending = pending.contains { $0.itemID == media.itemID && $0.episodeID == media.episodeID }
                // Use the same confirmed snapshot as this session baseline, including
                // offline. Pending history and newer local checkpoints still win.
                let selected: MediaProgress?
                if !hasPending,
                   let remote = baseline,
                   (remote.lastUpdate ?? 0) >= (resume?.lastUpdate ?? 0) { selected = remote }
                else { selected = resume ?? progressByItem[media.id] }
                let start = selected?.isFinished == true ? 0 : selected?.currentTime ?? 0
                guard await acquireAccountPlayback(player, epoch: epoch, request: request) else { return }
                await player.playOffline(media: media, tracks: tracks, initialPosition: start, following: following)
            } else if isOffline { throw ConnectionFailure.notDownloaded }
            else {
                guard await acquireAccountPlayback(player, epoch: epoch, request: request) else { return }
                await player.play(media: media, following: following)
            }
            try requireCurrent(epoch, playRequest: request)
            if let failure = player.errorDiagnostic { presentError(failure) }
        } catch {
            guard !Task.isCancelled, accountEpoch == epoch, playRequestID == request, !(error is CancellationError) else { return }
            errorMessage = L10n.error(error)
        }
    }

    func playHistoricalSession(_ request: ServerHistoricalPlaybackRequest) async throws {
        try Task.checkCancellation()
        guard request.source.isCurrent(store: self), !isConnecting, !hasCurrentPlaybackSessionMutation,
              let player, let database else { throw CancellationError() }
        guard request.position.isFinite, request.position >= 0 else { throw PlaybackFailure.invalidStartPosition }
        let operation = UUID(); playRequestID = operation
        publicSharing.cancelOpening()
        func validateSource() throws {
            try requireCurrent(request.source.accountEpoch, playRequest: operation)
            guard request.source.isCurrent(store: self), self.player === player,
                  self.database === database, !hasCurrentPlaybackSessionMutation else { throw CancellationError() }
        }
        let full = try await request.source.client.item(id: request.item.id)
        try validateSource()
        guard full.id == request.item.id, !full.libraryId.isEmpty, !full.isMissing, !full.isInvalid,
              request.source.canAccess(full) else { throw ABSError.invalidResponse }
        let episode: PodcastEpisode?
        if let episodeID = request.episodeID {
            guard full.mediaType == "podcast", let fresh = full.media.episodes.first(where: { $0.id == episodeID }) else {
                throw ABSError.invalidResponse
            }
            episode = fresh
        } else {
            guard full.mediaType == "book" else { throw ABSError.invalidResponse }
            episode = nil
        }
        try await database.save(full, key: "item.\(full.id)", partition: request.source.partition)
        try validateSource()
        var media = playbackMedia(full, episode: episode)
        let baseline = try await playbackBaseline(media, partition: request.source.partition, database: database)
        try validateSource()
        playbackBaselines[request.source.partition, default: [:]][media.id] = baseline
        media.coverURL = try await request.source.client.authorizedURL(path: "api/items/\(ServerEndpoint.component(full.id))/cover?width=440&format=jpeg")
        try validateSource()
        let downloadID = request.episodeID.map { PodcastDownloadIdentity.key(itemID: full.id, episodeID: $0) } ?? full.id
        let local = try? await downloads?.readyTracks(partition: request.source.partition, itemID: downloadID)
        try validateSource()
        guard await acquireAccountPlayback(player, epoch: request.source.accountEpoch, request: operation) else { throw CancellationError() }
        try validateSource()
        if let local, !local.isEmpty {
            let tracks = local.enumerated().map { index, track in
                PlaybackTrack(index: index, title: track.title, url: track.url, duration: track.duration, startOffset: track.startOffset, isLocal: true)
            }
            await player.playOffline(media: media, tracks: tracks, initialPosition: request.position, following: [])
        } else {
            await player.play(media: media, following: [], initialPosition: request.position)
        }
        try validateSource()
        if let failure = player.errorDiagnostic { throw failure }
    }

    func preparePlaybackSessionMutation(ids: Set<String>, source: ServerPlaybackSessionsSource, deleting: Bool) async throws {
        try Task.checkCancellation()
        guard source.isCurrent(store: self), let sync, let database else { throw CancellationError() }
        guard !ids.isEmpty, ids.allSatisfy(AdminPlaybackSessionPolicy.isValidIdentifier) else {
            throw AdminPlaybackSessionInputError.invalidSessionIDs
        }
        guard !hasCurrentPlaybackSessionMutation else { throw OfflineSyncError.alreadyRunning }
        let lease = PlaybackSessionMutationLease(ids: ids, source: source, sync: sync, database: database, player: player, deleting: deleting)
        playbackSessionMutations[lease.id] = lease
        do {
            try await sync.reserveSessionMutation(id: lease.id, partition: source.partition)
            try requirePlaybackSessionMutation(lease)
            // Ambiguous earlier deltas must finish recovery before a delete can
            // safely proceed; otherwise its local journal could recreate history.
            let pending = try await database.pendingSessions(partition: source.partition)
            try requirePlaybackSessionMutation(lease)
            guard !pending.contains(where: { ids.contains($0.id) }) else {
                throw ClientDiagnostic(code: "playback.managementPendingHistory", fallbackMessage: "所选记录仍有本机待同步内容。请先停止播放并同步，再重新操作。")
            }
            if let player, let sessionID = player.currentRemoteSessionID, ids.contains(sessionID) {
                playRequestID = UUID()
                guard try await player.prepareServerSessionMutation(sessionID: sessionID) else { throw CancellationError() }
                try requirePlaybackSessionMutation(lease)
            }
            let remaining = try await database.pendingSessions(partition: source.partition)
            try requirePlaybackSessionMutation(lease)
            guard !remaining.contains(where: { ids.contains($0.id) }) else {
                throw ClientDiagnostic(code: "playback.managementPendingHistory", fallbackMessage: "所选记录仍有本机待同步内容。请先停止播放并同步，再重新操作。")
            }
        } catch {
            await finishPlaybackSessionMutation(ids: ids, source: source)
            throw error
        }
    }

    func completePlaybackSessionMutation(ids: Set<String>, source: ServerPlaybackSessionsSource, deleted: Bool) async throws {
        // Completion belongs to the frozen original partition even if its UI
        // disappeared after ABS confirmed the write. Never use a new account.
        guard let lease = playbackSessionMutations.values.first(where: { $0.ids == ids && $0.source == source }),
              lease.deleting == deleted else { throw CancellationError() }
        if deleted {
            let pending = try await lease.database.pendingSessions(partition: source.partition)
            guard !pending.contains(where: { ids.contains($0.id) }) else {
                throw ClientDiagnostic(code: "playback.managementPendingHistory", fallbackMessage: "所选记录仍有本机待同步内容。请先停止播放并同步，再重新操作。")
            }
        }
    }

    func finishPlaybackSessionMutation(ids: Set<String>, source: ServerPlaybackSessionsSource) async {
        guard let lease = playbackSessionMutations.values.first(where: { $0.ids == ids && $0.source == source }) else { return }
        await lease.sync.finishSessionMutation(id: lease.id)
        playbackSessionMutations[lease.id] = nil
    }

    private func requirePlaybackSessionMutation(_ lease: PlaybackSessionMutationLease) throws {
        try Task.checkCancellation()
        guard playbackSessionMutations[lease.id] != nil, lease.source.isCurrent(store: self),
              sync === lease.sync, database === lease.database, player === lease.player else { throw CancellationError() }
        guard lease.player?.finalizingSessionIDs.isDisjoint(with: lease.ids) != false else { throw OfflineSyncError.alreadyRunning }
    }

    private func prepareLocalPlayback(_ media: PlaybackMedia, partition: AccountPartition, callbackEpoch: UUID) async throws -> PreparedPlayback? {
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        guard let downloads, let database else { return nil }
        let baseline = try await playbackBaseline(media, partition: partition, database: database)
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        playbackBaselines[partition, default: [:]][media.id] = baseline
        let key = media.episodeID.map { PodcastDownloadIdentity.key(itemID: media.itemID, episodeID: $0) } ?? media.itemID
        let local: [DownloadedTrack]
        do { local = try await downloads.readyTracks(partition: partition, itemID: key) }
        catch {
            try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
            if isOffline { throw error }
            return nil
        }
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        guard !local.isEmpty else {
            if isOffline { throw ConnectionFailure.notDownloaded }
            return nil
        }
        var expanded = media
        if let full = try await database.load(AudilseCore.LibraryItem.self, key: "item.\(media.itemID)", partition: partition) {
            try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
            if let episodeID = media.episodeID, let episode = full.media.episodes.first(where: { $0.id == episodeID }) {
                expanded = playbackMedia(full, episode: episode)
            } else if media.episodeID == nil { expanded = playbackMedia(full) }
        }
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        let resume = try await database.loadResume(itemID: media.itemID, episodeID: media.episodeID, partition: partition)
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        let pending = try await database.pendingSessions(partition: partition)
        try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        let hasPending = pending.contains { $0.itemID == media.itemID && $0.episodeID == media.episodeID }
        let selected: MediaProgress?
        if !hasPending,
           let remote = baseline, (remote.lastUpdate ?? 0) >= (resume?.lastUpdate ?? 0) { selected = remote }
        else { selected = resume ?? progressByItem[media.id] }
        let position = selected?.isFinished == true ? 0 : selected?.currentTime ?? 0
        expanded.coverURL = nil
        if !isOffline, let client {
            expanded.coverURL = try? await client.authorizedURL(path: "api/items/\(ServerEndpoint.component(media.itemID))/cover?width=440&format=jpeg")
            try requirePlaybackAccount(partition, callbackEpoch: callbackEpoch)
        }
        let tracks = local.enumerated().map { index, track in
            PlaybackTrack(index: index, title: track.title, url: track.url, duration: track.duration, startOffset: track.startOffset, isLocal: true)
        }
        return PreparedPlayback(media: expanded, tracks: tracks, sessionID: nil, initialPosition: position)
    }

    private func requirePlaybackAccount(_ partition: AccountPartition, callbackEpoch: UUID) throws {
        guard self.partition == partition, playbackCallbackEpoch == callbackEpoch else { throw CancellationError() }
    }

    func download(_ item: AudilseCore.LibraryItem) async {
        guard !isDemo else { showConnection = true; return }
        guard canDownload else { errorMessage = L10n.tr("此账户没有下载权限。"); return }
        guard let client, let partition, let database, let downloads else { return }
        let epoch = accountEpoch
        do {
            let full = try await client.item(id: item.id)
            try requireCurrent(epoch)
            try await database.save(full, key: "item.\(full.id)", partition: partition)
            try requireCurrent(epoch)
            // A completed online book may never have appeared in the last /me
            // cache. Capture a server baseline while preparing its offline copy.
            // A failed optional read must not prevent downloading the original.
            if let confirmed = try? await client.progress(itemID: full.id) {
                try requireCurrent(epoch)
                try? await rememberConfirmedProgress(confirmed, client: client, partition: partition, database: database, epoch: epoch)
            }
            try requireCurrent(epoch)
            let files = full.media.audioFiles.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            guard !files.isEmpty else { throw ConnectionFailure.noAudio }
            var offset = 0.0
            var tracks: [DownloadTrack] = []
            for (index, file) in files.enumerated() {
                let matching = full.media.tracks.first { $0.index == (file.index ?? index) }
                let duration = file.duration ?? matching?.duration ?? 0
                let start = matching?.startOffset ?? offset
                let url = try await client.resourceURL(path: "api/items/\(full.id)/file/\(file.ino)")
                try requireCurrent(epoch)
                tracks.append(.init(ino: file.ino, title: matching?.title ?? file.metadata.filename, filename: file.metadata.filename, contentURL: url, duration: duration, startOffset: start, expectedBytes: file.metadata.size))
                offset = start + duration
            }
            try await downloads.start(partition: partition, itemID: full.id, title: full.title, tracks: tracks) { url in
                try await client.authorizedRequest(path: url.absoluteString)
            }
            try requireCurrent(epoch)
            notice = L10n.format("已加入下载：%1$@", String(describing: full.title))
        } catch { if accountEpoch == epoch, !(error is CancellationError) { errorMessage = L10n.error(error) } }
    }

    func downloadEpisode(_ item: AudilseCore.LibraryItem, episode: PodcastEpisode) async {
        guard !isDemo else { showConnection = true; return }
        guard canDownload else { errorMessage = L10n.tr("此账户没有下载权限。"); return }
        guard let client, let partition, let database, let downloads else { return }
        let epoch = accountEpoch
        do {
            let full = try await client.item(id: item.id)
            try requireCurrent(epoch)
            guard let current = full.media.episodes.first(where: { $0.id == episode.id }),
                  let file = current.audioFile,
                  let duration = current.duration ?? file.duration, duration.isFinite, duration > 0 else { throw ConnectionFailure.noAudio }
            try await database.save(full, key: "item.\(full.id)", partition: partition)
            try requireCurrent(epoch)
            if let progress = try? await client.progress(itemID: full.id, episodeID: current.id) {
                try requireCurrent(epoch)
                try? await rememberConfirmedProgress(progress, client: client, partition: partition, database: database, epoch: epoch)
                try requireCurrent(epoch)
                if player?.currentMedia?.id != progress.id,
                   let adopted = try await database.saveDownloadedResume(progress, partition: partition) {
                    try requireCurrent(epoch)
                    if player?.currentMedia?.id != progress.id,
                       (remoteProgressByItem[progress.id]?.lastUpdate ?? -1) <= (adopted.lastUpdate ?? -1),
                       (progressByItem[progress.id]?.lastUpdate ?? -1) <= (adopted.lastUpdate ?? -1) {
                        progressByItem[progress.id] = adopted
                    }
                }
            }
            try requireCurrent(epoch)
            let url = try await client.resourceURL(path: "api/items/\(ServerEndpoint.component(full.id))/file/\(ServerEndpoint.component(file.ino))")
            try requireCurrent(epoch)
            let track = DownloadTrack(ino: file.ino, title: current.title, filename: file.metadata.filename, contentURL: url,
                                      duration: duration, startOffset: 0, expectedBytes: file.metadata.size)
            let id = PodcastDownloadIdentity.key(itemID: full.id, episodeID: current.id)
            try await downloads.start(partition: partition, itemID: id, title: "\(full.title) · \(current.title)", tracks: [track]) { url in
                try await client.authorizedRequest(path: url.absoluteString)
            }
            try requireCurrent(epoch)
            notice = L10n.format("已加入下载：%1$@", String(describing: current.title))
        } catch { if accountEpoch == epoch, !(error is CancellationError) { errorMessage = L10n.error(error) } }
    }

    func synchronize() async {
        guard !isDemo, !isOffline, !isConnecting, user?.isActive == true, serverRecovery == nil, !recoveryBusy, let partition, let client, let sync else { return }
        let epoch = accountEpoch
        do {
            if player?.currentSessionID == nil, !hasCurrentPlaybackSessionMutation {
                let report = try await sync.synchronize(partition: partition, remote: ABSOfflineSyncRemote(client: client))
                try requireCurrent(epoch)
                conflicts = report.conflicts
                if report.uploaded > 0 { notice = L10n.format("已同步 %1$@ 条收听记录", String(describing: report.uploaded)) }
            }
            if !readingIsActive, let readingRepository {
                let conflicts = try await readingRepository.synchronize(partition: partition, client: client) { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireReadingSynchronizationSource(epoch: epoch, client: client, partition: partition, repository: readingRepository)
                }
                try requireReadingSynchronizationSource(epoch: epoch, client: client, partition: partition, repository: readingRepository)
                readingConflicts = conflicts
            }
        } catch { if accountEpoch == epoch, !(error is CancellationError) { errorMessage = L10n.error(error) } }
    }

    func resolveReading(_ conflict: ReadingConflict, useLocal: Bool) async {
        guard !readingIsActive, !isDemo, !isOffline, !isConnecting, user?.isActive == true,
              serverRecovery == nil, !recoveryBusy, let partition, let client, let readingRepository else { return }
        let epoch = accountEpoch
        do {
            try await readingRepository.resolve(conflict, useLocal: useLocal, partition: partition, client: client) { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.requireReadingSynchronizationSource(epoch: epoch, client: client, partition: partition, repository: readingRepository)
            }
            try requireReadingSynchronizationSource(epoch: epoch, client: client, partition: partition, repository: readingRepository)
            readingConflicts.removeAll { $0.id == conflict.id }
        } catch { if accountEpoch == epoch, !(error is CancellationError) { errorMessage = L10n.error(error) } }
    }

    private func requireReadingSynchronizationSource(epoch: UUID, client: ABSClient, partition: AccountPartition, repository: ReadingRepository) throws {
        try Task.checkCancellation()
        try requireCurrent(epoch)
        guard self.client === client, self.partition == partition, readingRepository === repository,
              user?.isActive == true, !isDemo, !isOffline, !isConnecting, !readingIsActive,
              serverRecovery == nil, !recoveryBusy else { throw CancellationError() }
    }

    func stopPlaybackAndSync() async {
        publicSharing.cancelOpening()
        if publicSharing.isActive {
            if await publicSharing.stop() { player?.setSystemMediaControlsActive(true) }
            else if let diagnostic = publicSharing.diagnostic { presentError(diagnostic) }
            return
        }
        guard !hasCurrentPlaybackSessionMutation else { return }
        let epoch = accountEpoch
        playRequestID = UUID()
        if let player { await player.stop() }
        guard accountEpoch == epoch else { return }
        await synchronize()
    }

    func resolve(_ conflict: SyncConflict, choice: SyncPositionChoice) async {
        guard !hasCurrentPlaybackSessionMutation, let partition, let client, let sync, let database else { return }
        let epoch = accountEpoch
        do {
            if player?.currentMedia?.itemID == conflict.local.itemID,
               player?.currentMedia?.episodeID == conflict.local.episodeID {
                playRequestID = UUID(); await player?.stop(); try requireCurrent(epoch)
            }
            try await sync.resolve(conflict, choice: choice, partition: partition, remote: ABSOfflineSyncRemote(client: client))
            try requireCurrent(epoch)
            let progress = try await client.progress()
            try requireCurrent(epoch)
            let id = progressID(itemID: conflict.local.itemID, episodeID: conflict.local.episodeID)
            if let confirmed = progress.first(where: { $0.id == id }) {
                try await database.saveResume(confirmed, partition: partition)
                try requireCurrent(epoch)
            }
            let pending = try await database.pendingSessions(partition: partition)
            try requireCurrent(epoch)
            let pendingIDs = Set(pending.map { progressID(itemID: $0.itemID, episodeID: $0.episodeID) })
            let retained = progressByItem.filter { pendingIDs.contains($0.key) }
            remoteProgressByItem = Dictionary(progress.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            progressByItem = remoteProgressByItem.merging(retained) { _, local in local }
            serverProgressIsFresh = true
            conflicts.removeAll { $0.id == conflict.id }
        } catch {
            guard accountEpoch == epoch, !(error is CancellationError) else { return }
            let restored = try? await database.conflicts(partition: partition)
            guard accountEpoch == epoch else { return }
            if let restored { conflicts = restored }
            errorMessage = L10n.error(error)
        }
    }

    /// Visibility responses must not replace concurrently advancing audio or reading positions.
    func applyContinuationChange(_ change: ContinueListeningChange) {
        guard change.isCurrent(self), let partition else { return }
        let metadata: ContinuationMetadataChange
        switch change.target {
        case .progress(let id):
            guard let progress = change.user.mediaProgress.first(where: { $0.serverID == id }) else { return }
            metadata = .progress(progress)
            progressByItem[progress.id] = (progressByItem[progress.id] ?? progress).withContinuationMetadata(from: progress)
            remoteProgressByItem[progress.id] = (remoteProgressByItem[progress.id] ?? progress).withContinuationMetadata(from: progress)
        case .series(let id): metadata = .series(id: id, hidden: change.user.seriesHideFromContinueListening.contains(id))
        }
        if let user { self.user = metadata.applying(to: user) }
        let epoch = accountEpoch
        Task {
            do { try await database?.applyContinuationMetadata(metadata, partition: partition) }
            catch { if accountEpoch == epoch { errorMessage = L10n.error(error) } }
        }
    }

    /// Server-confirmed audio/episode progress must update every local resume source together.
    func applyConfirmedProgress(_ progress: MediaProgress, expectedPartition: AccountPartition, expectedClient: ABSClient) async throws {
        let epoch = accountEpoch
        guard partition == expectedPartition, client === expectedClient, let database, !isOffline else { throw CancellationError() }
        try Task.checkCancellation()
        try await database.saveResume(progress, partition: expectedPartition)
        try requireCurrent(epoch)
        guard partition == expectedPartition, client === expectedClient, !isOffline else { throw CancellationError() }
        try Task.checkCancellation()
        progressByItem[progress.id] = progress
        remoteProgressByItem[progress.id] = progress
    }

    func setFinished(_ item: AudilseCore.LibraryItem, finished: Bool) async {
        guard !isDemo, let client, let partition, let database else { return }
        let epoch = accountEpoch
        do {
            try await client.setProgressFinished(itemID: item.id, isFinished: finished)
            try requireCurrent(epoch)
            let confirmed = try await client.progress(itemID: item.id)
            try requireCurrent(epoch)
            if let confirmed {
                try await database.saveResume(confirmed, partition: partition)
                try requireCurrent(epoch)
                progressByItem[item.id] = confirmed; remoteProgressByItem[item.id] = confirmed
            }
        } catch { if accountEpoch == epoch, !(error is CancellationError) { errorMessage = L10n.error(error) } }
    }

    func coverURL(_ item: AudilseCore.LibraryItem) -> URL? {
        guard !isDemo, let base = profile?.baseURL else { return nil }
        let path = base.absoluteString.hasSuffix("/") ? base : base.appendingPathComponent("")
        guard let result = URL(string: "api/items/\(item.id)/cover", relativeTo: path)?.absoluteURL else { return nil }
        var components = URLComponents(url: result, resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "width", value: "440"), URLQueryItem(name: "format", value: "jpeg")]
        if let stamp = item.updatedAt, stamp.isFinite { query.append(.init(name: "ts", value: String(stamp))) }
        components?.queryItems = query
        return components?.url
    }

    func playbackMedia(_ item: AudilseCore.LibraryItem, episode: PodcastEpisode? = nil) -> PlaybackMedia {
        .init(itemID: item.id, episodeID: episode?.id, title: episode?.title ?? item.title, author: item.authorName,
              duration: episode?.duration ?? item.media.duration,
              chapters: item.media.chapters.map { .init(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }, coverURL: coverURL(item))
    }

    func enterDemo() async {
        guard !recoveryBusy, !isConnecting else { return }
        let checkpointEpoch = accountEpoch
        isConnecting = true
        do { try await checkpointReadingBeforeTransition(); try await checkpointPlaybackBeforeTransition() }
        catch { if accountEpoch == checkpointEpoch { isConnecting = false; errorMessage = L10n.error(error) }; return }
        let epoch = beginAccountChange()
        isConnecting = false
        let previousDownloads = downloads
        retainPlaybackForRecovery(player, partition: partition)
        player = nil; downloads = nil
        guard accountEpoch == epoch else { return }
        if let previousDownloads {
            let active = previousDownloads.records.filter { $0.state == .downloading || $0.state == .queued }
            for record in active {
                try? await previousDownloads.pause(itemID: record.itemID)
                guard accountEpoch == epoch else { return }
            }
        }
        isDemo = true; isOffline = false; profile = nil; user = nil; client = nil
        accountReauthenticationRequired = false; accountAccessRefreshPending = false
        serverRecovery = nil; recoveryError = nil
        playbackPreferences = .init()
        selectedItem = nil; conflicts = []; readingConflicts = []; readingIsActive = false; readingActivityID = nil; errorMessage = nil; notice = nil
        remoteProgressByItem = [:]; serverProgressIsFresh = false; isLoading = false
        libraries = [.init(id: "demo", name: L10n.tr("我的有声书"))]
        browsingLibraryID = nil; route = .home; search = ""; items = DemoLibrary.items; totalItems = items.count
        progressByItem = Dictionary(items.prefix(3).enumerated().map { index, item in
            (item.id, .init(libraryItemId: item.id, currentTime: Double((index + 1) * 1700), duration: item.media.duration, progress: Double(index + 1) * 0.13, lastUpdate: Double(3 - index)))
        }, uniquingKeysWith: { _, last in last })
        showConnection = false
    }

    /// Persist active work before removing this account's credentials and visible data.
    func signOut() async {
        _ = await performSignOut(scope: .currentDevice, source: nil)
    }

    func signOutAllDevices(_ source: AllDevicesSignOutSource) async -> AllDevicesSignOutCompletion {
        guard source.isCurrent(self), !Task.isCancelled else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        do {
            let eligibility = try await source.client.allDevicesLogoutEligibility()
            guard source.isCurrent(self), !Task.isCancelled else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
            guard eligibility == .available else { return .notCompleted(AllDevicesSignOutSource.message(for: eligibility)) }
        } catch { return .notCompleted(L10n.error(error)) }
        return await performSignOut(scope: .allDevices, source: source)
    }

    private func performSignOut(scope: LogoutScope, source: AllDevicesSignOutSource?, presentConnection: Bool = true) async -> AllDevicesSignOutCompletion {
        guard !recoveryBusy else { return .notCompleted(L10n.tr("服务器恢复正在进行，请稍后再试。")) }
        if scope == .allDevices {
            guard let source, source.isCurrent(self), !Task.isCancelled else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        }
        var previousEpoch = accountEpoch
        isConnecting = true
        let forcedIsolation = scope == .currentDevice && !presentConnection
        let forcedOperation = forcedIsolation ? UUID() : nil
        if let forcedOperation { forcedSignOutOperations.insert(forcedOperation) }
        defer { if let forcedOperation { forcedSignOutOperations.remove(forcedOperation) } }
        if forcedIsolation {
            previousEpoch = beginAccountChange()
            // Invalidated accounts cannot keep playing while a reader checkpoint
            // is suspended or failing. Preserve audio independently of logout.
            UserDefaults.standard.set(true, forKey: "explicitSignedOut")
            accountAccessRefreshPending = true
            retainPlaybackForRecovery(player, partition: partition)
            player = nil; playbackCallbackEpoch = UUID()
            items = []; libraries = []; selectedItem = nil; totalItems = 0
            conflicts = []; readingConflicts = []; libraryRevision = UUID()
            await retirePlaybackRecoveryHandles()
        }
        guard accountEpoch == previousEpoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        var retainedWorkError: String?
        do {
            try await checkpointReadingBeforeTransition()
            try await checkpointPlaybackBeforeTransition()
        } catch {
            if presentConnection {
                if accountEpoch == previousEpoch { isConnecting = false; errorMessage = L10n.error(error) }
                return .notCompleted(L10n.error(error))
            }
            retainedWorkError = L10n.error(error)
        }
        guard accountEpoch == previousEpoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        let epoch = beginAccountChange()
        accountReauthenticationRequired = false; accountAccessRefreshPending = false
        if scope == .currentDevice { UserDefaults.standard.set(true, forKey: "explicitSignedOut") }
        isConnecting = true
        defer { if accountEpoch == epoch { isConnecting = false } }
        let previousClient = client
        let previousDownloads = downloads
        retainPlaybackForRecovery(player, partition: partition)
        player = nil
        await retirePlaybackRecoveryHandles()
        guard accountEpoch == epoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        if let previousDownloads {
            for record in previousDownloads.records where record.state == .downloading || record.state == .queued {
                try? await previousDownloads.pause(itemID: record.itemID)
                guard accountEpoch == epoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
            }
        }
        var logoutError: String? = retainedWorkError
        do {
            if scope == .currentDevice && !presentConnection { _ = try await previousClient?.logoutForReauthentication() }
            else { _ = try await previousClient?.logout(scope: scope) }
        }
        catch let error as LogoutError where scope == .currentDevice && !presentConnection {
            logoutError = (error.localCredentialsRemoved
                ? L10n.tr("本机凭据已清除，服务器退出尚未确认。")
                : L10n.tr("本机凭据清理未确认，自动登录已停用。")) + " " + L10n.error(error.underlyingError)
        }
        catch let error as LogoutError where scope == .allDevices && !error.localCredentialsRemoved {
            guard accountEpoch == epoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
            // No credential removal was confirmed. Recreate the paused playback
            // pipeline while retaining this account and its persisted work.
            if let source, let previousClient {
                _ = await configure(profile: source.profile, user: source.user, client: previousClient, epoch: epoch)
            }
            return .notCompleted(L10n.tr("未完成退出，本机账户已保留。") + " " + L10n.error(error.underlyingError))
        }
        catch let error as LogoutError where scope == .allDevices {
            logoutError = L10n.tr("此 Mac 已退出，其他设备的退出尚未确认。") + " " + L10n.error(error.underlyingError)
        }
        catch { logoutError = L10n.error(error) }
        if forcedIsolation {
            await previousClient?.retireForServerRestore()
            if let previousClient { trackedClients[ObjectIdentifier(previousClient)]?.isRetired = true }
        }
        guard accountEpoch == epoch else { return .notCompleted(L10n.tr("账户已变化，请关闭后重新打开。")) }
        UserDefaults.standard.set(true, forKey: "explicitSignedOut")
        playbackCallbackEpoch = UUID()
        user = nil; client = nil; profile = nil; downloads = nil
        playbackPreferences = .init()
        items = []; libraries = []; progressByItem = [:]; remoteProgressByItem = [:]
        serverProgressIsFresh = false; totalItems = 0; page = 0
        selectedItem = nil; conflicts = []; readingConflicts = []
        readingIsActive = false; readingActivityID = nil
        isDemo = false; isOffline = false; search = ""; browsingLibraryID = nil; route = .home
        if scope == .allDevices {
            notice = logoutError ?? L10n.tr("已请求服务器退出此账户的全部刷新会话。本机下载和待同步记录已保留。")
            errorMessage = nil
            // The confirmation sheet dismisses before the connection sheet opens.
        } else {
            notice = L10n.tr("已退出账户，本地下载和待同步记录已保留。")
            errorMessage = logoutError; showConnection = presentConnection
        }
        return .finished
    }

    private func trackedClient(profile: ServerProfile, tokenStore: any TokenStore = LocalFileTokenStore.shared) -> ABSClient {
        trackedClients = trackedClients.filter { $0.value.client != nil }
        let client = ABSClient(profile: profile, tokenStore: tokenStore)
        if let endpoint = try? ServerRestoreBatch.canonicalURL(profile.baseURL.absoluteString) {
            trackedClients[ObjectIdentifier(client)] = .init(endpoint: endpoint, client: client)
        }
        return client
    }

    private func removeCancelledCredentials(account: String, tokens: AuthTokens, url: URL, sourceClient: ABSClient) async throws {
        let endpoint = try ServerRestoreBatch.canonicalURL(url.absoluteString)
        // Restoration owns this account's retained credentials from this point on.
        // This check and the write registration are one MainActor turn. The
        // permanent source marker still applies after the endpoint gate is lifted.
        guard let source = trackedClients[ObjectIdentifier(sourceClient)], source.client === sourceClient,
              source.endpoint == endpoint, !source.isRetired, !restoringEndpoints.contains(endpoint) else { return }
        let id = UUID()
        let task = Task { try await LocalFileTokenStore.shared.remove(account: account, matching: tokens) }
        credentialWrites[id] = task
        defer { credentialWrites[id] = nil }
        try await task.value
    }

    private func persistOIDCCredentials(_ tokens: AuthTokens, profile: ServerProfile) async throws {
        let endpoint = try ServerRestoreBatch.canonicalURL(profile.baseURL.absoluteString)
        if restoringEndpoints.contains(endpoint) {
            guard let recovery = serverRecovery, recovery.canonicalBaseURL == endpoint,
                  recovery.id == recoveryRestartConfirmed else { throw ABSError.sessionChanged }
        }
        let id = UUID()
        let task = Task { try await LocalFileTokenStore.shared.save(tokens, account: profile.id.uuidString) }
        credentialWrites[id] = task
        defer { credentialWrites[id] = nil }
        try await task.value
    }

    private func clearServerTaskActivity() {
        serverTaskActivity.reset()
        for continuation in taskActivitySubscribers.values { continuation.finish() }
        taskActivitySubscribers.removeAll()
    }

    private func rejectServerTaskIdentity() {
        for continuation in taskActivitySubscribers.values {
            continuation.yield(.init(name: "auth_failed", payload: nil))
            continuation.finish()
        }
        taskActivitySubscribers.removeAll()
    }

    private func finishServerTaskActivity(source: ServerTaskActivitySession.Source, client: ABSClient, epoch: UUID) {
        guard accountEpoch == epoch, self.client === client, serverTaskActivity.source == source else { return }
        let disconnected = RealtimeEvent(name: "disconnected", payload: nil)
        _ = try? serverTaskActivity.consume(disconnected, from: source)
        for continuation in taskActivitySubscribers.values {
            continuation.yield(disconnected)
            continuation.finish()
        }
        taskActivitySubscribers.removeAll()
    }

    var serverTaskResults: [ServerTask] {
        guard ServerTasksSource(store: self) != nil else { return [] }
        return serverTaskActivity.state.tasks.filter { $0.isFinished && ($0.isFailed || $0.showSuccess == true) }
    }

    func subscribeServerTaskActivity(profile expectedProfile: ServerProfile, client expectedClient: ABSClient,
                                     id: UUID) throws -> AsyncStream<RealtimeEvent> {
        guard profile == expectedProfile, client === expectedClient, ServerTasksSource(store: self) != nil else { throw ABSError.sessionChanged }
        let replay = try serverTaskActivity.replay()
        return AsyncStream { continuation in
            taskActivitySubscribers[id] = continuation
            replay.forEach { continuation.yield($0) }
            if !serverTaskActivity.isAuthenticated { continuation.yield(.init(name: "disconnected", payload: nil)) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.unsubscribeServerTaskActivity(id: id) }
            }
        }
    }
    func unsubscribeServerTaskActivity(id: UUID) {
        taskActivitySubscribers.removeValue(forKey: id)?.finish()
    }
    func cancelServerActivityScan(libraryID: String) throws {
        guard ServerTasksSource(store: self) != nil, serverTaskActivity.isAuthenticated, let restoreEvents else { throw ABSError.sessionChanged }
        try restoreEvents.cancelScan(libraryID: libraryID)
    }
    func requireServerTaskActivity(client expected: ABSClient) async throws {
        let epoch = accountEpoch, expectedPartition = partition, activitySource = serverTaskActivity.source
        guard activitySource != nil else { throw ServerActivityUnavailable() }
        for _ in 0..<50 {
            try Task.checkCancellation()
            guard accountEpoch == epoch, client === expected, partition == expectedPartition,
                  serverTaskActivity.source == activitySource, ServerTasksSource(store: self) != nil else { throw ABSError.sessionChanged }
            if serverTaskActivity.isAuthenticated { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServerActivityUnavailable()
    }

    private func observeServerRestores(profile: ServerProfile, client: ABSClient, epoch: UUID) {
        restoreEventTask?.cancel(); restoreEvents?.disconnect()
        clearServerTaskActivity()
        let activitySource = partition.map { ServerTaskActivitySession.Source(partition: $0, generation: epoch) }
        if let activitySource, user.map({ AdminPolicy.allows(.manageServer, user: $0) }) == true { serverTaskActivity.begin(activitySource) }
        let events = ABSRealtimeClient(); restoreEvents = events
        restoreEventTask = Task { [weak self] in
            defer {
                events.disconnect()
                if let activitySource {
                    self?.finishServerTaskActivity(source: activitySource, client: client, epoch: epoch)
                }
            }
            do {
                let stream = try await events.connect(profile: profile, client: client)
                for await event in stream {
                    guard !Task.isCancelled, let self, self.accountEpoch == epoch, self.client === client else { return }
                    if let activitySource, self.partition == activitySource.partition,
                       self.user.map({ AdminPolicy.allows(.manageServer, user: $0) }) == true {
                        do {
                            if try self.serverTaskActivity.consume(event, from: activitySource) {
                                for continuation in self.taskActivitySubscribers.values { continuation.yield(event) }
                            } else if event.name == "init", self.serverTaskActivity.source == activitySource {
                                self.rejectServerTaskIdentity()
                            }
                        } catch {
                            if event.name == "init", self.serverTaskActivity.source == activitySource {
                                self.serverTaskActivity.begin(activitySource)
                                self.rejectServerTaskIdentity()
                            }
                        }
                    }
                    if event.name == "backup_applied" {
                        // ABS sends this event with either no payload or a single null.
                        self.beginServerRecovery(profile: profile)
                        return
                    } else if event.name == "user_updated" {
                        self.accountUpdateTask?.cancel()
                        self.accountUpdateTask = Task { [weak self] in
                            await self?.handleCurrentUserUpdate(event, client: client, epoch: epoch)
                        }
                    } else if event.name == "user_item_progress_updated" {
                        await self.handleConfirmedProgressEvent(event, client: client, epoch: epoch)
                    } else if event.name == "user_session_closed" {
                        await self.handlePlaybackSessionClosed(event, client: client, epoch: epoch)
                    }
                }
            } catch {
                // The transport reconnects itself. A failed observer must not replace
                // an unrelated account's UI or claim that restoration occurred.
            }
        }
    }

    private struct ConfirmedProgressEvent: Decodable {
        struct Value: Decodable {
            let userID: String
            let progress: MediaProgress
            private enum CodingKeys: String, CodingKey { case userId }
            init(from decoder: Decoder) throws {
                userID = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .userId)
                progress = try MediaProgress(from: decoder)
            }
        }
        let data: Value
    }

    func handleConfirmedProgressEvent(_ event: RealtimeEvent, client: ABSClient, epoch: UUID) async {
        guard event.name == "user_item_progress_updated", let data = event.payload,
              let value = try? JSONDecoder().decode(ConfirmedProgressEvent.self, from: data),
              let partition, let database, value.data.userID == partition.userID else { return }
        try? await rememberConfirmedProgress(value.data.progress, client: client, partition: partition, database: database, epoch: epoch)
    }

    private func rememberConfirmedProgress(_ progress: MediaProgress, client: ABSClient, partition: AccountPartition, database: ShelfDatabase, epoch: UUID) async throws {
        try requireCurrent(epoch)
        guard self.client === client, self.partition == partition, self.database === database,
              user?.id == partition.userID, user?.isActive == true, !isConnecting,
              !recoveryBusy, serverRecovery == nil else { throw CancellationError() }
        let saved = try await database.saveConfirmedProgress(progress, partition: partition)
        try requireCurrent(epoch)
        guard self.client === client, self.partition == partition, self.database === database else { throw CancellationError() }
        if (saved.lastUpdate ?? 0) > (remoteProgressByItem[saved.id]?.lastUpdate ?? -1) {
            remoteProgressByItem[saved.id] = saved
        }
    }

    private func playbackBaseline(_ media: PlaybackMedia, partition: AccountPartition, database: ShelfDatabase) async throws -> MediaProgress? {
        let cached = remoteProgressByItem[media.id]
        let pending = try await database.pendingSessions(partition: partition)
        if let latest = OfflineSyncPolicy.ordered(pending).first(where: { $0.mediaKey == OfflinePlaybackSession.mediaKey(itemID: media.itemID, episodeID: media.episodeID) }) {
            // A new session must not silently rebase older unsynchronized work.
            guard let timestamp = latest.serverProgressUpdatedAt, let position = latest.serverCurrentTime,
                  let finished = latest.serverFinished else { return nil }
            return MediaProgress(libraryItemId: media.itemID, episodeId: media.episodeID, currentTime: position,
                                 duration: latest.duration, isFinished: finished, lastUpdate: timestamp)
        }
        let confirmed = try await database.confirmedProgress(itemID: media.itemID, episodeID: media.episodeID, partition: partition)
        if let confirmed, (confirmed.lastUpdate ?? 0) > (cached?.lastUpdate ?? -1) { return confirmed }
        return cached
    }

    func handleCurrentUserUpdate(_ event: RealtimeEvent, client: ABSClient, epoch: UUID) async {
        guard event.name == "user_updated", let data = event.payload,
              let updated = try? JSONDecoder().decode(UserAccount.self, from: data),
              updated.id == user?.id, accountEpoch == epoch, self.client === client,
              !isConnecting, !recoveryBusy, serverRecovery == nil else { return }
        // Treat the event as invalidation, not an authoritative permission grant.
        await refresh()
    }

    func handlePlaybackSessionClosed(_ event: RealtimeEvent, client: ABSClient, epoch: UUID) async {
        guard event.name == "user_session_closed", let payload = event.payload,
              let id = try? JSONDecoder().decode(String.self, from: payload), !id.isEmpty,
              self.client === client, accountEpoch == epoch, !isConnecting,
              !recoveryBusy, serverRecovery == nil, let player,
              player.currentRemoteSessionID == id else { return }
        playRequestID = UUID()
        do {
            let stopped = try await player.serverSessionClosed(sessionID: id)
            guard accountEpoch == epoch, self.client === client, self.player === player else { return }
            if stopped { notice = L10n.tr("服务器已关闭当前收听会话。此 Mac 的播放位置已保存在本机。") }
        } catch {
            guard accountEpoch == epoch, self.client === client, self.player === player else { return }
            presentError(.capture(error))
        }
    }

    func requestServerRestore(backupID: String, context: ServerAdminContext) {
        guard !recoveryBusy, !isConnecting, !isOffline, !isDemo,
              context.accountEpoch == accountEpoch,
              context.isAdministrator, client === context.client, profile?.id == context.profileID,
              user?.id == context.userID, user?.isActive == true, user?.isAdmin == true,
              let profile else { return }
        beginServerRecovery(profile: profile, backupID: backupID, expectedUserID: context.userID)
    }

    /// The task belongs to the application, not the sheet that initiated it.
    /// Once a request may have reached ABS, neither closing UI nor restarting this
    /// application may replay it. Pending batches are resumed as local cleanup only.
    private func beginServerRecovery(profile saved: ServerProfile, batch existing: ServerRestoreBatch? = nil,
                                     backupID: String? = nil, expectedUserID: String? = nil) {
        guard !recoveryBusy else { return }
        let proposed: ServerRestoreBatch
        do {
            let endpoint = try ServerRestoreBatch.canonicalURL(saved.baseURL.absoluteString)
            let affected = profiles.filter { (try? ServerRestoreBatch.canonicalURL($0.baseURL.absoluteString)) == endpoint }.map(\.id)
            proposed = try ServerRestoreBatch(id: existing?.id ?? UUID(), canonicalBaseURL: endpoint,
                                              profileIDs: (existing?.profileIDs ?? []) + affected + [saved.id],
                                              createdAt: existing?.createdAt ?? Date(), origin: existing?.origin ?? (backupID == nil ? .observed : .requested),
                                              reason: existing?.reason ?? "serverBackupRestore", backupID: existing?.backupID ?? backupID)
        } catch { errorMessage = L10n.error(error); return }
        let previousDownloads = downloads
        retainPlaybackForRecovery(player, partition: partition)
        let previousReadingShutdown = readingShutdown ?? recoveryReadingShutdown
        recoveryReadingShutdown = previousReadingShutdown
        if let client, let activeProfile = profile,
           (try? ServerRestoreBatch.canonicalURL(activeProfile.baseURL.absoluteString)) == proposed.canonicalBaseURL {
            if trackedClients[ObjectIdentifier(client)] == nil {
                trackedClients[ObjectIdentifier(client)] = .init(endpoint: proposed.canonicalBaseURL, client: client)
            }
        }
        _ = beginAccountChange()
        playbackCallbackEpoch = UUID()
        restoringEndpoints.insert(proposed.canonicalBaseURL)
        serverRecovery = proposed; recoveryBusy = true; recoveryError = nil; recoveryRestartConfirmed = nil
        accountReauthenticationRequired = false; accountAccessRefreshPending = false
        isConnecting = true; isOffline = false; isDemo = false; showConnection = false
        profile = saved; user = nil; client = nil; player = nil; readingShutdown = nil; downloads = nil
        items = []; libraries = []; progressByItem = [:]; remoteProgressByItem = [:]; playbackBaselines = [:]
        selectedItem = nil; conflicts = []; readingConflicts = []; readingIsActive = false; readingActivityID = nil
        totalItems = 0; search = ""; browsingLibraryID = nil; route = .home; notice = nil; errorMessage = nil
        serverProgressIsFresh = false; libraryRevision = UUID()
        let sources = trackedClients.values.filter { $0.endpoint == proposed.canonicalBaseURL }
        for source in sources { source.isRetired = true }
        let clients = sources.compactMap(\.client)
        recoveryTask = Task { [self] in
            defer { recoveryBusy = false; isConnecting = false; recoveryTask = nil }
            var batch = proposed
            var preparationError: (any Error)?
            do {
                guard let database, let readingRepository else { throw ServerRestoreArchiveError.incompleteArchive }
                // Durable barrier precedes all network actions; each SQLite archive
                // is atomic, while the persisted batch coordinates both databases.
                batch = try await database.beginServerRestore(proposed)
                serverRecovery = batch
                _ = try await readingRepository.beginServerRestore(batch)
            } catch { preparationError = error }

            await withTaskGroup(of: Void.self) { group in
                for client in clients { group.addTask { await client.retireForServerRestore() } }
            }
            for write in Array(credentialWrites.values) { _ = try? await write.value }
            await retirePlaybackRecoveryHandles()
            do { try await savePlaybackRecoveryHandles(profileIDs: Set(batch.profileIDs)) }
            catch { preparationError = preparationError ?? error }
            if let previousReadingShutdown {
                do { try await previousReadingShutdown(); recoveryReadingShutdown = nil }
                catch { preparationError = preparationError ?? error }
            }
            if let previousDownloads {
                for record in previousDownloads.records where record.state == .downloading || record.state == .queued {
                    do { try await previousDownloads.pause(itemID: record.itemID) }
                    catch { preparationError = preparationError ?? error }
                }
            }
            do {
                if let preparationError { throw preparationError }
                guard let database, let readingRepository else { throw ServerRestoreArchiveError.incompleteArchive }
                _ = try await database.archiveForServerRestore(batchID: batch.id)
                let reading = try await readingRepository.archiveForServerRestore(batch: batch)
                batch = try await database.markRestoreAwaitingReconnect(batchID: batch.id, readingReceipt: reading)
                serverRecovery = batch
                restoreArchives = try await database.serverRestoreArchives()
                // Only a newly confirmed UI action can enter this branch. Resuming
                // a persisted batch, including an uncertain one, never applies it.
                if let backupID, existing == nil, batch.id == proposed.id {
                    let restoreClient = trackedClient(profile: saved)
                    do {
                        _ = try await restoreClient.status()
                        let actor = try await restoreClient.currentUser()
                        guard actor.id == expectedUserID, actor.isActive, actor.isAdmin else { throw ABSError.sessionChanged }
                        batch = try await database.recordServerRestoreOrigin(batchID: batch.id, origin: .uncertain)
                        serverRecovery = batch
                        try await restoreClient.applyBackup(id: backupID)
                        batch = try await database.recordServerRestoreOrigin(batchID: batch.id, origin: .observed)
                        serverRecovery = batch
                    } catch {
                        recoveryError = L10n.error(error)
                    }
                    await restoreClient.retireForServerRestore()
                    trackedClients[ObjectIdentifier(restoreClient)] = nil
                }
            } catch { recoveryError = L10n.error(error) }
        }
    }

    func retryRecoveryPreparation() {
        guard let profile, let batch = serverRecovery, !recoveryBusy else { return }
        beginServerRecovery(profile: profile, batch: batch)
    }

    /// The user explicitly acknowledges the required server-process restart.
    /// A new authenticated read cannot prove that restart; never claim otherwise.
    func reconnectServerRecovery() async {
        guard !recoveryBusy, let batch = serverRecovery, batch.state == .awaitingReconnect, let saved = profile else { return }
        recoveryRestartConfirmed = batch.id
        let epoch = beginAccountChange()
        isConnecting = true; recoveryBusy = true; recoveryError = nil
        defer { if accountEpoch == epoch { isConnecting = false; recoveryBusy = false } }
        let nextClient = trackedClient(profile: saved)
        do {
            _ = try await nextClient.status(); try requireCurrent(epoch)
            // A restored database may have removed this refresh session while its
            // old access token still works. Verify renewal before clearing the gate.
            let account = try await nextClient.validateServerRecoveryAuthentication(); try requireCurrent(epoch)
            let nextProfile = await nextClient.profile; try requireCurrent(epoch)
            try await finishServerRecovery(batch, profile: nextProfile, client: nextClient, epoch: epoch)
            guard await configure(profile: nextProfile, user: account, client: nextClient, epoch: epoch) else { return }
            profiles.removeAll { $0.id == nextProfile.id }; profiles.insert(nextProfile, at: 0); saveProfiles()
            recoveryBusy = false; isConnecting = false
            await refresh()
        } catch {
            await nextClient.retireForServerRestore()
            trackedClients[ObjectIdentifier(nextClient)] = nil
            guard accountEpoch == epoch else { return }
            recoveryError = L10n.error(error)
            if case ABSError.notAuthenticated = error { showConnection = true }
            if case ABSError.http(let status, _) = error, status == 401 || status == 403 { showConnection = true }
        }
    }

    private func recoveryBeforeAuthentication(url: URL) async throws -> ServerRestoreBatch? {
        let canonical = try ServerRestoreBatch.canonicalURL(url.absoluteString)
        try await repairCompletedRecoveryIfNeeded(endpoint: canonical)
        guard let database else { throw ServerRestoreArchiveError.incompleteArchive }
        let all = try await database.pendingServerRestores()
        guard let batch = all.first(where: { $0.canonicalBaseURL == canonical }) else {
            guard !restoringEndpoints.contains(canonical) else { throw ServerRestoreArchiveError.pendingRestore }
            return nil
        }
        guard batch.state == .awaitingReconnect, recoveryRestartConfirmed == batch.id else { throw ServerRestoreArchiveError.pendingRestore }
        return batch
    }

    private func finishServerRecovery(_ batch: ServerRestoreBatch, profile: ServerProfile, client: ABSClient, epoch: UUID) async throws {
        guard recoveryRestartConfirmed == batch.id, batch.state == .awaitingReconnect,
              try ServerRestoreBatch.canonicalURL(profile.baseURL.absoluteString) == batch.canonicalBaseURL,
              let database, let readingRepository, let supportDirectory, let downloadDirectory else { throw ServerRestoreArchiveError.pendingRestore }
        let wasBusy = recoveryBusy
        recoveryBusy = true
        defer { recoveryBusy = wasBusy }
        async let freshLibraries = client.libraries()
        async let freshProgress = client.progress()
        let account = try await client.currentUser()
        _ = try await (freshLibraries, freshProgress)
        try requireCurrent(epoch)
        guard account.isActive, account.id == profile.userID else { throw ABSError.notAuthenticated }
        try await pauseDownloadsForStorageReplacement()
        try requireCurrent(epoch)
        // Build replacement actors before removing the durable gate. Their lease
        // sees the sealed epoch; no old callback can regain a writable lease.
        let nextDatabase = try ShelfDatabase(path: supportDirectory.appendingPathComponent("Audilse.sqlite"))
        let nextReading = try ReadingRepository(rootDirectory: supportDirectory.appendingPathComponent("Reading", isDirectory: true))
        let complete = try await database.completeServerRestore(batchID: batch.id)
        try await readingRepository.completeServerRestore(batch: complete)
        try requireCurrent(epoch)
        self.database = nextDatabase; self.readingRepository = nextReading
        sync = SyncCoordinator(database: nextDatabase)
        downloads = DownloadManager(database: nextDatabase, rootDirectory: downloadDirectory)
        restoringEndpoints.remove(batch.canonicalBaseURL)
        serverRecovery = nil; recoveryRestartConfirmed = nil; recoveryError = nil
        restoreArchives = try await nextDatabase.serverRestoreArchives()
    }

    /// Finish the local second phase after a successful main-DB commit. This is
    /// safe to repeat and makes a failed reading-DB commit recoverable in-process.
    private func repairCompletedRecoveryIfNeeded(endpoint: String) async throws {
        guard restoringEndpoints.contains(endpoint), let database, let readingRepository,
              let supportDirectory, let downloadDirectory else { return }
        let wasBusy = recoveryBusy
        recoveryBusy = true
        defer { recoveryBusy = wasBusy }
        let batches = try await database.serverRestoreArchives()
        let completed = batches.filter { $0.canonicalBaseURL == endpoint && $0.state == .completed }
        guard !batches.contains(where: { $0.canonicalBaseURL == endpoint && $0.state != .completed }), !completed.isEmpty else { return }
        try await pauseDownloadsForStorageReplacement()
        for batch in completed { try await readingRepository.completeServerRestore(batch: batch) }
        let nextDatabase = try ShelfDatabase(path: supportDirectory.appendingPathComponent("Audilse.sqlite"))
        let nextReading = try ReadingRepository(rootDirectory: supportDirectory.appendingPathComponent("Reading", isDirectory: true))
        self.database = nextDatabase; self.readingRepository = nextReading
        sync = SyncCoordinator(database: nextDatabase)
        downloads = DownloadManager(database: nextDatabase, rootDirectory: downloadDirectory)
        restoringEndpoints.remove(endpoint)
        if serverRecovery?.canonicalBaseURL == endpoint { serverRecovery = nil; recoveryRestartConfirmed = nil; recoveryError = nil }
        restoreArchives = batches
    }

    private func pauseDownloadsForStorageReplacement() async throws {
        guard let previousDownloads = downloads else { return }
        for record in previousDownloads.records where record.state == .downloading || record.state == .queued {
            try await previousDownloads.pause(itemID: record.itemID)
        }
    }

    private func reconcileCompletedRestores() async throws {
        guard let database, let readingRepository else { return }
        let batches = try await database.serverRestoreArchives()
        for batch in batches where batch.state == .completed { try await readingRepository.completeServerRestore(batch: batch) }
        restoreArchives = batches
        restoringEndpoints = Set(batches.filter { $0.state != .completed }.map(\.canonicalBaseURL))
    }

    func exportRestoreArchive(_ batch: ServerRestoreBatch) async throws -> Data {
        guard !recoveryBusy, let database, let readingRepository else { throw ServerRestoreArchiveError.incompleteArchive }
        let reading = try await readingRepository.archiveSnapshot(batchID: batch.id)
        return try await database.exportServerRestoreArchive(batchID: batch.id, readingArchive: reading)
    }

    /// The application delegate awaits this before replying to an explicit quit.
    @discardableResult func shutdown() async -> Bool {
        publicSharing.cancelOpening()
        await recoveryTask?.value
        let previousEpoch = accountEpoch
        let previousClient = client, previousPartition = partition
        let previousProfileID = profile?.id, previousUserID = user?.id
        let previousPlayer = player, previousDownloads = downloads
        let previousShare = publicSharing.identity
        isConnecting = true
        do {
            try await checkpointReadingBeforeTransition()
            try await savePlaybackRecoveryHandles()
            if let recoveryReadingShutdown { try await recoveryReadingShutdown(); self.recoveryReadingShutdown = nil }
        } catch {
            if accountEpoch == previousEpoch { isConnecting = false; errorMessage = L10n.error(error) }
            return false
        }
        guard accountEpoch == previousEpoch, client === previousClient, partition == previousPartition,
              profile?.id == previousProfileID, user?.id == previousUserID, player === previousPlayer else { return false }
        guard await publicSharing.checkpoint() else {
            isConnecting = false
            if let diagnostic = publicSharing.diagnostic { presentError(diagnostic) }
            return false
        }
        if let previousPlayer {
            let receipt = await previousPlayer.checkpointForTransition()
            guard receipt.mayQuit else {
                isConnecting = false
                if let diagnostic = receipt.diagnostic { presentError(diagnostic) }
                return false
            }
        }
        guard accountEpoch == previousEpoch, player === previousPlayer,
              publicSharing.identity == previousShare else { isConnecting = false; return false }
        guard await publicSharing.stop() else {
            isConnecting = false
            if let diagnostic = publicSharing.diagnostic { presentError(diagnostic) }
            return false
        }
        guard accountEpoch == previousEpoch, player === previousPlayer, !publicSharing.isActive else { isConnecting = false; return false }
        if let previousPlayer {
            let receipt = await previousPlayer.shutdownForQuit()
            guard accountEpoch == previousEpoch, client === previousClient, partition == previousPartition,
                  profile?.id == previousProfileID, user?.id == previousUserID, player === previousPlayer else { return false }
            guard receipt.mayQuit else {
                isConnecting = false
                if let diagnostic = receipt.diagnostic { presentError(diagnostic) }
                return false
            }
        }
        _ = beginAccountChange()
        player = nil
        if let previousDownloads {
            let active = previousDownloads.records.filter { $0.state == .downloading || $0.state == .queued }
            for record in active { try? await previousDownloads.pause(itemID: record.itemID) }
        }
        return true
    }

    private func retainPlaybackForRecovery(_ source: PlaybackController?, partition: AccountPartition?) {
        guard let source else { return }
        for handle in source.detachForRecovery() {
            retiredPlayback[handle.id] = RetiredPlayback(handle: handle, partition: partition)
        }
    }

    private func retirePlaybackRecoveryHandles() async {
        for entry in Array(retiredPlayback.values) { await entry.handle.retireToLocalRecovery() }
    }

    private func savePlaybackRecoveryHandles(profileIDs: Set<UUID>? = nil) async throws {
        let pending = retiredPlayback.filter { _, entry in
            guard let profileIDs, let partition = entry.partition else { return true }
            return profileIDs.contains(partition.serverID)
        }
        var failure: ClientDiagnostic?
        for (id, entry) in pending {
            await entry.handle.retireToLocalRecovery()
            let receipt = await entry.handle.finalize()
            if receipt.cumulativeSnapshotSaved { retiredPlayback[id] = nil }
            else { failure = failure ?? receipt.diagnostic ?? .init(code: "playback.finalSnapshotNotDurable", fallbackMessage: "完整播放记录尚未安全保存，请重试。") }
        }
        if let failure { throw failure }
    }

    private func checkpointPlaybackBeforeTransition() async throws {
        let epoch = accountEpoch, source = player, sourcePartition = partition
        let sourceClient = client, sourceProfileID = profile?.id, sourceUserID = user?.id
        try await savePlaybackRecoveryHandles()
        guard accountEpoch == epoch, player === source, partition == sourcePartition,
              client === sourceClient, profile?.id == sourceProfileID, user?.id == sourceUserID else { throw CancellationError() }
        if let source {
            let receipt = await source.checkpointForTransition()
            guard accountEpoch == epoch, player === source, partition == sourcePartition,
                  client === sourceClient, profile?.id == sourceProfileID, user?.id == sourceUserID else { throw CancellationError() }
            guard receipt.mayQuit else {
                throw receipt.diagnostic ?? ClientDiagnostic(code: "playback.finalSnapshotNotDurable", fallbackMessage: "完整播放记录尚未安全保存，请重试。")
            }
        }
    }

    private func checkpointReadingBeforeTransition() async throws {
        try Task.checkCancellation()
        guard let readingShutdown else { return }
        let epoch = accountEpoch, sourceClient = client, sourceProfile = profile?.id, sourceUser = user?.id
        try await readingShutdown()
        try Task.checkCancellation()
        guard accountEpoch == epoch, client === sourceClient, profile?.id == sourceProfile,
              user?.id == sourceUser else { throw CancellationError() }
        self.readingShutdown = nil
        readingIsActive = false; readingActivityID = nil
    }

    private func accessCacheInvalidationKey(_ partition: AccountPartition) -> String {
        "accountAccessCacheInvalidation." + partition.serverID.uuidString + "." + ServerEndpoint.component(partition.userID)
    }

    @discardableResult private func beginAccountChange() -> UUID {
        publicSharing.cancelOpening()
        clearServerTaskActivity()
        restoreEventTask?.cancel(); restoreEventTask = nil
        restoreEvents?.disconnect(); restoreEvents = nil
        accountEpoch = UUID(); loadID = UUID(); playRequestID = UUID()
        browseNavigation = nil
        cancelDetailLoading()
        isLoading = false
        return accountEpoch
    }

    private func requireCurrent(_ epoch: UUID, playRequest: UUID? = nil) throws {
        if playRequest != nil { try Task.checkCancellation() }
        guard accountEpoch == epoch, playRequest == nil || playRequestID == playRequest else { throw CancellationError() }
    }

    private func progressID(itemID: String, episodeID: String?) -> String {
        itemID + (episodeID.map { ":" + $0 } ?? "")
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "serverProfiles") }
        UserDefaults.standard.set(false, forKey: "explicitSignedOut")
    }
    private static func isNetworkFailure(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(error.code)
    }
}

enum ConnectionFailure: LocalizedError {
    case invalidAddress, notDownloaded, noAudio
    var errorDescription: String? {
        switch self {
        case .invalidAddress: L10n.tr("请输入有效的 http:// 或 https:// 服务器地址，地址中不要包含账号密码、查询参数或片段。")
        case .notDownloaded: L10n.tr("这本书尚未完整下载。连接服务器后下载，即可离线收听。")
        case .noAudio: L10n.tr("这条内容没有可下载的音频文件。")
        }
    }
}

enum DemoLibrary {
    static let items: [AudilseCore.LibraryItem] = [
        ("山海之间", "林间", "把世界的声音，收进自己的书房。", 26400.0),
        ("时间的形状", "陈序", "关于日常、记忆与缓慢生活的故事。", 31800.0),
        ("远行的人", "江予", "沿着河流走进陌生的城市。", 19200.0),
        ("一间自己的书房", "周眠", "为想象留下一扇窗。", 22500.0),
        ("星河来信", "许知遥", "夜空之下，每一个故事都值得被听见。", 41400.0),
        ("岛屿日记", "余白", "在海风里，重新寻找生活的节奏。", 15600.0),
        ("万物有声", "沈林", "发现那些被忽略的细微声音。", 28800.0),
        ("城市漫游指南", "程以", "用另一种方式认识熟悉的街道。", 24600.0),
        ("长夜与黎明", "南栀", "一个关于勇气与重新出发的故事。", 36600.0),
        ("慢慢走，轻轻听", "林间", "让故事陪你走过每一个平凡日子。", 17400.0),
        ("不远的远方", "江予", "旅程的终点，也是新的起点。", 28200.0),
        ("四季的手稿", "余白", "收集春风、夏雨和冬日的阳光。", 20400.0)
    ].enumerated().map { index, book in
        .init(id: "sample-\(index)", libraryId: "demo", media: .init(
            metadata: .init(title: book.0, authorName: book.1, narratorName: "Audilse 演示", description: book.2, genres: [index % 2 == 0 ? "文学" : "生活"], publishedYear: "2026"),
            chapters: (0..<8).map { chapter in .init(id: chapter, title: "第 \(chapter + 1) 章", start: Double(chapter) * book.3 / 8, end: Double(chapter + 1) * book.3 / 8) }, duration: book.3))
    }
}

private struct ServerActivityUnavailable: LocalizedError {
    var errorDescription: String? { L10n.tr("后台结果连接尚未就绪，尚未提交导入。请连接后再试。") }
}
