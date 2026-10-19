import SwiftUI
import ShelfCore

struct ServerPlaybackSessionsView: View {
    let store: AppStore
    let model: ServerPlaybackSessionsModel
    var embedded = false
    private struct HistoryKey: Hashable { let source: ServerPlaybackSessionsSource?; let query: ServerPlaybackSessionsQuery }
    private var source: ServerPlaybackSessionsSource? { .init(store: store) }

    var body: some View {
        Group {
            if embedded { content }
            else { ScrollView { content.padding(20) } }
        }
        .task(id: HistoryKey(source: source, query: model.query)) {
            let expected = source, requested = model.query
            guard !Task.isCancelled, ServerPlaybackSessionsSource(store: store) == expected else { return }
            guard let expected else { model.cancel(); return }
            await model.loadHistory(store: store, source: expected, query: requested)
        }
        .task(id: source) { if let source, model.targetUserID == nil { await model.loadUsers(store: store, source: source) } }
        .task(id: OpenKey(source: source, kind: .open)) { if let source, model.targetUserID == nil { await model.loadSnapshot(store: store, source: source, kind: .open) } }
        .task(id: OpenKey(source: source, kind: .share)) { if let source, model.targetUserID == nil { await model.loadSnapshot(store: store, source: source, kind: .share) } }
        .onDisappear { model.cancel() }
    }
    private struct OpenKey: Hashable { let source: ServerPlaybackSessionsSource?; let kind: AdminPlaybackSessionKind }
    @ViewBuilder private var content: some View {
        if source == nil || !model.isBound(to: store) {
            if source == nil { ContentUnavailableView(L10n.tr("连接服务器后管理收听会话"), systemImage: "headphones", description: Text(L10n.tr("账户或权限已变化，请关闭后重新打开。"))) }
            else { ProgressView(L10n.tr("载入收听会话…")).frame(maxWidth: .infinity).padding(32) }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if let error = model.actionError { errorText(error) }
                if model.isPreparingPlayback { ProgressView(L10n.tr("正在检查可播放内容…")).controlSize(.small) }
                if model.isMutating { ProgressView(L10n.tr("正在处理会话操作…")).controlSize(.small) }
                confirmation
                if let detail = model.detail {
                    ServerPlaybackSessionDetailView(session: detail.session, kind: detail.kind,
                        canDelete: model.canDelete(detail.session, kind: detail.kind), canClose: model.canClose(detail.session, kind: detail.kind),
                        administratorCloseSupported: model.source.map { AdminPlaybackSessionPolicy.supportsAdministratorClose(serverVersion: $0.version) } == true,
                        busy: model.isMutating || model.isPreparingPlayback,
                        back: { model.detail = nil; model.cancelConfirmation() },
                        play: { Task { await model.preparePlayback(detail.session, kind: detail.kind, store: store) } },
                        delete: { model.prepareDeletion(detail.session) }, close: { model.prepareClosure(detail.session) })
                } else {
                    historyPanel
                    if model.targetUserID == nil {
                        snapshotPanel(kind: .open)
                        snapshotPanel(kind: .share)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var historyPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                header("收听历史", loading: model.historyLoading) { reloadHistory() }
                controls
                if model.targetUserID == nil, let error = model.usersError {
                    HStack { errorText(error); Spacer(); Button(L10n.tr("重试用户列表")) { if let source { Task { await model.loadUsers(store: store, source: source) } } }.disabled(model.usersLoading) }
                }
                if let error = model.historyError { errorText(error) }
                if model.historyRows.isEmpty, !model.historyLoading, model.historyError == nil { Text(L10n.tr("尚无收听记录。")).foregroundStyle(.secondary).padding(.vertical, 14) }
                HStack {
                    Toggle(L10n.tr("选择本页"), isOn: Binding(get: {
                        let selectable = selectableRows; return !selectable.isEmpty && Set(selectable.map(\.id)).isSubset(of: model.selectedIDs)
                    }, set: { selected in model.selectedIDs = selected ? Set(selectableRows.map(\.id)) : [] }))
                        .toggleStyle(.checkbox).disabled(selectableRows.isEmpty || model.isMutating)
                    Spacer()
                    Text(L10n.format("已选择 %1$@ 条", String(model.selectedRows.count))).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("删除所选记录"), role: .destructive) { model.prepareBatchDeletion() }.disabled(!model.canBatchDelete)
                }
                if model.source?.actor.permissions.delete == false {
                    Text(L10n.tr("单条删除需要删除权限；管理员仍可批量删除本页选择的历史。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 0) {
                    ForEach(model.historyRows) { session in
                        sessionRow(session, kind: .history)
                        Divider()
                    }
                }
                HStack {
                    Text(L10n.format("共 %1$@ 条记录", String(model.history?.total ?? 0))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("上一页")) { changeQuery { $0.page -= 1 } }.disabled(model.query.page == 0 || model.historyLoading || model.isMutating)
                    Text(L10n.format("第 %1$@ / %2$@ 页", String(model.query.page + 1), String(max(1, model.history?.numPages ?? 1)))).font(.caption).monospacedDigit()
                    Button(L10n.tr("下一页")) { changeQuery { $0.page += 1 } }.disabled(model.query.page + 1 >= (model.history?.numPages ?? 0) || model.historyLoading || model.isMutating)
                }
            }.padding(10)
        }
    }
    private var selectableRows: [AdminPlaybackSession] { model.historyRows.filter { $0.mediaPlayer != "web-share" && AdminPlaybackSessionPolicy.isValidIdentifier($0.id) } }
    private var controls: some View {
        HStack(spacing: 12) {
            if model.targetUserID == nil {
                Picker(L10n.tr("用户"), selection: Binding(get: { model.query.userID ?? "" }, set: { value in changeQuery { $0.userID = value.isEmpty ? nil : value; $0.page = 0 } })) {
                    Text(L10n.tr("全部用户")).tag("")
                    ForEach(model.users.filter { AdminPlaybackSessionPolicy.isValidIdentifier($0.id) }) { Text($0.username).tag($0.id) }
                    if let selected = model.query.userID, !model.users.contains(where: { $0.id == selected }) { Text(selected).tag(selected) }
                }.pickerStyle(.menu).frame(maxWidth: 240).disabled(model.usersLoading || model.isMutating)
                Picker(L10n.tr("排序"), selection: Binding(get: { model.query.sort }, set: { value in changeQuery { $0.sort = value } })) {
                    ForEach(AdminPlaybackSessionSort.allCases, id: \.self) { Text(playbackSessionSortTitle($0)).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: 230).disabled(model.isMutating)
                Button { changeQuery { $0.descending.toggle() } } label: { Image(systemName: model.query.descending ? "arrow.down" : "arrow.up") }
                    .help(model.query.descending ? L10n.tr("降序") : L10n.tr("升序")).accessibilityLabel(model.query.descending ? L10n.tr("降序") : L10n.tr("升序")).disabled(model.isMutating)
            }
            Spacer(minLength: 0)
            Picker(L10n.tr("每页"), selection: Binding(get: { model.query.limit }, set: { value in changeQuery { $0.limit = value; $0.page = 0 } })) {
                ForEach([10, 25, 50, 100], id: \.self) { Text(String($0)).tag($0) }
            }.pickerStyle(.menu).frame(width: 125).disabled(model.isMutating)
        }
    }
    private func snapshotPanel(kind: AdminPlaybackSessionKind) -> some View {
        let rows = kind == .open ? model.openSessions : model.shareSessions
        let loading = kind == .open ? model.openLoading : model.shareLoading
        let error = kind == .open ? model.openError : model.shareError
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                header(kind == .open ? "活动会话（全部用户）" : "分享会话", loading: loading) {
                    if let source { Task { await model.loadSnapshot(store: store, source: source, kind: kind) } }
                }
                if let error { errorText(error) }
                if rows.isEmpty, !loading, error == nil { Text(L10n.tr("暂无会话")).foregroundStyle(.secondary) }
                LazyVStack(spacing: 0) {
                    ForEach(rows) { session in sessionRow(session, kind: kind); Divider() }
                }
            }.padding(10)
        }
    }
    private func sessionRow(_ session: AdminPlaybackSession, kind: AdminPlaybackSessionKind) -> some View {
        HStack(spacing: 12) {
            if kind == .history {
                Toggle(L10n.tr("选择记录"), isOn: Binding(get: { model.selectedIDs.contains(session.id) }, set: { if $0 { model.selectedIDs.insert(session.id) } else { model.selectedIDs.remove(session.id) } }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(!selectableRows.contains(where: { $0.id == session.id }) || model.isMutating)
            }
            Button { model.detail = .init(session: session, kind: kind); model.cancelConfirmation() } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.displayTitle ?? L10n.tr("已删除的内容")).font(.headline).lineLimit(2)
                    HStack(spacing: 10) {
                        if kind != .share { Text(session.user?.username ?? session.userId ?? "—") }
                        Text(playbackSessionMethod(session.playMethod))
                        Text(L10n.format("位置 %1$@", playbackSessionTime(session.currentTime)))
                    }.font(.caption).foregroundStyle(.secondary)
                    Text(L10n.format("已收听 %1$@ · 更新 %2$@", playbackSessionTime(session.timeListening), playbackSessionDate(session.updatedAt))).font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.isMutating)
            Button(L10n.tr("详情")) { model.detail = .init(session: session, kind: kind); model.cancelConfirmation() }.disabled(model.isMutating)
            if kind == .open, session.mediaPlayer != "web-share" {
                Button(L10n.tr("关闭活动会话"), role: .destructive) { model.prepareClosure(session) }
                    .disabled(!model.canClose(session, kind: kind) || model.isPreparingPlayback)
            }
        }.padding(.vertical, 12)
    }
    @ViewBuilder private var confirmation: some View {
        if let request = model.confirmation {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.action == .close ? L10n.tr("关闭活动会话") : L10n.tr("删除收听记录")).font(.headline)
                    Text(request.action == .close ? L10n.tr("将停止此会话并保留累计收听历史。关闭其他设备的会话时，此 Mac 不会停止播放。") : L10n.format("将永久删除已确认选择的 %1$@ 条收听记录；同标识的活动会话也会关闭。", String(request.rows.count)))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Spacer(); Button(L10n.tr("取消")) { model.cancelConfirmation() }; Button(L10n.tr("确认"), role: .destructive) { Task { await model.confirm(request, store: store) } } }.disabled(model.isMutating)
                }.padding(10)
            }
        }
        if let request = model.playbackConfirmation {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.tr("从历史位置播放")).font(.headline)
                    Text(L10n.format("在此 Mac 从 %1$@ 播放「%2$@」。这会更新当前账户的播放进度；查看其他用户的记录不会修改其进度。", playbackSessionTime(request.position), request.title)).font(.callout).foregroundStyle(.secondary)
                    HStack { Spacer(); Button(L10n.tr("取消")) { model.cancelConfirmation() }; Button(L10n.tr("播放")) { Task { await model.confirmPlayback(request, store: store) } } }.disabled(model.isMutating)
                }.padding(10)
            }
        }
    }
    private func header(_ title: String, loading: Bool, retry: @escaping () -> Void) -> some View {
        HStack { Text(L10n.tr(title)).font(.title3.bold()); Spacer(); if loading { ProgressView().controlSize(.small) }; Button(action: retry) { Image(systemName: "arrow.clockwise") }.help(L10n.tr("重新载入")).accessibilityLabel(L10n.tr("重新载入")).disabled(loading || model.isMutating) }
    }
    private func errorText(_ error: String) -> some View { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
    private func changeQuery(_ update: (inout ServerPlaybackSessionsQuery) -> Void) { update(&model.query); model.queryChanged() }
    private func reloadHistory() { if let source { Task { await model.loadHistory(store: store, source: source, query: model.query, force: true) } } }
}

func playbackSessionSortTitle(_ value: AdminPlaybackSessionSort) -> String {
    switch value {
    case .displayTitle: L10n.tr("标题")
    case .duration: L10n.tr("总时长")
    case .playMethod: L10n.tr("播放方式")
    case .startTime: L10n.tr("起始位置")
    case .currentTime: L10n.tr("当前位置")
    case .timeListening: L10n.tr("收听时长")
    case .updatedAt: L10n.tr("更新时间")
    case .createdAt: L10n.tr("创建时间")
    }
}
