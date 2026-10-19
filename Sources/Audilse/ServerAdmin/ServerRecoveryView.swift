import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AudilseCore

struct ServerRecoveryView: View {
    let store: AppStore
    let batch: ServerRestoreBatch
    @State private var restarted = false
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "externaldrive.badge.timemachine").font(.system(size: 38)).foregroundStyle(.tint)
                Text(L10n.tr("服务器恢复后重新连接")).font(.title.bold())
                Text(store.profile?.name ?? batch.canonicalBaseURL).foregroundStyle(.secondary)
                if store.recoveryBusy {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text(L10n.tr("正在整理本机状态，请稍候…")) }
                } else {
                    if batch.origin != .observed {
                        Label(L10n.tr("上次恢复操作未确认完成。请先在服务器端核对结果；Audilse 不会自动重试恢复。"), systemImage: "exclamationmark.triangle")
                    }
                    Text(L10n.tr("播放和同步已暂停。旧的本机进度保留在恢复记录中，下载原件保留。重新连接后不会自动上传这些旧进度。"))
                    Text(L10n.tr("Audiobookshelf 恢复备份后可能保留旧的运行缓存。请管理员重启服务器进程，再重新连接，以免读到恢复前的数据。"))
                    if batch.state == .awaitingReconnect {
                        Toggle(L10n.tr("管理员已重启服务器，我已确认恢复结果"), isOn: $restarted)
                        HStack {
                            Button(L10n.tr("重新连接")) { Task { await store.reconnectServerRecovery() } }
                                .buttonStyle(.borderedProminent).disabled(!restarted)
                            Button(L10n.tr("导出旧本机进度…")) { export(batch) }.disabled(exporting)
                        }
                    } else {
                        Button(L10n.tr("继续整理本机记录")) { store.retryRecoveryPreparation() }.buttonStyle(.borderedProminent)
                    }
                    Button(L10n.tr("连接其他服务器…")) { store.showConnection = true }
                }
                if let error = store.recoveryError ?? exportError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                }
                Text(L10n.tr("导出文件包含旧书库缓存和收听、阅读记录，不会重新写入服务器。请妥善保存。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 660, alignment: .leading).padding(36).frame(maxWidth: .infinity, alignment: .center)
        }
        .onChange(of: batch.id) { _, _ in restarted = false }
    }

    private func export(_ batch: ServerRestoreBatch) {
        exporting = true; exportError = nil
        Task {
            defer { exporting = false }
            do { try await RestoreArchiveExport.save(batch: batch, store: store) }
            catch { exportError = L10n.error(error) }
        }
    }
}

struct ServerRestoreArchivesView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("本机恢复记录")).font(.title2.bold())
                Spacer()
                Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.tr("旧记录仅保留供导出，不会自动重新上传。下载原件仍在本机。"))
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List(store.restoreArchives.sorted { $0.createdAt > $1.createdAt }) { batch in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(batch.canonicalBaseURL).lineLimit(2)
                        Text(batch.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(batch.state == .completed ? L10n.tr("已重新连接") : L10n.tr("等待重新连接")).font(.caption)
                    }
                    Spacer()
                    Button(L10n.tr("导出…")) {
                        exporting = true; error = nil
                        Task {
                            defer { exporting = false }
                            do { try await RestoreArchiveExport.save(batch: batch, store: store) }
                            catch { self.error = L10n.error(error) }
                        }
                    }.disabled(exporting || store.recoveryBusy || batch.state == .collecting)
                }.padding(.vertical, 6)
            }
        }.padding(24).frame(width: 660, height: 460)
    }
}

@MainActor private enum RestoreArchiveExport {
    static func save(batch: ServerRestoreBatch, store: AppStore) async throws {
        let data = try await store.exportRestoreArchive(batch)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Audilse-restore-\(batch.id.uuidString.lowercased()).json"
        guard await panel.begin() == .OK, let url = panel.url else { return }
        try await Task.detached(priority: .utility) {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
    }
}
