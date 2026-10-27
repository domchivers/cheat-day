import AVFoundation
import SwiftUI
import Vision
import VisionKit

/// Scan a barcode with the iPhone's own scanner, look it up, then pick how much.
struct ScanSheet: View {
    enum Phase { case scanning, looking(String), found(EditTarget), notFound(String), failed(String, String) }

    let meal: String
    let onAdded: () -> Void
    let onFlow: (WebFlow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    @State private var typed = ""
    @State private var found = 0

    private var scannerWorks: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .scanning: scanning.keyboardDone()   // only here: "How much?" brings its own
                case .looking(let code):
                    VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Looking up \(code)…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .found(let t):
                    AmountView(target: t) { onAdded() }
                case .notFound(let code):
                    problem("Not on Open Food Facts yet", "Barcode \(code) isn't in the database. Take a photo of the pack or its nutrition table instead, or type the numbers in.")
                case .failed(let code, let why):
                    problem("Couldn't look it up", "\(why) Try barcode \(code) again in a moment, or use a photo.", retry: code)
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sensoryFeedback(.success, trigger: found)
        }
    }

    @ViewBuilder private var scanning: some View {
        if scannerWorks {
            ZStack(alignment: .bottom) {
                BarcodeScanner { code in look(code) }.ignoresSafeArea(edges: .bottom)
                Text("Point at a barcode").font(.subheadline.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 30)
            }
            .overlay(alignment: .topTrailing) { TorchButton().padding(16) }
        } else {
            Form {
                Section {
                    TextField("Barcode number", text: $typed).keyboardType(.numberPad)
                    Button("Look it up") { look(typed.filter(\.isNumber)) }.disabled(typed.filter(\.isNumber).count < 6)
                } footer: { Text("This phone can't scan barcodes with the camera here. Type the number under the bars instead.") }
            }
        }
    }

    private func problem(_ title: String, _ message: String, retry: String? = nil) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) { Text(title).font(.title3.bold()); Text(message).foregroundStyle(.secondary) }.padding(.vertical, 6)
            }
            Section {
                if let retry { Button { look(retry) } label: { Label("Try again", systemImage: "arrow.clockwise") } }
                Button { onFlow(WebFlow(view: "scan", opts: ["scan": "label", "meal": meal], title: "Photo")) } label: { Label("Take a photo instead", systemImage: "camera.fill") }
                NavigationLink { ManualEntry(meal: meal) { onAdded() } } label: { Label("Type the numbers in", systemImage: "square.and.pencil") }
                Button { phase = .scanning } label: { Label("Scan another", systemImage: "barcode.viewfinder") }
            }
        }
    }

    private func look(_ code: String) {
        guard !code.isEmpty else { return }
        phase = .looking(code)
        Task {
            switch await OpenFoodFacts.lookup(code) {
            case .found(let item):
                if pos(item["kcalPer100"]) == nil && pos(item["kcalPerServing"]) == nil { phase = .notFound(code); return }
                found += 1
                phase = .found(EditTarget(basis: item, kcal: nil, editId: nil, meal: meal))
            case .notFound: phase = .notFound(code)
            case .failed(let why): phase = .failed(code, why)
            }
        }
    }
}

/// Apple's live barcode scanner (VisionKit). Calls back once with the first code it reads.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            // only the codes on food packs: fewer kinds to look for reads faster
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .itf14, .code128])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            try? vc.startScanning()
            // newer Pro iPhones can't focus closer than about 20 cm: a little zoom lets a pack held closer than that come
            // into focus (Apple's suggestion). Other phones stay at 1x, which reads fastest.
            if let d = AVCaptureDevice.default(for: .video), d.minimumFocusDistance > 150 {
                let z = Double(d.minimumFocusDistance) / 120
                vc.zoomFactor = min(max(vc.minZoomFactor, z), min(vc.maxZoomFactor, 2))
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) { vc.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { take(addedItems, dataScanner) }
        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) { take(updatedItems, dataScanner) }

        private func take(_ items: [RecognizedItem], _ dataScanner: DataScannerViewController) {
            guard !done else { return }
            for item in items {
                if case .barcode(let b) = item, let value = b.payloadStringValue, !value.isEmpty {
                    done = true
                    dataScanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}

/// The torch, for scanning in a dim kitchen.
private struct TorchButton: View {
    @State private var on = false
    var body: some View {
        Button {
            guard let d = AVCaptureDevice.default(for: .video), d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
            on.toggle()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        } label: {
            Image(systemName: on ? "flashlight.on.fill" : "flashlight.off.fill").font(.title3).foregroundStyle(on ? .yellow : .white)
                .frame(width: 48, height: 48).background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(on ? "Torch off" : "Torch on")
        .onDisappear {
            guard on, let d = AVCaptureDevice.default(for: .video), (try? d.lockForConfiguration()) != nil else { return }
            d.torchMode = .off; d.unlockForConfiguration()
        }
    }
}
