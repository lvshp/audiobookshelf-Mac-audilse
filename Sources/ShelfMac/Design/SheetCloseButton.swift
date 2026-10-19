import SwiftUI

/// Shared modal close control with a visible keyboard focus ring.
struct SheetCloseButton: View {
    var label = L10n.tr("关闭")
    var identifier = "sheet.close"
    let action: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(isHovered ? 0.10 : 0.055), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.secondary.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .keyboardShortcut(.cancelAction)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(label + "（Esc）")
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
