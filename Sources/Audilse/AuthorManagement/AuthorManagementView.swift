import SwiftUI
import AppKit
import AudilseCore

struct AuthorManagementView: View {
    @State private var model: AuthorManagementModel
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, authorID: String, libraryID: String, onChange: @escaping @MainActor (AuthorManagementChange) -> Void = { _ in }) {
        _model = State(initialValue: .init(store: store, authorID: authorID, libraryID: libraryID, onChange: onChange))
    }
    var body: some View {
        let renderedSource = model.scope.identity
        let entryIsCurrent = model.scope.entrySource.isCurrent(model.scope.store)
        VStack(spacing: 0) {
            LibraryPersonalHeader(title: L10n.tr("作者管理"), scope: model.scope) { model.scope.cancel(); dismiss() }
            LibraryPersonalStatus(scope: model.scope)
            if !entryIsCurrent || !model.scope.available {
                Spacer()
                if entryIsCurrent { ProgressView() }
                Spacer()
            }
            else {
                // Keep editable control identities stable while the confirmation
                // dismisses and focus returns to this sheet after deletion.
                if model.isDeleted {
                    Label(L10n.tr("作者已删除"), systemImage: "person.crop.circle.badge.xmark")
                        .font(.headline).padding(.horizontal, 20).padding(.bottom, 8)
                }
                Form {
                    Section(L10n.tr("作者资料")) {
                        FormInputRow(L10n.tr("名称")) { TextField("", text: $model.name).disabled(!model.canUpdate || !model.canRename).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("名称")) }
                        if !model.canRename { Text(L10n.tr("此服务端版本的作者改名可能跨书库合并。请升级到 2.36.1 或更新版本后改名。")).font(.caption).foregroundStyle(.secondary) }
                        FormInputRow("ASIN") { TextField("", text: $model.asin).disabled(!model.canUpdate).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel("ASIN") }
                        LabeledContent(L10n.tr("简介")) { LeadingTextEditor(text: $model.description).frame(minHeight: 120).disabled(!model.canUpdate) }
                        HStack { Button(L10n.tr("保存…")) { model.save() }.disabled(!model.canUpdate || !model.hasChanges || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); Spacer(); Button(L10n.tr("快速匹配…")) { model.match() }.disabled(!model.canUpdate || model.author == nil) }
                        Text(L10n.tr("快速匹配按书库的 Audible 地区更新作者；不会改名。")) .font(.caption).foregroundStyle(.secondary)
                    }
                    Section(L10n.tr("作者头像")) {
                        HStack(alignment: .top, spacing: 16) {
                            if let data = model.imageData, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 120) }
                            else if model.isLoadingImage { ProgressView().frame(width: 100, height: 120) }
                            else { Image(systemName: "person.crop.rectangle").font(.system(size: 52)).foregroundStyle(.secondary).frame(width: 100, height: 120) }
                            VStack(alignment: .leading, spacing: 8) {
                                if let error = model.imageError { Text(error).foregroundStyle(.red); Button(L10n.tr("重试头像")) { Task { await model.retryImage() } } }
                                FormInputRow(L10n.tr("图片网页地址")) { TextField("", text: $model.imageURL).disabled(!model.canUploadImage).labelsHidden().multilineTextAlignment(.leading).accessibilityLabel(L10n.tr("图片网页地址")) }
                                HStack { Button(L10n.tr("更换头像…")) { model.uploadImage() }.disabled(!model.canUploadImage || !model.validImageURL || model.author == nil); Button(L10n.tr("删除头像…"), role: .destructive) { model.deleteImage() }.disabled(!model.canDelete || model.author?.imagePath == nil) }
                            }
                        }
                    }
                    Section { Button(L10n.tr("删除作者…"), role: .destructive) { model.deleteAuthor() }.disabled(!model.canDelete || model.author == nil) }
                }.formStyle(.grouped).disabled(model.scope.isWorking || !model.scope.available || model.isDeleted)
            }
            HStack { Button(L10n.tr("刷新")) { Task { await model.load(expectedSource: renderedSource) } }.disabled(model.scope.isWorking || !entryIsCurrent || model.isDeleted); Spacer() }.padding(16)
        }.frame(width: 700, height: 700).textFieldStyle(.shelfLeading)
        .task(id: renderedSource) { await model.load(expectedSource: renderedSource) }
        .onDisappear { model.scope.cancel() }
        .libraryPersonalConfirmation(scope: model.scope)
    }
}
