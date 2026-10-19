import SwiftUI
import ShelfCore

private struct HomeRequest: Hashable { let source: HomeSource; let personal: LibraryPersonalSource; let retry: UUID }
private struct HomeContinueTarget: Identifiable {
    let id = UUID()
    let source: LibraryPersonalSource
}

struct HomeView: View {
    @Bindable var store: AppStore
    let library: Library
    @State private var model = HomeModel()
    @State private var actions = HomeActions()
    @State private var retry = UUID()
    @State private var continuation: ContinueListeningModel?
    @State private var continuationTarget: HomeContinueTarget?
    private var source: HomeSource { .init(store: store, libraryID: library.id) }
    private var visibleShelves: [PersonalizedLibraryShelf] {
        model.shelves.map { $0.applyingContinuationVisibility(user: store.user, progressByID: store.progressByItem) }
    }

    var body: some View {
        let identity = source
        let personal = LibraryPersonalSource(store: store, libraryID: library.id)
        let bound = model.isBound(to: store, libraryID: library.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if bound, let error = model.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        Spacer(); Button(L10n.tr("重试")) { retry = UUID() }.disabled(model.isLoading)
                    }
                }
                if bound, let warning = model.cacheError { Text(warning).font(.caption).foregroundStyle(.secondary) }
                if continuation?.scope.available == true, let error = continuation?.scope.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                if bound && model.usesCache {
                    Label(L10n.tr("正在显示已缓存的首页；书架顺序可能尚未包含最近的变化。"), systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !bound || model.isLoading && model.shelves.isEmpty {
                    VStack(spacing: 12) { ProgressView(); Text(L10n.tr("正在整理你的首页…")).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.vertical, 80)
                } else if model.shelves.isEmpty && model.error == nil {
                    QuietEmptyState(symbol: "rectangle.stack", title: L10n.tr("还没有为你整理的书架"),
                                    message: L10n.tr("开始收听、阅读或向书库添加内容后，服务器会在这里提供推荐。"))
                } else {
                    // Ten standard shelves remain in server order. Each row only
                    // creates its visible page; there is no unbounded lazy stack.
                    ForEach(Array(visibleShelves.enumerated()), id: \.offset) { offset, shelf in
                        HomeShelfView(store: store, library: library, shelf: shelf, model: model,
                                      actions: actions, source: identity, continuation: continuation)
                            .id(shelf.id + ":" + String(offset))
                    }
                }
            }.padding(.horizontal, 30).padding(.vertical, 28)
        }.scrollContentBackground(.hidden)
        .accessibilityIdentifier("home.content")
        .task(id: HomeRequest(source: identity, personal: personal, retry: retry)) {
            guard !Task.isCancelled, identity.isCurrent(store), personal == LibraryPersonalSource(store: store, libraryID: library.id) else { return }
            actions.bind(identity)
            continuation?.scope.cancel()
            let continuationModel = ContinueListeningModel(store: store, libraryID: library.id, onChange: continuationChanged)
            continuationModel.scope.bind()
            continuation = continuationModel
            await model.load(store: store, library: library)
        }
        .onChange(of: identity) { _, new in
            actions.bind(new)
            if continuation?.scope.source?.isCurrent(store) != true { continuation?.scope.cancel() }
            if continuationTarget?.source.isCurrent(store) != true { continuationTarget = nil }
        }
        .onChange(of: personal) { _, _ in
            if continuation?.scope.source?.isCurrent(store) != true { continuation?.scope.cancel() }
            if continuationTarget?.source.isCurrent(store) != true { continuationTarget = nil }
        }
        .onChange(of: store.readingActivityID) { old, new in
            if old != nil, new == nil, identity.isCurrent(store) { retry = UUID() }
        }
        .onDisappear { model.cancel(); actions.cancel(); continuation?.scope.cancel() }
        .sheet(item: $continuationTarget) { target in
            if target.source.isCurrent(store) {
                ContinueListeningView(store: store, libraryID: library.id, onChange: continuationChanged)
            }
        }
        .sheet(item: $actions.destination) { destination in
            switch destination.content {
            case .reader(let item): ReaderView(store: store, item: item)
            case .group(let kind, let group): FeatureGroupDetailView(store: store, kind: kind, initial: group)
            }
        }
        .alert(L10n.tr("暂时无法完成"), isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
            Button(L10n.tr("知道了"), role: .cancel) { actions.error = nil }
        } message: { Text(actions.error ?? "") }
        .alert(continuation?.scope.confirmation?.title ?? L10n.tr("确认操作"), isPresented: Binding(get: { continuation?.scope.confirmation != nil }, set: { if !$0 { continuation?.scope.confirmation = nil } })) {
            if let confirmation = continuation?.scope.confirmation {
                Button(L10n.tr("确认"), role: confirmation.destructive ? .destructive : nil) {
                    continuation?.scope.confirmation = nil
                    Task { await confirmation.action() }
                }
                Button(L10n.tr("取消"), role: .cancel) { continuation?.scope.confirmation = nil }
            }
        } message: { Text(continuation?.scope.confirmation?.message ?? "") }
    }
    private func continuationChanged(_ change: ContinueListeningChange) {
        guard change.isCurrent(store) else { return }
        store.applyContinuationChange(change)
        retry = UUID()
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("为你整理的书架")).font(.system(size: 29, weight: .bold, design: .rounded))
                Text(L10n.tr("从上次停下的地方，继续下一段故事。")).font(.callout).foregroundStyle(.secondary)
                if model.isBound(to: store, libraryID: library.id), let date = model.updatedAt {
                    HStack(spacing: 4) {
                        Text(L10n.tr("首页更新于")); Text(date, style: .date); Text(date, style: .time)
                    }.font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                Picker(L10n.tr("书库"), selection: Binding(get: { library.id }, set: { store.browsingLibraryID = $0 })) {
                    ForEach(store.libraries) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu).frame(maxWidth: 230).accessibilityIdentifier("home.library")
                if model.isLoading || actions.isWorking { ProgressView().controlSize(.small) }
                Button(L10n.tr("浏览完整书库"), systemImage: "books.vertical") { store.route = .library(library.id) }
                    .buttonStyle(.borderless).font(.caption).accessibilityIdentifier("home.browse-library")
                Button(L10n.tr("续听管理…"), systemImage: "eye.slash") {
                    let captured = LibraryPersonalSource(store: store, libraryID: library.id)
                    guard captured.isCurrent(store) else { return }
                    continuationTarget = .init(source: captured)
                }.buttonStyle(.borderless).font(.caption)
                    .disabled(!LibraryPersonalSource(store: store, libraryID: library.id).isCurrent(store))
                    .accessibilityIdentifier("home.continuation-management")
            }
        }
    }
}
