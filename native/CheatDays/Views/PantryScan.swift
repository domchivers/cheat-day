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

/// Scan barcodes or photograph labels for the cupboard: no amounts, just each food and its numbers. Stays open so
/// you can see what was read, name anything a label didn't say, and add several at once.
struct PantryScanSheet: View {
    enum Mode: String, Identifiable { case barcode, photo; var id: String { rawValue } }
    let mode: Mode
    let onItems: ([PantryItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: [PantryItem] = []
    @State private var busy: String?
    @State private var problem: String?
    @State private var camera = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var typed = ""
    @State private var scannerOpen = true
    @FocusState private var naming: String?

    private var ready: Bool { !found.isEmpty && found.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .barcode && scannerOpen && busy == nil { scanner } else { list }
            }
            .navigationTitle(mode == .barcode ? "Scan a barcode" : "Photo of a label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fullScreenCover(isPresented: $camera) {
                CameraPicker { img in camera = false; if let img { Task { await read(img) } } }.ignoresSafeArea()
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await read(img) }
                    }
                    picked = []
                }
            }
            .keyboardDone()
        }
    }

    @ViewBuilder private var scanner: some View {
        if BarcodeScanner.camera != nil {
            ZStack(alignment: .bottom) {
                BarcodeScanner { code in Task { await look(code) } }.ignoresSafeArea(edges: .bottom)
                Text("Point at the barcode on the pack").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 30)
            }
        } else {
            Form {
                TextField("Barcode number", text: $typed).keyboardType(.numberPad)
                Button("Look it up") { Task { await look(typed.filter(\.isNumber)); typed = "" } }.disabled(typed.filter(\.isNumber).count < 6)
            }
        }
    }

    /// What's been read so far, each with a name to check, and the ways to add more.
    private var list: some View {
        List {
            Section {
                if mode == .barcode {
                    Button { problem = nil; scannerOpen = true } label: { Label(found.isEmpty ? "Scan a barcode" : "Scan another", systemImage: "barcode.viewfinder").font(.headline) }
                } else {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { problem = nil; camera = true } label: { Label(found.isEmpty ? "Take a photo" : "Take another", systemImage: "camera.fill").font(.headline) }
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) { Label("Choose photos", systemImage: "photo.on.rectangle") }
                }
            } footer: {
                if mode == .photo && found.isEmpty { Text("Take a photo of the nutrition table on the back: it's the most exact. You can choose several photos at once.") }
            }
            if let busy { Section { HStack(spacing: 10) { ProgressView(); Text(busy).foregroundStyle(.secondary) } } }
            if let problem { Section { Text(problem).font(.footnote).foregroundStyle(Theme.warn) } }
            if !found.isEmpty {
                Section {
                    ForEach($found) { $item in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("What is it? e.g. Protein powder", text: $item.name).font(.body.weight(.semibold)).focused($naming, equals: item.id)
                            HStack {
                                Text(item.line).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { withAnimation { found.removeAll { $0.id == item.id } } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 36, height: 30) }
                                    .buttonStyle(.borderless).accessibilityLabel("Don't add this")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text(mode == .barcode ? "Scanned" : "Read from your photos") } footer: {
                    if !ready { Text("Give each one a name to add them.") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !found.isEmpty {
                Button { onItems(found); dismiss() } label: {
                    Text("Add \(found.count) to your cupboard").font(.headline).foregroundStyle(ready ? Color.black : Theme.heroLabel)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(ready ? Theme.accent : Theme.hero, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain).disabled(!ready || busy != nil).padding(.horizontal, 20).padding(.bottom, 8)   // wait for every photo to be read
            }
        }
    }

    private func add(_ item: PantryItem) {
        withAnimation { found.append(item) }
        if item.name.trimmingCharacters(in: .whitespaces).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { naming = item.id }   // labels rarely say what they are
        }
    }

    private func look(_ code: String) async {
        guard !code.isEmpty else { return }
        scannerOpen = false; problem = nil
        busy = "Looking up \(code)…"
        defer { busy = nil }
        switch await OpenFoodFacts.lookup(code) {
        case .found(let b):
            if let item = PantryItem(basis: b) { add(item) }
            else { problem = "Barcode \(code) has no calories listed. Use a photo of its nutrition table instead." }
        case .notFound: problem = "Barcode \(code) isn't in the database yet. Use a photo of its nutrition table instead."
        case .failed(let why): problem = why
        }
    }

    private func read(_ img: UIImage) async {
        problem = nil
        busy = "Reading the label…"
        defer { busy = nil }
        do {
            let r = try await LabelReader.read(img) { step in busy = step }
            if let item = PantryItem(basis: r.item) { add(item) }
            else { problem = "Couldn't find calories per 100 g on one photo. Try a clearer photo of the table." }
        } catch { problem = error.localizedDescription }
    }
}
