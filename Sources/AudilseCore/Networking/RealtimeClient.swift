import Foundation
@preconcurrency import SocketIO

public struct RealtimeEvent: Sendable {
    public let name: String
    public let payload: Data?
    public init(name: String, payload: Data?) { self.name = name; self.payload = payload }
}

/// Socket.IO v4 transport. All callbacks and mutable socket state run on the main queue.
@MainActor public final class ABSRealtimeClient {
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var authProvider: (@Sendable () async throws -> String)?
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    private var authenticationTask: Task<Void, Never>?
    private var tokenObservationTask: Task<Void, Never>?
    private var connectionEpoch = UUID()
    public private(set) var isConnected = false
    public init() {}

    public func connect(profile: ServerProfile, tokenProvider: @escaping @Sendable () async throws -> String) throws -> AsyncStream<RealtimeEvent> {
        disconnect()
        return try install(profile: profile, tokenProvider: tokenProvider)
    }
    private func install(profile: ServerProfile, tokenProvider: @escaping @Sendable () async throws -> String) throws -> AsyncStream<RealtimeEvent> {
        let attempt = connectionEpoch
        let endpoint = try ServerEndpoint(baseURL: profile.baseURL)
        let path = Self.socketPath(for: endpoint)
        var origin = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        origin.path = "/"; origin.query = nil; origin.fragment = nil
        guard let url = origin.url else { throw ABSError.invalidServerURL }
        let manager = SocketManager(socketURL: url, config: [.path(path), .handleQueue(.main), .log(false), .reconnects(true), .reconnectWait(2), .reconnectWaitMax(30)])
        let socket = manager.defaultSocket
        self.manager = manager; self.socket = socket; self.authProvider = tokenProvider
        let stream = AsyncStream<RealtimeEvent> { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in
                guard let self, self.connectionEpoch == attempt else { return }
                self.disconnect()
            } }
        }
        socket.on(clientEvent: .connect) { [weak self] _, _ in MainActor.assumeIsolated { guard let self, self.connectionEpoch == attempt else { return }; self.authenticate() } }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in MainActor.assumeIsolated { guard let self, self.connectionEpoch == attempt else { return }; self.isConnected = false; self.continuation?.yield(.init(name: "disconnected", payload: nil)) } }
        socket.on("auth_failed") { [weak self] _, _ in MainActor.assumeIsolated { guard let self, self.connectionEpoch == attempt else { return }; self.isConnected = false; self.continuation?.yield(.init(name: "auth_failed", payload: nil)) } }
        for event in Self.serverEvents {
            socket.on(event) { [weak self] data, _ in
                MainActor.assumeIsolated {
                    guard let self, self.connectionEpoch == attempt else { return }
                    if event == "init" { self.isConnected = true }
                    // Encode before crossing concurrency boundaries; do not expose untyped [Any].
                    let first = data.first
                    let payload = first.flatMap { Self.encodePayload($0) }
                    self.continuation?.yield(.init(name: event, payload: payload))
                }
            }
        }
        socket.connect()
        return stream
    }
    public func connect(profile: ServerProfile, client: ABSClient) async throws -> AsyncStream<RealtimeEvent> {
        disconnect()
        let attempt = connectionEpoch
        let tokenChanges = await client.tokenUpdates()
        guard connectionEpoch == attempt else { throw ABSError.sessionChanged }
        let events = try install(profile: profile, tokenProvider: { try await client.accessToken() })
        tokenObservationTask = Task { [weak self] in
            for await tokens in tokenChanges {
                guard !Task.isCancelled, let self, self.connectionEpoch == attempt else { return }
                if tokens == nil { self.disconnect(); return }
                self.authenticate()
            }
        }
        return events
    }
    public func reauthenticate() { authenticate() }
    nonisolated static func socketPath(for endpoint: ServerEndpoint) -> String {
        // Foundation URL.path can omit the trailing slash of a normalized URL.
        // SocketEngine assigns this decoded path to URLComponents.path itself.
        let prefix = endpoint.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "/socket.io" : "/" + prefix + "/socket.io"
    }
    static let serverEvents = ["init", "items_added", "items_updated", "item_added", "item_updated", "item_removed", "user_updated", "user_session_closed", "user_item_progress_updated", "user_item_progress_removed", "download_progress", "download_complete", "scan_start", "scan_progress", "scan_complete", "stream_open", "stream_closed", "stream_reset", "log", "task_started", "task_updated", "task_finished", "task_progress", "track_started", "track_progress", "track_finished", "metadata_embed_queue_update", "backup_applied"]
    static func encodePayload(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
    /// Server enforces the administrator role for these Socket.IO commands.
    public func setLogListener(level: ServerLogLevel) throws {
        guard isConnected else { throw ABSError.notAuthenticated }
        socket?.emit("set_log_listener", level.rawValue)
    }
    public func removeLogListener() { socket?.emit("remove_log_listener") }
    public func cancelScan(libraryID: String) throws {
        guard isConnected else { throw ABSError.notAuthenticated }
        socket?.emit("cancel_scan", libraryID)
    }
    private func authenticate() {
        let attempt = connectionEpoch
        authenticationTask?.cancel()
        authenticationTask = Task { [weak self] in
            guard let self, let provider = self.authProvider else { return }
            do { let token = try await provider(); guard !Task.isCancelled, self.connectionEpoch == attempt else { return }; self.socket?.emit("auth", token) }
            catch {
                guard !Task.isCancelled, self.connectionEpoch == attempt else { return }
                self.continuation?.yield(.init(name: "auth_failed", payload: nil))
            }
        }
    }
    public func disconnect() {
        connectionEpoch = UUID()
        authenticationTask?.cancel(); authenticationTask = nil
        tokenObservationTask?.cancel(); tokenObservationTask = nil
        socket?.removeAllHandlers(); socket?.disconnect(); manager?.disconnect()
        socket = nil; manager = nil; authProvider = nil; isConnected = false
        continuation?.finish(); continuation = nil
    }
}
