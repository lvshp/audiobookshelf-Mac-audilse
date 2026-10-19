import SwiftUI
import AppKit

/// Native text editing with visual padding; no native-view probes or event wrappers.
struct LeadingTextEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .multilineTextAlignment(.leading)
            .environment(\.layoutDirection, .leftToRight)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
