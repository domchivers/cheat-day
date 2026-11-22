import SwiftUI

/// Watches the edit for Undo (kept out of the editor's body: one more modifier there is too much for the compiler).
/// A change is recorded once nothing's changed for a moment and no finger or keyboard is still at it.
struct EditWatch<Edit: Equatable>: ViewModifier {
    let edit: Edit
    let began: () -> Void
    let changed: () -> Void
    let busy: () -> Bool
    let settled: () -> Void
    @State private var count = 0

    func body(content: Content) -> some View {
        content
            .onAppear { began() }
            .onChange(of: edit) { (_: Edit, _: Edit) in
                count += 1
                changed()
            }
            .task(id: count) {
                guard count > 0 else { return }
                try? await Task.sleep(for: .milliseconds(700))
                while !Task.isCancelled && busy() { try? await Task.sleep(for: .milliseconds(200)) }
                if !Task.isCancelled { settled() }
            }
    }
}
