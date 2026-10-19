import AppKit
import Observation
import ShelfCore
import SwiftUI

extension LibraryFileExportError: ClientLocalizedError {
    var clientErrorDescription: String {
        switch self {
        case .invalidFile: L10n.tr("无法保存此文件，请刷新文件列表后重试。")
        case .destinationChanged: L10n.tr("保存位置的文件已改变，请重新选择保存位置。")
        case .unsafeDestination: L10n.tr("请选择普通文件的保存位置。")
        case .http(let status): L10n.format("保存原件失败（HTTP %1$@）。", String(status))
        }
    }
}

/// Shared by detail and content-management file rows. Saving an original requires
/// download permission only; it does not depend on content-editing permission.
struct FileExportButton: View {
    let store: AppStore
    let itemID: String
    let file: MediaFile
    @State private var model = FileExportCoordinator()

    var body: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                if let fraction = model.progress.fraction { ProgressView(value: fraction).frame(width: 64) }
                else { ProgressView().controlSize(.small) }
                Text(ByteCountFormatter.string(fromByteCount: model.progress.bytesWritten, countStyle: .file)).font(.caption).monospacedDigit()
                Button { model.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .help(L10n.tr("取消保存")).accessibilityLabel(L10n.tr("取消保存"))
            } else {
                if model.saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L10n.tr("原件已保存")) }
                Button { model.choose(store: store, itemID: itemID, file: file) } label: { Image(systemName: "square.and.arrow.down") }
                    .help(L10n.tr("原件另存为…")).accessibilityLabel(L10n.tr("原件另存为…"))
                    .disabled(!model.canStart(store: store))
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("file.export.\(file.ino)")
        .onDisappear { model.cancel() }
        .onChange(of: store.partition) { _, _ in model.cancel() }
        .onChange(of: store.client.map(ObjectIdentifier.init)) { _, _ in model.cancel() }
        .onChange(of: store.canDownload) { _, allowed in if !allowed { model.cancel() } }
        .onChange(of: store.serverRecovery?.id) { _, recovery in if recovery != nil { model.cancel() } }
        .alert(L10n.tr("无法保存原件"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.tr("好"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@MainActor @Observable final class FileExportCoordinator {
    private(set) var isBusy = false
    private(set) var saved = false
    private(set) var progress = LibraryFileExportProgress(bytesWritten: 0, expectedBytes: nil)
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var panel: NSSavePanel?
    @ObservationIgnored private var operationID = UUID()

    func canStart(store: AppStore) -> Bool {
        !isBusy && store.canDownload && !store.isOffline && !store.isDemo && !store.isConnecting &&
        !store.recoveryBusy && store.serverRecovery == nil && store.partition != nil && store.client != nil
    }

    func choose(store: AppStore, itemID: String, file: MediaFile) {
        guard canStart(store: store), let partition = store.partition, let client = store.client else { return }
        isBusy = true; saved = false; error = nil
        progress = .init(bytesWritten: 0, expectedBytes: file.metadata.size)
        operationID = UUID(); let attempt = operationID
        let panel = NSSavePanel(); self.panel = panel
        // Server paths are not destinations. Offer only the last filename component.
        let filename = file.metadata.filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        panel.nameFieldStringValue = filename.isEmpty ? file.ino : filename
        panel.canCreateDirectories = true
        panel.title = L10n.tr("原件另存为…")
        panel.begin { [weak self, weak store] result in
            guard let self, self.operationID == attempt else { return }
            self.panel = nil
            guard result == .OK, let destination = panel.url else { self.isBusy = false; return }
            guard let store, Self.matches(store, partition: partition, client: client) else { self.isBusy = false; return }
            let scoped = destination.startAccessingSecurityScopedResource()
            self.task = Task { [weak self, weak store] in
                defer {
                    if scoped { destination.stopAccessingSecurityScopedResource() }
                    if self?.operationID == attempt { self?.isBusy = false; self?.task = nil }
                }
                do {
                    try Task.checkCancellation()
                    guard let store, Self.matches(store, partition: partition, client: client) else { throw ABSError.sessionChanged }
                    try await LibraryFileExporter().export(itemID: itemID, file: file, partition: partition, client: client, destination: destination) { [weak self] value in
                        await MainActor.run { if self?.operationID == attempt { self?.progress = value } }
                    } authorizeCommit: { [weak store] in
                        try await MainActor.run {
                            guard let store, Self.matches(store, partition: partition, client: client) else { throw ABSError.sessionChanged }
                        }
                    }
                    guard self?.operationID == attempt, Self.matches(store, partition: partition, client: client) else { return }
                    self?.saved = true
                } catch is CancellationError { }
                catch {
                    guard self?.operationID == attempt else { return }
                    if let urlError = error as? URLError, urlError.code == .cancelled { return }
                    self?.error = L10n.error(error)
                }
            }
        }
    }

    private static func matches(_ store: AppStore, partition: AccountPartition, client: ABSClient) -> Bool {
        store.partition == partition && store.client === client && store.canDownload &&
        !store.isOffline && !store.isDemo && !store.isConnecting && !store.recoveryBusy && store.serverRecovery == nil
    }

    func cancel() {
        operationID = UUID()
        panel?.cancel(nil); panel = nil
        task?.cancel(); task = nil
        isBusy = false; saved = false
    }
}
