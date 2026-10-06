import SwiftUI

extension View {
    /// An alert with a text field to rename something: `name` is what it is now while the alert is
    /// up, and `commit` gets the new one.
    func renameAlert(_ title: String, name: Binding<String?>, commit: @escaping (String) -> Void) -> some View {
        modifier(RenameAlert(title: title, name: name, commit: commit))
    }
}

private struct RenameAlert: ViewModifier {
    let title: String
    @Binding var name: String?
    let commit: (String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { name != nil }, set: { if !$0 { name = nil } })) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { commit(text) }
            }
            .onChange(of: name) { _, now in if let now { text = now } }
    }
}
