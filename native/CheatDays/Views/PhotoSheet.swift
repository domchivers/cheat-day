import PhotosUI
import SwiftUI

/// Take or pick a photo of a pack or its nutrition table; the AI reads it, then pick how much.
struct PhotoSheet: View {
    enum Phase { case choose, reading(UIImage, String), found(EditTarget), failed(String) }

    let meal: String
    let onAdded: () -> Void
    let onFlow: (WebFlow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .choose
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var done = 0

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .choose: choose
                case .reading(let img, let step):
                    VStack(spacing: 18) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 170, height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        ProgressView().controlSize(.large)
                        Text(step).font(.headline).foregroundStyle(.secondary).contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .found(let t):
                    AmountView(target: t) { onAdded() }
                case .failed(let why):
                    List {
                        Section { VStack(alignment: .leading, spacing: 6) { Text("Couldn't read that").font(.title3.bold()); Text(why).foregroundStyle(.secondary) }.padding(.vertical, 6) }
                        Section {
                            Button { phase = .choose } label: { Label("Try another photo", systemImage: "camera.fill") }
                            NavigationLink { ManualEntry(meal: meal) { onAdded() } } label: { Label("Type the numbers in", systemImage: "square.and.pencil") }
                        }
                    }
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sensoryFeedback(.success, trigger: done)
            .fullScreenCover(isPresented: $camera) {
                CameraPicker { img in camera = false; if let img { read(img) } }.ignoresSafeArea()
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { read(img) }
                    picked = nil
                }
            }
        }
    }

    private var choose: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Photo of the pack or the nutrition table").font(.title3.bold())
                    Text("The front of a pack works: it reads what's printed, checks the product, and asks how many. The table on the back is the most exact.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera.fill").font(.headline) }
                }
                PhotosPicker(selection: $picked, matching: .images) { Label("Choose from your photos", systemImage: "photo.on.rectangle") }
            }
        }
    }

    private func read(_ img: UIImage) {
        phase = .reading(img, "Reading the photo…")
        Task {
            do {
                let r = try await LabelReader.read(img) { step in phase = .reading(img, step) }
                done += 1
                phase = .found(EditTarget(basis: r.item, kcal: nil, editId: nil, meal: meal, note: r.note))
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// The camera, for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onDone: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ p: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void
        init(onDone: @escaping (UIImage?) -> Void) { self.onDone = onDone }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onDone(nil) }
    }
}

/// Type the numbers in: per 100 g, or per piece or serving.
struct ManualEntry: View {
    let meal: String
    let onAdded: () -> Void
    @State private var name = ""
    @State private var per = 0
    @State private var kcalText = ""
    @State private var servingText = ""
    @State private var pieceName = ""
    @State private var unit = "g"
    @State private var p = ""
    @State private var c = ""
    @State private var f = ""
    @State private var go: EditTarget?

    private func d(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        Form {
            Section { TextField("What is it?", text: $name).font(.headline) }
            Section {
                Picker("Calories are", selection: $per) { Text("Per 100 \(unit)").tag(0); Text("For one").tag(1) }.pickerStyle(.segmented)
                HStack { TextField("Calories", text: $kcalText).keyboardType(.decimalPad); Text("kcal").foregroundStyle(.secondary) }
                if per == 1 {
                    TextField("One what? (slice, bar, serving)", text: $pieceName)
                    HStack { TextField("Weighs (optional)", text: $servingText).keyboardType(.decimalPad); Text(unit).foregroundStyle(.secondary) }
                } else {
                    HStack { TextField("A usual portion (optional)", text: $servingText).keyboardType(.decimalPad); Text(unit).foregroundStyle(.secondary) }
                }
                Picker("Measured in", selection: $unit) { Text("grams").tag("g"); Text("ml").tag("ml") }
            } header: { Text("From the pack") }
            Section {
                HStack { Text("Protein"); TextField("g", text: $p).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                HStack { Text("Carbs"); TextField("g", text: $c).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                HStack { Text("Fat"); TextField("g", text: $f).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            } header: { Text(per == 0 ? "Per 100 \(unit), optional" : "In one, optional") }
            Section {
                Button("Next: how much") { next() }.font(.headline).frame(maxWidth: .infinity).disabled((d(kcalText) ?? 0) <= 0)
            }
        }
        .navigationTitle("Type it in")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $go) { t in AmountView(target: t) { onAdded() } }
    }

    private func next() {
        guard let k = d(kcalText), k > 0 else { return }
        var b: JSON = ["source": "manual", "name": name.trimmingCharacters(in: .whitespaces).isEmpty ? "Something tasty" : name.trimmingCharacters(in: .whitespaces), "unit": unit]
        let serving = d(servingText)
        let hasMacros = d(p) != nil || d(c) != nil || d(f) != nil
        if per == 0 {
            b["kcalPer100"] = k
            if let serving, serving > 0 { b["servingSize"] = serving }
            if hasMacros { b["p100"] = d(p) ?? 0; b["c100"] = d(c) ?? 0; b["f100"] = d(f) ?? 0 }
        } else {
            b["kcalPerServing"] = k
            let label = pieceName.trimmingCharacters(in: .whitespaces).lowercased()
            b["unitLabel"] = label.isEmpty ? "serving" : (label.hasSuffix("s") ? String(label.dropLast()) : label)
            if let serving, serving > 0 { b["servingSize"] = serving; b["kcalPer100"] = k / serving * 100 }
            if hasMacros { b["pServ"] = d(p) ?? 0; b["cServ"] = d(c) ?? 0; b["fServ"] = d(f) ?? 0 }
        }
        go = EditTarget(basis: b, kcal: nil, editId: nil, meal: meal)
    }
}
