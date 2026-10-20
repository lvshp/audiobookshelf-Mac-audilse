import Darwin
import Foundation

public final class AppUpdateInstallation: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(process: Process) { self.process = process }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process.isRunning
    }

    /// False means the helper did not stop in time; retain staging in that case.
    @discardableResult public func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard process.isRunning else { return true }
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}

public struct PreparedAppUpdate: Sendable {
    public let stagingDirectory: URL
    public let destination: URL

    public func discard() { try? FileManager.default.removeItem(at: stagingDirectory) }

    /// Starts a helper that waits for this process to exit. Cancel it if shutdown is refused.
    @discardableResult public func start(parentPID: Int32) throws -> AppUpdateInstallation {
        guard parentPID > 1 else { throw AppInstallationError.invalidApplication }
        let helper = stagingDirectory.appendingPathComponent("install.sh")
        let log = stagingDirectory.appendingPathComponent("install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(parentPID), stagingDirectory.appendingPathComponent("Audilse.app").path,
                             destination.path, stagingDirectory.appendingPathComponent("Previous.app").path,
                             stagingDirectory.path, "/usr/bin/open"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        return AppUpdateInstallation(process: process)
    }
}

public enum AppInstallationError: Error, LocalizedError, Sendable {
    case unwritableLocation, invalidApplication, commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unwritableLocation: "The application location is not writable. Move Audilse to Applications, or install the download manually."
        case .invalidApplication: "The update does not contain the expected Audilse application."
        case .commandFailed(let message): "The update could not be prepared: \(message)"
        }
    }
}

public actor AppUpdateInstaller {
    public init() {}

    public func prepare(dmg: URL, release: AppUpdateRelease, installedApp: URL, progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }) async throws -> PreparedAppUpdate {
        let fm = FileManager.default
        let destination = installedApp.resolvingSymlinksInPath().standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app", destination.lastPathComponent == "Audilse.app",
              fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: destination.path),
              !destination.path.hasPrefix("/Volumes/") else { throw AppInstallationError.unwritableLocation }
        let root = parent.appendingPathComponent(".Audilse-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let mount = fm.temporaryDirectory.appendingPathComponent("Audilse-update-mount-" + UUID().uuidString, isDirectory: true)
        var mounted = false, prepared = false
        defer {
            if mounted { _ = try? Self.runCommand("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"], timeout: 15, ignoresCancellation: true) }
            if !prepared { try? fm.removeItem(at: root) }
            // Never recurse into a mount that hdiutil could not detach.
            _ = mount.path.withCString { rmdir($0) }
        }
        try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // An attach can mount successfully before its process is cancelled.
        progress(.mounting)
        mounted = true
        _ = try Self.runCommand("/usr/bin/hdiutil", ["attach", dmg.path, "-readonly", "-nobrowse", "-mountpoint", mount.path, "-quiet"])
        progress(.verifyingApplication)
        let source = mount.appendingPathComponent("Audilse.app", isDirectory: true)
        guard source.resolvingSymlinksInPath().path.hasPrefix(mount.resolvingSymlinksInPath().path + "/"),
              let bundle = Bundle(url: source), bundle.bundleIdentifier == "app.audilse.client",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version.version,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == String(release.version.build),
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Audilse" else {
            throw AppInstallationError.invalidApplication
        }
        _ = try Self.runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let executable = source.appendingPathComponent("Contents/MacOS/Audilse")
        let archs = try Self.runCommand("/usr/bin/lipo", ["-archs", executable.path])
        guard archs.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" else { throw AppInstallationError.invalidApplication }
        try Task.checkCancellation()
        progress(.copyingApplication)
        let staged = root.appendingPathComponent("Audilse.app", isDirectory: true)
        _ = try Self.runCommand("/usr/bin/ditto", [source.path, staged.path])
        progress(.verifyingStagedApplication)
        _ = try Self.runCommand("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        _ = try Self.runCommand(staged.appendingPathComponent("Contents/MacOS/Audilse").path, ["--verify-resources"])
        progress(.unmounting)
        _ = try Self.runCommand("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
        mounted = false
        try Self.helperScript.write(to: root.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        prepared = true
        return PreparedAppUpdate(stagingDirectory: root, destination: destination)
    }

    // File-backed output cannot block the child when a pipe buffer fills.
    // Cleanup commands can ignore task cancellation, but still have a hard deadline.
    static func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60,
                           ignoresCancellation: Bool = false) throws -> String {
        if !ignoresCancellation { try Task.checkCancellation() }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("Audilse-command-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let log = temporary.appendingPathComponent("output")
        guard fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppInstallationError.commandFailed("Cannot create command output file.")
        }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if (!ignoresCancellation && Task.isCancelled) || ProcessInfo.processInfo.systemUptime > deadline {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let killDeadline = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
                if !ignoresCancellation { try Task.checkCancellation() }
                throw AppInstallationError.commandFailed("Operation timed out.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let input = try FileHandle(forReadingFrom: log)
        defer { try? input.close() }
        let text = String(decoding: try input.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw AppInstallationError.commandFailed(String(text.prefix(1200))) }
        if !ignoresCancellation { try Task.checkCancellation() }
        return text
    }

    // Arguments are passed separately, never interpolated into shell source.
    // The previous app is restored if replacement or LaunchServices fails.
    static let helperScript = #"""
    #!/bin/sh
    set -eu
    PID="$1"; STAGED="$2"; TARGET="$3"; BACKUP="$4"; ROOT="$5"; OPEN="$6"
    COUNT=0
    while kill -0 "$PID" 2>/dev/null; do
      COUNT=$((COUNT + 1))
      [ "$COUNT" -lt 600 ] || exit 12
      sleep 1
    done
    [ -d "$STAGED" ] && [ -d "$TARGET" ] && [ ! -e "$BACKUP" ] || exit 13
    /bin/mv "$TARGET" "$BACKUP"
    if /bin/mv "$STAGED" "$TARGET"; then
      if "$OPEN" -n "$TARGET"; then
        /bin/rm -rf "$ROOT"
        exit 0
      fi
      /bin/mv "$TARGET" "$STAGED"
    fi
    /bin/mv "$BACKUP" "$TARGET"
    "$OPEN" -n "$TARGET" || true
    exit 14
    """#
}
