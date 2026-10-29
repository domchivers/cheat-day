import PhotosUI
import SwiftUI

/// A food in your cupboard with its real numbers, from a barcode or a photo of its label, so the planner's ideas
/// use what's printed on the pack instead of typical values. Kept on the phone between plans.
struct PantryItem: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var kcal100: Double
    var p100: Double?
    var c100: Double?
    var f100: Double?

    /// From a looked-up or read food; nil when it has no calories per 100 g to go on.
    init?(basis b: JSON) {
        guard let k = FoodMath.kcalPer100(b) else { return nil }
        let size = pos(b["servingSize"])
        func per100(_ key100: String, _ keyServ: String) -> Double? {
            if let v = num(b[key100]) { return v }
            if let v = num(b[keyServ]), let size { return v / size * 100 }
            return nil
        }
        let brand = str(b["brand"]), name = str(b["name"])
        self.name = brand.isEmpty || name.lowercased().contains(brand.lowercased()) ? name : "\(brand) \(name)"
        kcal100 = k
        p100 = per100("p100", "pServ"); c100 = per100("c100", "cServ"); f100 = per100("f100", "fServ")
    }

    var line: String { "\(Fmt.int(kcal100)) kcal\(p100.map { " · \(Fmt.int($0)) g protein" } ?? "") per 100 g" }

    /// For the planner's prompt.
    var prompt: String {
        "\(name): \(Fmt.int(kcal100)) kcal, \(p100.map { "\(Fmt.int($0)) g" } ?? "?") protein, \(c100.map { "\(Fmt.int($0)) g" } ?? "?") carbs, \(f100.map { "\(Fmt.int($0)) g" } ?? "?") fat per 100 g"
    }

    enum Saved {
        static func load(_ s: String) -> [PantryItem] { (try? JSONDecoder().decode([PantryItem].self, from: Data(s.utf8))) ?? [] }
        static func save(_ items: [PantryItem]) -> String { String(data: (try? JSONEncoder().encode(items)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" }
    }
}

/// Scan a barcode or photograph a label for the cupboard: no amounts, just the food and its numbers.
struct PantryScanSheet: View {
    enum Mode: String, Identifiable { case barcode, photo; var id: String { rawValue } }
    let mode: Mode
    let onItem: (PantryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy: String?
    @State private var problem: String?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Group {
                if let busy {
                    VStack(spacing: 14) { ProgressView().controlSize(.large); Text(busy).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let problem {
                    List {
                        Section { VStack(alignment: .leading, spacing: 6) { Text("Couldn't use that").font(.title3.bold()); Text(problem).foregroundStyle(.secondary) }.padding(.vertical, 6) }
                        Section { Button { self.problem = nil } label: { Label("Try again", systemImage: "arrow.clockwise") } }
                    }
                } else if mode == .barcode {
                    barcode
                } else {
                    photo
                }
            }
            .navigationTitle(mode == .barcode ? "Scan a barcode" : "Photo of a label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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

    @ViewBuilder private var barcode: some View {
        if BarcodeScanner.camera != nil {
            ZStack(alignment: .bottom) {
                BarcodeScanner { code in look(code) }.ignoresSafeArea(edges: .bottom)
                Text("Point at the barcode on the pack").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 30)
            }
        } else {
            Form {
                TextField("Barcode number", text: $typed).keyboardType(.numberPad)
                Button("Look it up") { look(typed.filter(\.isNumber)) }.disabled(typed.filter(\.isNumber).count < 6)
            }
        }
    }

    private var photo: some View {
        List {
            Section {
                Text("Take a photo of the nutrition table on the back. It's the most exact, and it's kept with the food for next time.")
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            }
            Section {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label("Take a photo", systemImage: "camera.fill").font(.headline) }
                }
                PhotosPicker(selection: $picked, matching: .images) { Label("Choose from your photos", systemImage: "photo.on.rectangle") }
            }
        }
    }

    private func look(_ code: String) {
        guard !code.isEmpty else { return }
        busy = "Looking up \(code)…"
        Task {
            defer { busy = nil }
            switch await OpenFoodFacts.lookup(code) {
            case .found(let b):
                if let item = PantryItem(basis: b) { onItem(item); dismiss() }
                else { problem = "That one has no calories listed. Take a photo of its nutrition table instead." }
            case .notFound: problem = "Barcode \(code) isn't in the database yet. Take a photo of its nutrition table instead."
            case .failed(let why): problem = why
            }
        }
    }

    private func read(_ img: UIImage) {
        busy = "Reading the label…"
        Task {
            defer { busy = nil }
            do {
                let r = try await LabelReader.read(img) { step in busy = step }
                if let item = PantryItem(basis: r.item) { onItem(item); dismiss() }
                else { problem = "Couldn't find calories per 100 g on that. Try a clearer photo of the table." }
            } catch { problem = error.localizedDescription }
        }
    }
}
