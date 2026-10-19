import AppKit
import AudilseCore
import Observation

@MainActor @Observable
final class AppUpdateController {
    static let shared = AppUpdateController()
    private let client = GitHubUpdateClient()
    private let installer = AppUpdateInstaller()
    private var downloadTask: Task<Void, Never>?
    private var prepared: PreparedAppUpdate?
    private var installation: AppUpdateInstallation?
    var isChecking = false
    var isDownloading = false
    var isInstalling = false
    private(set) var isCancellingInstallation = false
    var availableRelease: AppUpdateRelease?
    var statusMessage: String?
    var errorMessage: String?

    private var installedVersion: AppUpdateVersion? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let build = Int(text) else { return nil }
        return try? AppUpdateVersion(version: version, build: build)
    }
    var currentVersionDescription: String {
        guard let current = installedVersion else { return L10n.tr("开发版本") }
        return "\(current.version) (\(current.build))"
    }

    func check() async {
        guard !isChecking, !isDownloading, !isInstalling, !isCancellingInstallation else { return }
        isChecking = true; errorMessage = nil; statusMessage = nil
        defer { isChecking = false }
        do {
            guard let current = installedVersion else { throw AppUpdateError.invalidVersion }
            let release = try await client.latestRelease()
            if release.version > current { availableRelease = release }
            else { availableRelease = nil; statusMessage = L10n.tr("当前已是最新版本。") }
        } catch {
            errorMessage = L10n.format("检查更新失败：%1$@", message(for: error))
        }
    }

    func downloadAndInstall() async {
        guard let release = availableRelease, let current = installedVersion, release.version > current,
              !isChecking, !isDownloading, !isInstalling, !isCancellingInstallation, installation == nil else { return }
        errorMessage = nil; statusMessage = nil; isDownloading = true
        let task = Task { @MainActor in
            var downloaded: URL?
            defer {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                isDownloading = false; downloadTask = nil
            }
            do {
                let dmg = try await client.download(release); downloaded = dmg
                try Task.checkCancellation()
                isDownloading = false; isInstalling = true
                prepared = try await installer.prepare(dmg: dmg, release: release, installedApp: Bundle.main.bundleURL)
                try Task.checkCancellation()
                NSApp.terminate(nil)
            } catch {
                if let prepared { Task.detached { prepared.discard() } }
                prepared = nil
                isInstalling = false
                if Task.isCancelled { statusMessage = L10n.tr("已取消下载。") }
                else { errorMessage = L10n.format("更新未能安装：%1$@", message(for: error)) }
            }
        }
        downloadTask = task
        await task.value
    }

    func cancelDownload() { downloadTask?.cancel() }

    /// Start the waiting helper before changing application state. It only
    /// replaces the bundle after this process actually exits.
    func beginInstallationExit() -> Bool {
        guard !isCancellingInstallation else { return false }
        if installation != nil {
            cancelPreparedInstallation()
            return false
        }
        guard let prepared else { return true }
        do {
            installation = try prepared.start(parentPID: ProcessInfo.processInfo.processIdentifier)
            return true
        } catch {
            Task.detached { prepared.discard() }
            self.prepared = nil; isInstalling = false
            errorMessage = L10n.format("更新未能安装：%1$@", message(for: error))
            return false
        }
    }

    func cancelPreparedInstallation() {
        guard !isCancellingInstallation else { return }
        isCancellingInstallation = true
        let transfer = downloadTask
        transfer?.cancel()
        let pending = prepared, helper = installation
        Task {
            defer { isCancellingInstallation = false }
            await transfer?.value
            let stopped = await Task.detached { helper?.cancel() ?? true }.value
            guard stopped else {
                errorMessage = L10n.tr("暂时无法停止更新助手，请保持应用打开并稍后重试。")
                return
            }
            if let pending { Task.detached { pending.discard() } }
            installation = nil
            prepared = nil; isInstalling = false
            errorMessage = L10n.tr("未能保存当前状态，更新已取消。请处理保存错误后重试。")
        }
    }

    private func message(for error: any Error) -> String {
        if let update = error as? AppUpdateError {
            let text: String
            switch update {
            case .invalidVersion: text = "更新版本信息无效。"
            case .invalidRelease: text = "发布信息不是受支持的 Audilse 正式版本。"
            case .unsafeURL: text = "更新下载地址未通过校验。"
            case .missingAsset: text = "发布版本缺少 Apple 芯片安装包或校验文件。"
            case .invalidResponse: text = "更新服务器返回了无效响应。"
            case .tooLarge: text = "更新文件超过允许的大小。"
            case .invalidChecksum: text = "更新校验文件无效。"
            case .checksumMismatch: text = "安装包 SHA-256 校验失败，请重新下载。"
            }
            return L10n.tr(text)
        }
        if let install = error as? AppInstallationError {
            switch install {
            case .unwritableLocation: return L10n.tr("应用所在目录不可写。请将 Audilse 放入应用程序目录，或从 GitHub 手动下载安装。")
            case .invalidApplication: return L10n.tr("安装包中的应用身份或版本与更新信息不一致。")
            case .commandFailed: return L10n.tr("安装准备失败。原应用未被替换，可从 GitHub 手动下载安装。")
            }
        }
        return error.localizedDescription
    }
}
