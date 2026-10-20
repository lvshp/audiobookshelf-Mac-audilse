#!/usr/bin/env python3
"""Exercise the production termination delegate in an isolated, windowless AppKit process."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/Audilse/AudilseApp.swift').read_text()
start = source.index('    func applicationShouldTerminate(_ sender: NSApplication)')
end = source.index('    func applicationShouldHandleReopen', start)
method = source[start:end]
# Only services are stubs: use the production delegate method verbatim so a
# reintroduced terminateLater/Task nested-loop bug hangs and fails this probe.
probe = r'''
import AppKit
let mode = CommandLine.arguments[1]
@MainActor func report(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}
@MainActor final class AppStore {
    func shutdown() async -> Bool {
        try? await Task.sleep(for: .milliseconds(50))
        report("SAVED")
        return mode != "veto"
    }
}
@MainActor final class AppUpdateController {
    static let shared = AppUpdateController()
    var isInstalling = true
    func beginInstallationExit() -> Bool { report("BEGIN"); return mode != "start-failed" }
    func canFinishInstallationExit() -> Bool { mode != "expired-helper" }
    func cancelPreparedInstallation() { report("CANCELLED"); isInstalling = false }
}
@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore? = AppStore()
    private var isTerminating = false
    private var terminationApproved = false
__METHOD__
    func applicationWillTerminate(_ notification: Notification) { report("EXIT") }
}
@main struct Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            app.terminate(nil)
            if mode == "repeated" { app.terminate(nil) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            report("REMAINED_OPEN")
            exit(0)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''.replace('__METHOD__', method)
with tempfile.TemporaryDirectory(prefix='audilse-termination-test-') as temp:
    path = Path(temp)
    (path / 'Probe.swift').write_text(probe)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(path / 'Probe.swift'), '-o', str(path / 'probe')], check=True, timeout=90)
    for mode in ['success', 'repeated', 'veto', 'expired-helper', 'start-failed']:
        result = subprocess.run([str(path / 'probe'), mode], check=True,
                                capture_output=True, text=True, timeout=8)
        events = result.stdout.splitlines()
        if mode in ['success', 'repeated']:
            assert events == ['BEGIN', 'SAVED', 'EXIT'], (mode, events)
        elif mode == 'start-failed':
            assert events == ['BEGIN', 'REMAINED_OPEN'], (mode, events)
        else:
            assert events == ['BEGIN', 'SAVED', 'CANCELLED', 'REMAINED_OPEN'], (mode, events)
        print(f'PASS: termination {mode}')
