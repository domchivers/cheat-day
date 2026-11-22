import SwiftUI

/// What went wrong finishing or saving an edit, said (22 Nov audit: a video that couldn't be made said nothing).
enum EditorTrouble { case video, draft }

struct EditorTroubleAlert: ViewModifier {
    @Binding var trouble: EditorTrouble?
    let retry: () -> Void

    func body(content: Content) -> some View {
        let showing = Binding<Bool>(get: { trouble != nil }, set: { (on: Bool) in if !on { trouble = nil } })
        return content.alert(title, isPresented: showing, presenting: trouble) { (t: EditorTrouble) in
            if t == .video { Button("Try again") { retry() } }
            Button("Keep editing", role: .cancel) {}
        } message: { (t: EditorTrouble) in
            Text(t == .video ? "Your edit is still here. Check your storage, then try again."
                             : "The phone may be full. Free some space, then try again: your edit is still open here.")
        }
    }

    private var title: String { trouble == .draft ? "Couldn't save your edit" : "Couldn't make the video" }
}
