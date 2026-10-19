import SwiftUI
import AudilseCore

struct ServerTasksView: View {
    let store: AppStore
    @State private var model = ServerTasksModel()
    @State private var filter: Filter = .all
    @State private var page = 0
    @State private var cancellation: ServerScanCancellation?
    @State private var trackTarget: TrackTarget?
    private let pageSize = 40
    private enum Filter: String, CaseIterable { case all = "全部", running = "运行中", queued = "排队中", completed = "已完成", failed = "失败" }
    private struct TrackTarget: Identifiable { let id: String; let source: ServerTasksSource }
    private enum Row: Identifiable {
        case task(ServerTask), queued(ServerQueuedEmbed)
        var id: String { switch self { case .task(let task): "task:" + task.id; case .queued(let item): "queue:" + item.id } }
    }
    private var rows: [Row] {
        let tasks = model.state.tasks.filter { task in
            switch filter {
            case .all: true
            case .running: !task.isFinished
            case .queued: false
            case .completed: task.isFinished && !task.isFailed
            case .failed: task.isFailed
            }
        }.map(Row.task)
        return tasks + ((filter == .all || filter == .queued) ? model.state.queuedEmbeds.map(Row.queued) : [])
    }
    var body: some View {
        let source = ServerTasksSource(store: store)
        VStack(alignment: .leading, spacing: 12) {
            if let source, model.isBound(to: store) {
                content(source: source)
            } else if store.isConnecting {
                ProgressView(L10n.tr("正在连接服务器"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if source != nil {
                ProgressView(L10n.tr("正在读取后台任务…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.tr("连接管理员账户后查看任务"), systemImage: "checklist",
                    description: Text(L10n.tr("后台任务需要在线的管理员或 root 账户。")))
            }
        }
        .task(id: source) { await model.start(store: store, source: source) }
        .onChange(of: source) { _, _ in page = 0; cancellation = nil; trackTarget = nil }
        .onChange(of: filter) { _, _ in page = 0 }
        .onDisappear { model.cancel(); cancellation = nil; trackTarget = nil }
        .alert(L10n.tr("取消扫描"), isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })) {
            if let target = cancellation {
                Button(L10n.tr("取消扫描")) { cancellation = nil; _ = model.requestCancellation(target, store: store) }
                Button(L10n.tr("继续扫描"), role: .cancel) { cancellation = nil }
            }
        } message: {
            if let target = cancellation { Text(L10n.format("请求停止“%1$@”的当前扫描。服务器完成处理后才会更新任务状态。", target.libraryName)) }
        }
        .sheet(item: $trackTarget) { target in
            ServerTaskTracksView(store: store, model: model, taskID: target.id, source: target.source)
        }
    }

    @ViewBuilder private func content(source: ServerTasksSource) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("后台任务")).font(.title3.bold())
                Label(connectionLabel, systemImage: model.connectionStatus == .connected ? "bolt.horizontal.circle" : "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button(L10n.tr("刷新"), systemImage: "arrow.clockwise") { Task { await model.refresh(store: store, source: source) } }.disabled(model.isRefreshing)
            if model.connectionStatus == .failed || model.connectionStatus == .disconnected {
                Button(L10n.tr("重新连接")) { Task { await model.start(store: store, source: source) } }
            }
        }
        if let error = model.snapshotError {
            HStack { Text(error).foregroundStyle(.red).textSelection(.enabled); Spacer(); Button(L10n.tr("重试")) { Task { await model.refresh(store: store, source: source) } }.disabled(model.isRefreshing) }
        }
        if let error = model.connectionError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        if let error = model.eventError { Text(error).font(.callout).foregroundStyle(.orange) }
        if let error = model.cancellationError { Text(error).font(.callout).foregroundStyle(.red) }
        HStack {
            Picker(L10n.tr("任务状态"), selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) }
            }.pickerStyle(.menu).fixedSize()
            Spacer()
            if let date = model.updatedAt { Text(date, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary) }
        }
        let all = rows, pages = max(1, (all.count + pageSize - 1) / pageSize)
        let current = min(page, pages - 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if all.isEmpty {
                    ContentUnavailableView(model.isRefreshing ? L10n.tr("正在读取后台任务…") : L10n.tr("此状态下暂无任务"), systemImage: "checklist")
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(Array(all.dropFirst(current * pageSize).prefix(pageSize))) { row in
                    switch row {
                    case .task(let task): taskCard(task, source: source)
                    case .queued(let item): queuedCard(item)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
        }
        HStack {
            Text(L10n.format("第 %1$@ / %2$@ 页 · %3$@ 项", String(current + 1), String(pages), String(all.count))).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.tr("上一页")) { page = max(0, current - 1) }.disabled(current == 0)
            Button(L10n.tr("下一页")) { page = min(pages - 1, current + 1) }.disabled(current + 1 >= pages)
        }
        Text(L10n.tr("保留当前账户会话最近 100 条结束记录；断线期间的结束事件无法补取，服务器不提供完整任务历史。"))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var connectionLabel: String {
        switch model.connectionStatus {
        case .connecting: L10n.tr("正在建立任务实时连接…")
        case .connected: L10n.tr("任务状态实时更新")
        case .disconnected: L10n.tr("实时连接已断开；可手动刷新任务。")
        case .failed: L10n.tr("实时连接不可用；任务快照仍可刷新。")
        }
    }
    private func queuedCard(_ item: ServerQueuedEmbed) -> some View {
        GroupBox {
            HStack(alignment: .top) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? item.libraryItemId).font(.headline).textSelection(.enabled)
                    Text(L10n.tr("元数据嵌入排队中")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
    private func taskCard(_ task: ServerTask, source: ServerTasksSource) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: task.isFailed ? "exclamationmark.circle" : task.isFinished ? "checkmark.circle" : "hourglass")
                        .foregroundStyle(task.isFailed ? .red : task.isFinished ? .green : .secondary)
                    Text(ServerTasksPresentation.title(task)).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(task.isFailed ? L10n.tr("失败") : task.isFinished ? L10n.tr("已完成") : L10n.tr("运行中"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                let description = ServerTasksPresentation.description(task), error = ServerTasksPresentation.error(task)
                if !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let summary = ServerTasksPresentation.scanSummary(task) { Text(summary).font(.caption).foregroundStyle(.secondary) }
                if let progress = model.state.progress(for: task) {
                    HStack { ProgressView(value: progress, total: 100); Text(progress / 100, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
                } else if !task.isFinished {
                    HStack { ProgressView().controlSize(.small); Text(L10n.tr("等待服务器更新任务状态")).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    if !model.state.tracks(for: task).isEmpty {
                        Button(L10n.tr("音轨进度")) { trackTarget = .init(id: task.id, source: source) }
                    }
                    Spacer()
                    if model.cancellationRequested.contains(task.id) {
                        Text(L10n.tr("取消请求已发送，等待服务器确认…")).font(.caption).foregroundStyle(.secondary)
                    } else if let target = model.cancellationTarget(taskID: task.id, source: source, store: store) {
                        Button(L10n.tr("取消扫描")) { cancellation = target }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}

private struct ServerTaskTracksView: View {
    let store: AppStore
    let model: ServerTasksModel
    let taskID: String
    let source: ServerTasksSource
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let tracks = source.isCurrent(store: store) && model.isBound(to: store) ? model.state.task(id: taskID).map { model.state.tracks(for: $0) } ?? [] : []
        let pages = max(1, (tracks.count + 39) / 40), current = min(page, pages - 1)
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.tr("音轨进度")).font(.title2.bold()); Spacer(); Button(L10n.tr("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tracks.isEmpty { Text(L10n.tr("该任务已结束，或尚未收到可区分的音轨进度。")).foregroundStyle(.secondary) }
                    ForEach(Array(tracks.dropFirst(current * 40).prefix(40))) { track in
                        HStack {
                            Text(L10n.format("音轨 %1$@", track.ino)).font(.caption.monospacedDigit())
                            Spacer()
                            if track.isFinished { Label(L10n.tr("已完成"), systemImage: "checkmark.circle") }
                            else if let percent = track.progress { ProgressView(value: percent, total: 100).frame(width: 220); Text(percent / 100, format: .percent.precision(.fractionLength(0))) }
                            else { ProgressView().controlSize(.small) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.tr("仅显示服务器已报告的音轨状态，不代表原件总数量。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack { Text(L10n.format("第 %1$@ / %2$@ 页", String(current + 1), String(pages))).font(.caption); Spacer(); Button(L10n.tr("上一页")) { page = max(0, current - 1) }.disabled(current == 0); Button(L10n.tr("下一页")) { page = min(pages - 1, current + 1) }.disabled(current + 1 >= pages) }
        }.padding(24).frame(width: 640, height: 500)
    }
}
