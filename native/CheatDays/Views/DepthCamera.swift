import AVFoundation
import SwiftUI
import UIKit

/// The assistant's own camera: on phones with depth (LiDAR on Pro models, the dual camera on most others) it takes the
/// depth map with the photo and measures real sizes from it (DepthMeasure). Phones without depth take a plain photo; where
/// the camera can't be set up at all, the system camera opens instead.
struct DepthCamera: View {
    /// The photo and its sizes (nil when it couldn't measure), or nil for cancelled; `library` when they tapped Library.
    let onDone: (UIImage?, DepthMeasure.Result?, _ library: Bool) -> Void
    @State private var cam = DepthCameraModel()
    @State private var flash = false

    var body: some View {
        if cam.failed {
            CameraPicker { onDone($0, nil, false) }.ignoresSafeArea()
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                PreviewLayer(session: cam.session).ignoresSafeArea()
                // the faint guide: the plate goes in here
                RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(.horizontal, 40).frame(height: 330).allowsHitTesting(false)
                VStack {
                    HStack {
                        Button { onDone(nil, nil, false) } label: {
                            Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
                        }
                        .accessibilityLabel("Close")
                        Spacer()
                        HStack(spacing: 7) {
                            Circle().fill(cam.depth ? Color.green : Color.gray).frame(width: 8, height: 8).shadow(color: cam.depth ? .green : .clear, radius: 4)
                            Text(cam.depth ? "Measuring sizes" : "Photo only").font(.footnote.weight(.bold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 13).padding(.vertical, 8).background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                        Color.clear.frame(width: 36, height: 36)
                    }
                    .padding(.horizontal, 20).padding(.top, 8)
                    Spacer()
                    VStack(spacing: 4) {
                        Text("Hold it above the food, plate in the frame").font(.subheadline.weight(.semibold))
                        Text(cam.depth ? "About 30 to 50 cm away. Angled is fine." : "Angled is fine.").font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white).shadow(color: .black, radius: 3).padding(.bottom, 24)
                    HStack {
                        side("photo.on.rectangle", "Library") { onDone(nil, nil, true) }
                        Spacer()
                        Button { cam.take(flash: flash) { img, r in onDone(img, r, false) } } label: {
                            Circle().fill(.white).frame(width: 62, height: 62).padding(4).overlay(Circle().stroke(.white, lineWidth: 4))
                        }
                        .disabled(cam.busy).accessibilityLabel("Take photo")
                        Spacer()
                        side(flash ? "bolt.fill" : "bolt.slash", "Flash") { flash.toggle() }
                    }
                    .padding(.horizontal, 36).padding(.bottom, 30)
                }
            }
            .task { await cam.start() }
            .onDisappear { cam.stop() }
        }
    }

    private func side(_ icon: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3).frame(width: 44, height: 44).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text(label).font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 56)
    }
}

@Observable @MainActor
final class DepthCameraModel: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var done: ((UIImage?, DepthMeasure.Result?) -> Void)?
    /// The camera's field of view, for the photo callback (off the main queue) when the depth has no calibration.
    @ObservationIgnored private nonisolated(unsafe) var fov: Float?
    var depth = false, failed = false, busy = false

    func start() async {
        guard device == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { failed = true; return }
        // the best depth this phone has: LiDAR, then the two cameras together; else the main camera on its own
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
                                                     mediaType: .video, position: .back).devices
        guard let dev = [AVCaptureDevice.DeviceType.builtInLiDARDepthCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            .lazy.compactMap({ t in found.first { $0.deviceType == t } }).first,
              let input = try? AVCaptureDeviceInput(device: dev) else { failed = true; return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); failed = true; return }
        session.addInput(input)
        session.addOutput(output)
        // some formats carry no depth (LiDAR's default can't): one that does, as big as there is
        if dev.activeFormat.supportedDepthDataFormats.isEmpty, let f = dev.formats.last(where: { !$0.supportedDepthDataFormats.isEmpty }), (try? dev.lockForConfiguration()) != nil {
            dev.activeFormat = f
            dev.unlockForConfiguration()
        }
        output.maxPhotoQualityPrioritization = .balanced
        if output.isDepthDataDeliverySupported { output.isDepthDataDeliveryEnabled = true }
        session.commitConfiguration()
        device = dev
        fov = dev.activeFormat.videoFieldOfView
        depth = output.isDepthDataDeliveryEnabled
        let s = session
        await Task.detached { s.startRunning() }.value
    }

    func stop() {
        let s = session
        Task.detached { s.stopRunning() }
    }

    func take(flash: Bool, _ done: @escaping (UIImage?, DepthMeasure.Result?) -> Void) {
        guard !busy else { return }
        busy = true
        self.done = done
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(.on) { settings.flashMode = flash ? .on : .off }
        if output.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.isDepthDataFiltered = true   // the holes filled in
        }
        // the app's upright, so the photo is too unless the phone's held sideways
        let o = UIDevice.current.orientation
        let angle: CGFloat = o == .landscapeLeft ? 0 : o == .landscapeRight ? 180 : 90
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Called on the camera's own queue: measured there, handed back on the main one.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let img = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        let measured = photo.depthData.flatMap { d in Self.measure(d, portrait: img.map { $0.imageOrientation == .right || $0.imageOrientation == .left } ?? true, fov: fov) }
        Task { @MainActor in
            busy = false
            done?(img, measured)
            done = nil
        }
    }

    /// The depth map in metres, and the lens it was seen through, measured. Disparity (the dual camera's) is turned into depth.
    nonisolated static func measure(_ data: AVDepthData, portrait: Bool, fov: Float?) -> DepthMeasure.Result? {
        let d = data.depthDataType == kCVPixelFormatType_DepthFloat32 ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = d.depthDataMap
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let row = CVPixelBufferGetBytesPerRow(map)
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in 0..<w { depth[y * w + x] = line[x] }
        }
        // the lens: the calibration's when there is one (scaled to the depth map), else from the camera's field of view
        let lens: DepthMeasure.Lens
        if let cal = d.cameraCalibrationData {
            let k = cal.intrinsicMatrix, ref = cal.intrinsicMatrixReferenceDimensions
            let sx = Double(w) / Double(ref.width), sy = Double(h) / Double(ref.height)
            lens = .init(fx: Double(k.columns.0.x) * sx, fy: Double(k.columns.1.y) * sy, cx: Double(k.columns.2.x) * sx, cy: Double(k.columns.2.y) * sy)
        } else if let fov, fov > 0 {
            let f = Double(w) / 2 / tan(Double(fov) * .pi / 360)
            lens = .init(fx: f, fy: f, cx: Double(w) / 2, cy: Double(h) / 2)
        } else { return nil }
        guard var r = DepthMeasure.measure(depth: depth, width: w, height: h, lens: lens, portrait: portrait) else { return nil }
        r.rough = d.depthDataAccuracy != .absolute
        return r
    }
}

/// The camera's live picture.
private struct PreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession
    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: V, context: Context) {}
}
