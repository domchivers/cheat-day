import SwiftUI
import UIKit

/// A caption's words, typed where they are in Edit captions, with the cursor known (CapCut's, 21 Nov,
/// design/capcut-timeline-mockup.html): over the keyboard, Split at the cursor, Merge up, Merge down, its look and
/// Delete, then Done. Its own bar carries KeyboardDone's mark, so the app's plain Done bar doesn't replace it.
struct CaptionField: UIViewRepresentable {
    @Binding var text: String
    var active: Bool
    var canUp: Bool
    var canDown: Bool
    var focused: () -> Void
    var split: (Int) -> Void          // the cursor, in characters from the start
    var mergeUp: () -> Void
    var mergeDown: () -> Void
    var style: () -> Void
    var delete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.font = .systemFont(ofSize: 15)
        f.tintColor = .systemYellow
        f.returnKeyType = .done
        f.autocorrectionType = .no
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = f
        f.inputAccessoryView = context.coordinator.makeBar()
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        if f.text != text { f.text = text }
        // the caption picked or being said in white, the rest grey (as CapCut's list)
        f.textColor = active ? .white : UIColor(white: 0.55, alpha: 1)
        context.coordinator.refresh()
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CaptionField
        weak var field: UITextField?
        private var up: UIBarButtonItem?, down: UIBarButtonItem?

        init(_ parent: CaptionField) { self.parent = parent }

        @objc func changed(_ f: UITextField) { parent.text = f.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.focused() }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }

        /// Where the cursor is, in characters from the start.
        private var cursor: Int {
            guard let f = field, let r = f.selectedTextRange else { return 0 }
            return f.offset(from: f.beginningOfDocument, to: r.start)
        }

        func refresh() { up?.isEnabled = parent.canUp; down?.isEnabled = parent.canDown }

        func makeBar() -> UIToolbar {
            let t = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            t.tag = 0xD0E   // KeyboardDone's mark: this bar stays
            func item(_ title: String, _ run: @escaping () -> Void) -> UIBarButtonItem {
                let b = UIBarButtonItem(title: title, primaryAction: UIAction { _ in run() })
                b.tintColor = .white
                return b
            }
            let split = item("Split") { [weak self] in guard let self else { return }; self.parent.split(self.cursor) }
            let up = item("Merge ↑") { [weak self] in self?.parent.mergeUp() }
            let down = item("Merge ↓") { [weak self] in self?.parent.mergeDown() }
            let look = item("Aa") { [weak self] in self?.field?.resignFirstResponder(); self?.parent.style() }
            let bin = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.parent.delete() })
            bin.tintColor = .systemOrange
            bin.accessibilityLabel = "Delete this caption"
            let done = UIBarButtonItem(title: "Done", primaryAction: UIAction { [weak self] _ in self?.field?.resignFirstResponder() })
            done.tintColor = UIColor(Theme.accent)
            self.up = up; self.down = down
            refresh()
            func gap() -> UIBarButtonItem { .flexibleSpace() }
            t.items = [split, gap(), up, gap(), down, gap(), look, gap(), bin, gap(), done]
            t.sizeToFit()
            return t
        }
    }
}
