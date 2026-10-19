import Foundation
import Testing
@testable import AudilseCore

private struct UpdateInstallerFixture {
    let root: URL
    let staging: URL
    let target: URL
    let newApp: URL
    let backup: URL
    let helper: URL
    let opener: URL
    init(failingOpen: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Audilse-installer-test-" + UUID().uuidString)
        staging = root.appendingPathComponent("private staging")
        target = root.appendingPathComponent("Audilse.app")
        newApp = staging.appendingPathComponent("Audilse.app")
        backup = staging.appendingPathComponent("Previous.app")
        helper = staging.appendingPathComponent("install.sh")
        opener = root.appendingPathComponent("fake open.sh")
        try FileManager.default.createDirectory(at: newApp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appendingPathComponent("identity"), atomically: true, encoding: .utf8)
        try "new".write(to: newApp.appendingPathComponent("identity"), atomically: true, encoding: .utf8)
        try AppUpdateInstaller.helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try (failingOpen ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\n[ \"$1\" = -n ] && [ -f \"$2/identity\" ]\n")
            .write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func arguments(pid: Int32) -> [String] {
        [helper.path, String(pid), newApp.path, target.path, backup.path, staging.path, opener.path]
    }
    func exitedParent() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run(); process.waitUntilExit()
        return process.processIdentifier
    }
}

@Test func updateInstallerHelperReplacesAndCleansOnlyStaging() throws {
    let fixture = try UpdateInstallerFixture(); defer { fixture.cleanup() }
    _ = try AppUpdateInstaller.runCommand("/bin/sh", fixture.arguments(pid: fixture.exitedParent()), timeout: 5)
    #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
    #expect(FileManager.default.fileExists(atPath: fixture.opener.path))
}

@Test func updateInstallerHelperRestoresOldAppWhenLaunchFails() throws {
    let fixture = try UpdateInstallerFixture(failingOpen: true); defer { fixture.cleanup() }
    #expect(throws: AppInstallationError.self) {
        try AppUpdateInstaller.runCommand("/bin/sh", fixture.arguments(pid: fixture.exitedParent()), timeout: 5)
    }
    #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: fixture.newApp.appendingPathComponent("identity"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
}

@Test func updateInstallerHelperDoesNotReplaceRunningParent() throws {
    let fixture = try UpdateInstallerFixture(); defer { fixture.cleanup() }
    #expect(throws: AppInstallationError.self) {
        try AppUpdateInstaller.runCommand("/bin/sh", fixture.arguments(pid: ProcessInfo.processInfo.processIdentifier), timeout: 0.15)
    }
    #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: fixture.newApp.appendingPathComponent("identity"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
}

@Test func updateInstallerCommandTimeoutKillsChildIgnoringTermination() throws {
    let started = ProcessInfo.processInfo.systemUptime
    #expect(throws: AppInstallationError.self) {
        try AppUpdateInstaller.runCommand("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
    }
    #expect(ProcessInfo.processInfo.systemUptime - started < 3)
}

@Test func updateInstallerStartedHandleCancelsBeforeParentExit() throws {
    let fixture = try UpdateInstallerFixture(); defer { fixture.cleanup() }
    let prepared = PreparedAppUpdate(stagingDirectory: fixture.staging, destination: fixture.target)
    let installation = try prepared.start(parentPID: ProcessInfo.processInfo.processIdentifier)
    #expect(installation.cancel())
    #expect(try String(contentsOf: fixture.target.appendingPathComponent("identity"), encoding: .utf8) == "old")
    prepared.discard()
    #expect(!FileManager.default.fileExists(atPath: fixture.staging.path))
}

@Test func updateInstallerCommandOutputCannotFillAPipeAndCleanupIgnoresCancellation() async throws {
    let output = try AppUpdateInstaller.runCommand("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo output-line; i=$((i+1)); done"], timeout: 5)
    #expect(output.utf8.count == 64 * 1024)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try AppUpdateInstaller.runCommand("/bin/echo", ["cleanup"], timeout: 2, ignoresCancellation: true)
    }
    #expect(try await task.value == "cleanup\n")
}
