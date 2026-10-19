import SwiftUI
import AudilseCore

struct NarratorDirectoryView: View {
    @State private var model: NarratorDirectoryModel
    private let onNavigate: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, library: Library,
         onChange: @escaping @MainActor (NarratorDirectoryChange) -> Void = { _ in },
         onNavigate: @escaping @MainActor () -> Void = {}) {
        _model = State(initialValue: .init(store: store, library: library, onChange: onChange)); self.onNavigate = onNavigate
    }
    var body: some View {
        let renderedSource = model.identity
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.wave.2").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("朗读者")).font(.title2.bold())
                    Text(model.library.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.isLoading || model.scope.isWorking { ProgressView().controlSize(.small) }
                Button { Task { await model.load(expected: renderedSource) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.tr("刷新朗读者")).accessibilityLabel(L10n.tr("刷新朗读者"))
                    .disabled(!model.entryIsCurrent || model.isLoading || model.scope.isWorking || renderedSource?.personal.offline == true)
                SheetCloseButton(identifier: "narrators.close") { model.cancel(); dismiss() }
            }.padding(20)
            Divider()
            if !model.entryIsCurrent {
                ContentUnavailableView(L10n.tr("朗读者目录暂不可用"), systemImage: "person.wave.2",
                                       description: Text(L10n.tr("账户、书库或权限已变化，请关闭后重新打开。")))
            } else {
                status
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.tr("搜索朗读者"), text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel(L10n.tr("清除搜索")) }
                }.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 20).padding(.bottom, 12)
                if let narrator = model.editing { rename(narrator).padding(.horizontal, 20).padding(.bottom, 12) }
                directory(renderedSource)
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("书数来自整个书库的元数据，可能包含当前账户无权浏览的图书。"))
                    if renderedSource?.personal.offline == true || model.isCached { Text(L10n.tr("正在显示本机缓存，离线时仅可浏览。")) }
                    else if !LibraryNarratorPolicy.allowsMutation(serverVersion: renderedSource?.personal.serverVersion) {
                        Text(L10n.tr("此服务端版本的朗读者修改可能影响其他书库。请升级到 2.36.1 或更新版本后修改。"))
                    }
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }.frame(minWidth: 660, idealWidth: 780, minHeight: 560, idealHeight: 680)
        .textFieldStyle(.shelfLeading)
        .task(id: renderedSource) { await model.load(expected: renderedSource) }
        .onChange(of: renderedSource) { _, value in if value != model.entrySource { model.cancel() } }
        .onDisappear { model.cancel() }
        .libraryPersonalConfirmation(scope: model.scope)
    }
    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.scope.notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if let error = model.scope.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let error = model.error {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.confirmedChange != nil { Text(L10n.tr("修改已确认，目录刷新失败。")) }
                        Text(error)
                    }
                    Spacer()
                    Button(L10n.tr("重试刷新")) { Task { await model.load(expected: model.identity) } }.disabled(model.isLoading || model.scope.isWorking)
                }.foregroundStyle(.orange)
            }
            if let error = model.cacheError { Text(L10n.tr("修改已确认，本机缓存清理失败。请关闭并重新打开此页面重试。") + " " + error).foregroundStyle(.orange) }
        }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
    }
    @ViewBuilder private func directory(_ renderedSource: NarratorDirectorySource?) -> some View {
        if model.narrators == nil {
            if model.isLoading { ProgressView(L10n.tr("正在加载朗读者…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if renderedSource?.personal.offline == true { ContentUnavailableView(L10n.tr("尚无朗读者缓存"), systemImage: "wifi.slash", description: Text(L10n.tr("在线打开此目录后可在本机浏览缓存。"))) }
            else { ContentUnavailableView(L10n.tr("尚未加载朗读者"), systemImage: "person.wave.2") }
        } else if model.visibleNarrators.isEmpty {
            ContentUnavailableView(model.search.isEmpty ? L10n.tr("此书库暂无朗读者") : L10n.tr("没有匹配的朗读者"), systemImage: "person.wave.2")
        } else {
            List(model.visibleNarrators) { narrator in
                HStack(spacing: 12) {
                    Button {
                        if model.browse(narrator, renderedSource: renderedSource) { model.cancel(); onNavigate(); dismiss() }
                    } label: {
                        HStack { Text(narrator.name).lineLimit(2).multilineTextAlignment(.leading); Spacer(); Text(L10n.format("%1$@ 本图书", narrator.numBooks.formatted(.number.locale(AppLanguageStore.shared.selection.locale)))).font(.callout).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.scope.isWorking || model.isLoading)
                        .accessibilityIdentifier("narrator.browse.\(narrator.id)")
                    if model.canMutate {
                        Menu {
                            Button(L10n.tr("改名…")) { model.beginRename(narrator) }
                            Button(L10n.tr("移除关联…"), role: .destructive) { model.requestRemove(narrator) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel(L10n.format("管理朗读者 %1$@", narrator.name))
                            .accessibilityIdentifier("narrator.manage.\(narrator.id)")
                    }
                }.padding(.vertical, 6).accessibilityElement(children: .contain)
            }.listStyle(.inset)
        }
    }
    private func rename(_ narrator: LibraryNarrator) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("改名朗读者")).font(.title2.bold())
            Text(narrator.name).foregroundStyle(.secondary).textSelection(.enabled)
            TextField(L10n.tr("新名称"), text: $model.draftName).textFieldStyle(.shelfLeading)
                .onSubmit { if validRename(narrator) { model.requestRename() } }
            Text(L10n.tr("此操作影响整个书库；改为已有名称会合并关联。")) .font(.caption).foregroundStyle(.secondary)
            HStack { Button(L10n.tr("取消")) { model.editing = nil }.keyboardShortcut(.cancelAction); Spacer(); Button(L10n.tr("继续…")) { model.requestRename() }.buttonStyle(.borderedProminent).disabled(!validRename(narrator)) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
    private func validRename(_ narrator: LibraryNarrator) -> Bool {
        let name = model.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.canMutate && model.narrators?.contains(narrator) == true && !name.isEmpty && name != narrator.name
    }
}
