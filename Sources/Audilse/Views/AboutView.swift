import AppKit
import SwiftUI

struct AboutView: View {
    @State private var updates = AppUpdateController.shared

    private var isBusy: Bool { updates.isChecking || updates.isDownloading || updates.isInstalling || updates.isCancellingInstallation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    if let icon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: icon)
                            .resizable().scaledToFit().frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audilse").font(.title2.bold())
                        Text(updates.currentVersionDescription).foregroundStyle(.secondary)
                        Link(L10n.tr("GitHub 项目主页"), destination: URL(string: "https://github.com/lvshp/audiobookshelf-Mac-audilse")!)
                    }
                }
                Text(L10n.tr("所有内容来自你连接的 Audiobookshelf 服务器。离线内容保存在此 Mac。"))
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Button(L10n.tr("检查更新")) { Task { await updates.check() } }
                        .disabled(isBusy)
                        .accessibilityIdentifier("about.check-updates")
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在检查更新…")).foregroundStyle(.secondary)
                    }
                }
                if let status = updates.statusMessage {
                    Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = updates.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if let release = updates.availableRelease {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("可用更新")).font(.headline)
                        HStack {
                            Text("\(release.version.version) (\(release.version.build))")
                            Spacer()
                            Link(L10n.tr("在 GitHub 查看"), destination: release.pageURL)
                        }
                        if updates.isDownloading || updates.isInstalling {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(L10n.tr(updates.isInstalling ? "正在安装更新…" : "正在下载更新…"))
                                Spacer()
                                if updates.isDownloading && !updates.isInstalling {
                                    Button(L10n.tr("取消下载")) { updates.cancelDownload() }
                                }
                            }
                        } else {
                            Button(L10n.tr("下载并安装更新")) { Task { await updates.downloadAndInstall() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(isBusy)
                                .accessibilityIdentifier("about.install-update")
                        }
                        Text(L10n.tr("安装完成后，Audilse 将退出并重新打开。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.tr("更新说明")).font(.headline)
                        Text(verbatim: release.notes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
