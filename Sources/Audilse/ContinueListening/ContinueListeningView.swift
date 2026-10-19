import SwiftUI
import AudilseCore

struct ContinueListeningView: View {
    @State private var model: ContinueListeningModel
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, libraryID: String, onChange: @escaping @MainActor (ContinueListeningChange) -> Void = { _ in }) {
        _model = State(initialValue: .init(store: store, libraryID: libraryID, onChange: onChange))
    }
    var body: some View {
        let renderedSource = model.scope.identity
        let entryIsCurrent = model.scope.entrySource.isCurrent(model.scope.store)
        VStack(spacing: 0) {
            LibraryPersonalHeader(title: L10n.tr("续听管理"), scope: model.scope) { model.scope.cancel(); dismiss() }
            LibraryPersonalStatus(scope: model.scope)
            if !entryIsCurrent || !model.scope.available {
                Spacer()
                if entryIsCurrent { ProgressView() }
                Spacer()
            } else {
                List {
                    Section(L10n.tr("已隐藏的系列")) {
                        if model.isLoaded && model.hiddenSeries.isEmpty { Text(L10n.tr("当前书库没有已隐藏的系列。")).foregroundStyle(.secondary) }
                        ForEach(model.hiddenSeries) { series in
                            HStack { Text(series.name); Spacer(); Button(L10n.tr("恢复…")) { model.restore(series) } }
                        }
                    }
                    Section {
                        Text(L10n.tr("隐藏只影响当前账户的续听推荐，保留内容和进度。单个条目再次收听并推进播放位置后会重新显示。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(model.scope.isWorking)
            }
            HStack { Button(L10n.tr("刷新")) { Task { await model.load(expectedSource: renderedSource) } }.disabled(model.scope.isWorking || !entryIsCurrent); Spacer() }.padding(16)
        }.frame(width: 600, height: 480)
        .task(id: renderedSource) { await model.load(expectedSource: renderedSource) }
        .onDisappear { model.scope.cancel() }
        .libraryPersonalConfirmation(scope: model.scope)
    }
}

struct LibraryPersonalHeader: View {
    let title: String
    let scope: LibraryPersonalScope
    let close: () -> Void
    var body: some View {
        HStack { Text(title).font(.title2.bold()); Spacer(); if scope.isWorking { ProgressView().controlSize(.small) }; SheetCloseButton(label: L10n.tr("关闭"), action: close) }.padding(20)
    }
}
struct LibraryPersonalStatus: View {
    let scope: LibraryPersonalScope
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !scope.entrySource.isCurrent(scope.store) {
                Text(L10n.tr("账户或权限已变化，请关闭后重新打开。")).foregroundStyle(.secondary)
            } else if scope.available {
                if let error = scope.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                if let notice = scope.notice { Text(notice).foregroundStyle(.secondary) }
            }
        }.font(.callout).padding(.horizontal, 20).padding(.bottom, 8)
    }
}
private struct LibraryPersonalConfirmationModifier: ViewModifier {
    let scope: LibraryPersonalScope
    func body(content: Content) -> some View {
        content.alert(scope.confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { scope.confirmation != nil }, set: { if !$0 { scope.confirmation = nil } })) {
            if let confirmation = scope.confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) { scope.confirmation = nil; Task { await confirmation.action() } }
                Button(L10n.tr("取消"), role: .cancel) { scope.confirmation = nil }
            }
        } message: { Text(scope.confirmation?.message ?? "") }
    }
}
extension View { func libraryPersonalConfirmation(scope: LibraryPersonalScope) -> some View { modifier(LibraryPersonalConfirmationModifier(scope: scope)) } }
