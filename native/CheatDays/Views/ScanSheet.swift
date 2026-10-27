import AVFoundation
import SwiftUI

/// Scan a barcode with the camera, look it up, then pick how much.
struct ScanSheet: View {
    enum Phase { case scanning, looking(String), found(EditTarget), notFound(String), failed(String, String) }

    let meal: String
    let onAdded: () -> Void
    let onFlow: (WebFlow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .scanning
    @State private var typed = ""
    @State private var found = 0

    private var scannerWorks: Bool { BarcodeScanner.camera != nil && AVCaptureDevice.authorizationStatus(for: .video) != .denied }

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

/// The barcode scanner: the camera straight into AVFoundation's barcode reader, which reads a code in a frame or two.
/// Locked to the main (wide) lens: Apple's ready-made scanner let Pro iPhones hop between lenses as you moved, so the
/// picture kept zooming in and out and took seconds to settle. Calls back once with the first code it reads.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var camera: AVCaptureDevice? { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) }

    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onCode: onCode) }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ vc: ScannerController, coordinator: ()) { vc.stop() }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "scanner.session")
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            AVCaptureDevice.requestAccess(for: .video) { ok in
                guard ok else { return }
                self.queue.async { self.configure() }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        private func configure() {
            guard let device = BarcodeScanner.camera, let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                // only the codes on food packs
                let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce, .itf14, .code128]
                output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }
            }
            session.commitConfiguration()
            if (try? device.lockForConfiguration()) != nil {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                // Pro iPhones can't focus nearer than about 20 cm: a fixed, gentle zoom lets a pack held at a natural
                // distance fill the picture and stay sharp. Set once, so it never hunts. Other phones stay at 1x.
                let minFocus = Double(device.minimumFocusDistance)
                if minFocus > 150 { device.videoZoomFactor = min(CGFloat(minFocus / 100), device.activeFormat.videoMaxZoomFactor, 2) }
                device.unlockForConfiguration()
            }
            session.startRunning()
        }

        func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first(where: { !$0.isEmpty }) else { return }
            done = true
            stop()
            onCode(code)
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
