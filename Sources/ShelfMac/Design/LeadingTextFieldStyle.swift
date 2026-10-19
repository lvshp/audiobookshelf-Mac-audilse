import SwiftUI

/// Preserve the shared call-site name while using the native input style directly.
/// Keep the input event path free of native-view alignment probes.
extension TextFieldStyle where Self == RoundedBorderTextFieldStyle {
    static var shelfLeading: RoundedBorderTextFieldStyle { .init() }
}

/// Explicit native label/value layout prevents grouped forms from styling the
/// editable value as an automatically aligned trailing label.
struct FormInputRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
