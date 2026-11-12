import AVFoundation
import Photos
import PhotosUI
import SwiftUI

/// Adding to a story opens here, Instagram's way: the camera live and full screen. Tap the shutter for a photo, hold
/// it to film (up to 30 seconds, a red ring filling; slide up while holding to zoom). Flash, flip (or double-tap),
/// .5 / 1× / 2 and pinch to zoom. Your latest photo sits bottom left: it and a swipe up open your recent photos and
/// videos. Aa starts a story that's just text on a colour.
struct StoryCamera: View {
    var captured: (UIImage?, URL?) -> Void
    var close: () -> Void
    /// Aa: a story that's just words on a colour, opened straight into writing.
    var wordsOnly: (UIImage) -> Void = { _ in }
    @State private var cam = CameraRig()
    @State private var recording = false
    @State private var started: Date?
    @State private var elapsed: Double = 0
    @State private var pressing = false
    @State private var zoomStart: CGFloat = 1
    @State private var recents = false
    @State private var picked: PhotosPickerItem?
    @State private var library = false
    // camera modes, down the left as Instagram has them. Layout: 2 or 4 photos taken one after another and made
    // into one picture (0 when off). Hands-free: a tap starts filming and a tap stops it, no holding.
    @State private var layout = 0
    @State private var cells: [UIImage] = []
    @State private var handsFree = false

    var body: some View {
        // The same sums as the story editor's (StoryEditor.body): a 9:16 picture in the same space, the bar under it
        // where the editor's buttons will be, the X where the editor's X will be. Laid out its own way before (a
        // taller picture, a deeper bar, a bigger X higher up), everything jumped as a photo or video went from one
        // to the other.
        GeometryReader { screen in
            let low = max(0, screen.safeAreaInsets.bottom - 22)
            let stageH = max(120, screen.size.height + low - 70)
            let cw = min(screen.size.width, stageH * 9 / 16), ch = cw * 16 / 9
            VStack(spacing: 10) {
                ZStack {
                    if cam.denied {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                            Text("Allow the camera in Settings to take photos and videos for your story.").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center).padding(.horizontal, 40)
                            Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.font(.headline)
                        }
                    } else {
                        CameraPreview(session: cam.session)
                            .gesture(MagnifyGesture().onChanged { m in cam.zoom(to: zoomStart * m.magnification, glide: true) }.onEnded { _ in zoomStart = cam.zoomFactor })
                            .onTapGesture(count: 2) { cam.flip() }
                    }
                    if layout > 0 { layoutGuide.allowsHitTesting(false) }
                    if !recording && !cam.denied { modes }
                    if recording {
                        Text(String(format: "0:%02d", Int(elapsed))).font(.subheadline.weight(.heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14)
                    } else {
                        controlsTop
                    }
                    VStack(spacing: 18) {
                        Spacer()
                        if !recording && !cam.denied { zoomButtons }
                        if !recording, layout > 0 || handsFree {
                            Text(layout > 0 ? "Photo \(cells.count + 1) of \(layout)" : "Tap to start, tap to stop")
                                .font(.footnote.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                        shutter
                    }
                    .padding(.bottom, 22)
                }
                .frame(width: cw, height: ch)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in if v.translation.height < -60 && !recording { recents = true } })
                .frame(width: screen.size.width, height: stageH)
                bottomBar.frame(width: screen.size.width, height: 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: low / 2)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .task { await cam.start() }
        .onDisappear { cam.stop() }
        .sheet(isPresented: $recents) {
            RecentMedia { img, url in recents = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { captured(img, url) } } more: {
                recents = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { library = true }
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $library, selection: $picked, matching: .any(of: [.images, .videos]))
        .onChange(of: picked) { _, item in Task { await load(item) } }
        .onChange(of: cam.finishedMovie) { _, url in if let url { captured(nil, url) } }
        .onChange(of: cam.photo) { _, img in if let img { took(img) } }
    }

    private var controlsTop: some View {
        VStack {
            HStack {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
                Spacer()
                // Aa beside the flash, the same size and weight (it sat on its own line below)
                Button { textOnly() } label: {
                    Text("Aa").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("A text story")
                Button { cam.cycleFlash() } label: {
                    Image(systemName: cam.flash == .on ? "bolt.fill" : cam.flash == .auto ? "bolt.badge.automatic.fill" : "bolt.slash.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(cam.flash == .on ? .yellow : .white)
                        .frame(width: 34, height: 34).background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Flash")
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 12)
    }

    /// The phone's own lenses as a row in one dark pill, the way the Camera app shows them: the one in use bigger and
    /// yellow with its ×, showing the exact zoom while it's between two (1.4×). Which numbers are there comes from the
    /// phone (see CameraRig.stops): they were always .5, 1 and 2 before, whatever lenses it had.
    private var zoomButtons: some View {
        let stops = cam.stops
        // the one in use: the biggest that the zoom has reached
        let current = stops.last(where: { cam.shownZoom >= $0 - 0.04 }) ?? stops.first ?? 1
        return HStack(spacing: 2) {
            ForEach(stops, id: \.self) { z in
                let on = z == current
                Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation(.snappy) { cam.zoom(shown: z) }; zoomStart = cam.zoomFactor } label: {
                    Text(on ? Self.zoomName(cam.shownZoom) + "×" : Self.zoomName(z))
                        .font(.system(size: on ? 13 : 12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(on ? Color.yellow : Color.white)
                        .frame(width: on ? 42 : 34, height: on ? 42 : 34)
                        .background(Color.black.opacity(on ? 0.55 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(Self.zoomName(z) + " times zoom").accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3).background(.black.opacity(0.35), in: Capsule())
        .opacity(stops.count > 1 ? 1 : 0)
    }

    /// A zoom as the Camera app writes it: .5, 1, 2, 1.4 (no nought before the point, no ".0").
    private static func zoomName(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        if abs(r - r.rounded()) < 0.05 { return "\(Int(r.rounded()))" }
        let t = String(format: "%.1f", Double(r))
        return t.hasPrefix("0") ? String(t.dropFirst()) : t
    }

    /// Tap for a photo; hold for a video, slide up while holding to zoom in.
    private var shutter: some View {
        ZStack {
            Circle().stroke(.white.opacity(recording ? 0.25 : 1), lineWidth: 6).frame(width: recording ? 96 : 82, height: recording ? 96 : 82)
            if recording {
                Circle().trim(from: 0, to: elapsed / 30).stroke(Color.red, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    .frame(width: 96, height: 96)
                RoundedRectangle(cornerRadius: 10).fill(Color.red).frame(width: 40, height: 40)
            } else {
                Circle().fill(.white).frame(width: pressing ? 60 : 66, height: pressing ? 60 : 66)
            }
        }
        .animation(.snappy(duration: 0.2), value: recording)
        .contentShape(Circle().inset(by: -10))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !pressing {
                    pressing = true
                    guard !handsFree, layout == 0 else { return }   // no holding to film in those: a tap does it all
                    let at = Date(); started = at
                    // held a moment: it's a video
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard pressing, started == at, !recording else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        cam.startMovie(); recording = true; elapsed = 0; zoomStart = cam.zoomFactor
                        tick(at)
                    }
                }
                // each stretch of the thumb's travel doubles the zoom (it grew by a fixed amount per point, which
                // rushed at the start and crawled further up), and the camera glides to it
                if recording { cam.zoom(to: zoomStart * pow(2, max(0, -v.translation.height) / 150), glide: true) }
            }
            .onEnded { _ in
                pressing = false
                if handsFree && !recording && !cam.denied {
                    // hands-free: this tap starts it; the next one (below) stops it
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let at = Date(); started = at
                    cam.startMovie(); recording = true; elapsed = 0; zoomStart = cam.zoomFactor
                    tick(at)
                    return
                }
                if recording { cam.stopMovie(); recording = false }
                else if !cam.denied { UIImpactFeedbackGenerator(style: .light).impactOccurred(); cam.takePhoto() }
            })
        .accessibilityLabel("Shutter").accessibilityHint("Tap for a photo, hold to film")
    }

    // MARK: modes

    private var modes: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeButton("square.grid.2x2", layout == 0 ? "Layout" : "Layout · \(layout)", on: layout > 0) {
                layout = layout == 0 ? 2 : layout == 2 ? 4 : 0
                cells = []; if layout > 0 { handsFree = false }
            }
            modeButton("record.circle", "Hands-free", on: handsFree) {
                handsFree.toggle(); if handsFree { layout = 0; cells = [] }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.leading, 10)
    }

    private func modeButton(_ symbol: String, _ name: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { UISelectionFeedbackGenerator().selectionChanged(); withAnimation(.snappy(duration: 0.2)) { tap() } } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(on ? .black : .white)
                    .frame(width: 40, height: 40).background(on ? Color.yellow : Color.black.opacity(0.45), in: Circle())
                Text(name).font(.caption.weight(.bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 3)
            }
        }
        .buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Where each of Layout's photos goes, as fractions of the picture: two, one over the other; four, two by two.
    private static func places(_ n: Int) -> [CGRect] {
        n == 2 ? [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
               : [CGRect(x: 0, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                  CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
    }

    /// Over the camera in Layout: the photos taken so far in their places, the next place ringed, the rest dimmed.
    private var layoutGuide: some View {
        GeometryReader { g in
            let spots = Self.places(layout)
            ZStack(alignment: .topLeading) {
                ForEach(spots.indices, id: \.self) { i in
                    let r = spots[i], w = r.width * g.size.width, h = r.height * g.size.height
                    Group {
                        if i < cells.count { Image(uiImage: cells[i]).resizable().scaledToFill().frame(width: w, height: h).clipped() }
                        else if i == cells.count { Rectangle().strokeBorder(Color.yellow, lineWidth: 3) }
                        else { Color.black.opacity(0.45) }
                    }
                    .frame(width: w, height: h)
                    .overlay(Rectangle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    .offset(x: r.minX * g.size.width, y: r.minY * g.size.height)
                }
            }
        }
    }

    /// A photo from the shutter: the story's picture, or in Layout the next of its photos (the last one finishes it).
    private func took(_ img: UIImage) {
        guard layout > 0 else { captured(img, nil); return }
        cells.append(img)
        guard cells.count >= layout else { return }
        let out = Self.collage(cells, layout)
        cells = []
        captured(out, nil)
    }

    /// Layout's photos as one 9:16 picture, each filling its place from its middle.
    static func collage(_ shots: [UIImage], _ n: Int) -> UIImage {
        let size = CGSize(width: 1080, height: 1920), spots = places(n)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            for (i, shot) in shots.prefix(spots.count).enumerated() {
                let r = CGRect(x: spots[i].minX * size.width, y: spots[i].minY * size.height, width: spots[i].width * size.width, height: spots[i].height * size.height)
                let k = max(r.width / max(1, shot.size.width), r.height / max(1, shot.size.height))
                let w = shot.size.width * k, h = shot.size.height * k
                ctx.cgContext.saveGState()
                ctx.cgContext.clip(to: r)
                shot.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
                ctx.cgContext.restoreGState()
            }
            // a fine white line between them
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: size.height / 2 - 2, width: size.width, height: 4))
            if n == 4 { UIRectFill(CGRect(x: size.width / 2 - 2, y: 0, width: 4, height: size.height)) }
        }
    }

    private func tick(_ at: Date) {
        guard recording, started == at else { return }
        elapsed = Date().timeIntervalSince(at)
        if elapsed >= 30 { cam.stopMovie(); recording = false; pressing = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick(at) }
    }

    private var bottomBar: some View {
        HStack {
            Button { recents = true } label: {
                Group {
                    if let t = cam.latest { Image(uiImage: t).resizable().scaledToFill() } else { Image(systemName: "photo.on.rectangle").foregroundStyle(.white).font(.title3) }
                }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
            }
            .accessibilityLabel("Your photos")
            Spacer()
            Text("STORY").font(.subheadline.weight(.heavy)).foregroundStyle(.white)
            Spacer()
            Button { cam.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Color(white: 0.15), in: Circle())
            }
            .accessibilityLabel("Flip camera")
        }
        .padding(.horizontal, 26)
        .opacity(recording ? 0 : 1)
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }), let m = try? await item.loadTransferable(type: PickedMovie.self) { captured(nil, m.url) }
        else if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { captured(img, nil) }
        picked = nil
    }

    private func textOnly() { UIImpactFeedbackGenerator(style: .light).impactOccurred(); wordsOnly(Self.colourCard()) }

    /// A text story's background: one of six of the app's gradients, three colours each, with a soft glow, like
    /// Instagram's Create (two flat colours looked basic).
    static func colourCard() -> UIImage {
        func c(_ hex: Int) -> UIColor { UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1) }
        let sets: [[Int]] = [[0x1B2F52, 0x4A3A8C, 0xC4A1FF], [0xFF6B3D, 0xE0457B, 0x8A3FB8], [0x0F3D3E, 0x2A8C7A, 0x8CD9B6],
                             [0x101828, 0x2B3F7A, 0x8CC4FF], [0x3A1C4A, 0xB0447A, 0xF2C66B], [0x0B0D12, 0x26304A, 0x5C6B9A]]
        let cols = sets.randomElement()!.map { c($0).cgColor }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1920), format: format).image { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let g = CGGradient(colorsSpace: space, colors: cols as CFArray, locations: [0, 0.55, 1])!
            ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1080, y: 1920), options: [])
            let glow = CGGradient(colorsSpace: space, colors: [UIColor.white.withAlphaComponent(0.18).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(glow, startCenter: CGPoint(x: 780, y: 520), startRadius: 0, endCenter: CGPoint(x: 780, y: 520), endRadius: 900, options: [])
        }
    }
}

/// The camera itself: photos, videos with sound, the back cameras' zoom range (ultra wide when there is one), flash and flip.
@Observable @MainActor
final class CameraRig: NSObject {
    let session = AVCaptureSession()
    private let photos = AVCapturePhotoOutput()
    private let movies = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "story.camera")
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    var front = false
    var flash: AVCaptureDevice.FlashMode = .off
    var denied = false
    var latest: UIImage?
    var photo: UIImage?
    var finishedMovie: URL?
    /// The zoom shown on the buttons: 1 is the main camera, 0.5 the ultra wide.
    private(set) var shownZoom: CGFloat = 1
    private(set) var zoomFactor: CGFloat = 1
    private var mainFactor: CGFloat = 1   // the device zoom factor that is "1×"
    /// The zooms offered as buttons, from the lenses this phone has: its ultra wide (.5, or whatever it is), 1, 2
    /// (the main camera cropped, as the Camera app offers it), then each longer lens by its own number (3, 5…).
    /// The front camera has the one.
    private(set) var stops: [CGFloat] = [1, 2]

    func start() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        guard video else { denied = true; return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await loadLatest()
        configure()
    }

    func stop() { let s = session; queue.async { if s.isRunning { s.stopRunning() } } }

    private func camera(front: Bool) -> AVCaptureDevice? {
        if front { return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) }
        return AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configure() {
        guard let dev = camera(front: front) else { return }
        let s = session, ph = photos, mv = movies
        let main: CGFloat = dev.isVirtualDevice && dev.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera })
            ? CGFloat(truncating: dev.virtualDeviceSwitchOverVideoZoomFactors.first ?? 1) : 1
        mainFactor = main
        if dev.position == .front { stops = [1] } else {
            var list: [CGFloat] = []
            if main > 1 { list.append((10 / main).rounded() / 10) }   // the ultra wide: half the main camera, on most
            list.append(1)
            // where the phone changes to a longer lens, as so many times the main one, to the nearest half
            let longer = dev.isVirtualDevice
                ? dev.virtualDeviceSwitchOverVideoZoomFactors.map { (CGFloat(truncating: $0) / main * 2).rounded() / 2 }.filter { $0 > 1.4 } : []
            if !longer.contains(where: { abs($0 - 2) < 0.3 }) { list.append(2) }
            list.append(contentsOf: longer)
            stops = Array(list.prefix(4))
        }
        queue.async {
            s.beginConfiguration()
            s.sessionPreset = .high
            for i in s.inputs { s.removeInput(i) }
            if let vi = try? AVCaptureDeviceInput(device: dev), s.canAddInput(vi) { s.addInput(vi) }
            if let mic = AVCaptureDevice.default(for: .audio), let ai = try? AVCaptureDeviceInput(device: mic), s.canAddInput(ai) { s.addInput(ai) }
            if !s.outputs.contains(ph), s.canAddOutput(ph) { s.addOutput(ph) }
            if !s.outputs.contains(mv), s.canAddOutput(mv) { s.addOutput(mv) }
            mv.maxRecordedDuration = CMTime(seconds: 30, preferredTimescale: 600)
            if let c = mv.connection(with: .video), c.isVideoMirroringSupported { c.isVideoMirrored = dev.position == .front }
            s.commitConfiguration()
            if (try? dev.lockForConfiguration()) != nil { dev.videoZoomFactor = main; dev.unlockForConfiguration() }
            if !s.isRunning { s.startRunning() }
        }
        device = dev; zoomFactor = main; shownZoom = 1
    }

    func flip() { front.toggle(); UIImpactFeedbackGenerator(style: .light).impactOccurred(); configure() }
    func cycleFlash() { flash = flash == .off ? .auto : flash == .auto ? .on : .off }

    /// A device zoom factor, kept in the camera's range.
    /// `glide`: from a moving finger. The camera is asked to run smoothly to the zoom wanted (and is asked again,
    /// from wherever it's got to, as the finger moves on): set outright for every move, it went in little steps.
    func zoom(to factor: CGFloat, glide: Bool = false) {
        guard let d = device else { return }
        let f = min(max(factor, d.minAvailableVideoZoomFactor), min(d.maxAvailableVideoZoomFactor, mainFactor * 10))
        guard abs(f - zoomFactor) > 0.001 else { return }
        zoomFactor = f; shownZoom = f / mainFactor
        queue.async {
            guard (try? d.lockForConfiguration()) != nil else { return }
            if glide { d.ramp(toVideoZoomFactor: f, withRate: 12) } else { if d.isRampingVideoZoom { d.cancelVideoZoomRamp() }; d.videoZoomFactor = f }
            d.unlockForConfiguration()
        }
    }
    func zoom(shown z: CGFloat) { zoom(to: z * mainFactor) }

    func takePhoto() {
        let settings = AVCapturePhotoSettings()
        if photos.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        photos.capturePhoto(with: settings, delegate: self)
    }

    func startMovie() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        if flash == .on, let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil { d.torchMode = .on; d.unlockForConfiguration() }
        movies.startRecording(to: url, recordingDelegate: self)
    }
    func stopMovie() {
        if movies.isRecording { movies.stopRecording() }
        if let d = device, d.hasTorch, d.torchMode == .on, (try? d.lockForConfiguration()) != nil { d.torchMode = .off; d.unlockForConfiguration() }
    }

    /// The newest photo or video in the library, for the corner button (only when Photos is allowed).
    private func loadLatest() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let opts = PHFetchOptions(); opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; opts.fetchLimit = 1
        guard let a = PHAsset.fetchAssets(with: opts).firstObject else { return }
        latest = await withCheckedContinuation { c in
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true; o.isSynchronous = false
            var done = false
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 120, height: 120), contentMode: .aspectFill, options: o) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if !done { done = true; c.resume(returning: img) }
            }
        }
    }
}

extension CameraRig: AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let d = photo.fileDataRepresentation(), let full = UIImage(data: d) else { return }
        // a 12-megapixel photo drawn on screen held the editor black; 1920 on the long side is plenty
        let long = max(full.size.width, full.size.height), k = min(1, 1920 / long)
        let img = k < 1 ? (full.preparingThumbnail(of: CGSize(width: full.size.width * k, height: full.size.height * k)) ?? full) : full
        Task { @MainActor in self.photo = img }
    }
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.finishedMovie = url }
    }
}

/// The live camera picture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Layered: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Layered {
        let v = Layered(); v.preview.session = session; v.preview.videoGravity = .resizeAspectFill; v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: Layered, context: Context) {}
}

/// Your recent photos and videos (videos with their length): tap one to edit it.
struct RecentMedia: View {
    var chose: (UIImage?, URL?) -> Void
    var more: () -> Void
    @State private var assets: [PHAsset] = []
    @State private var allowed = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recents").font(.headline)
                Spacer()
                Button("All photos") { more() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.top, 16)
            if !allowed {
                Text("Cheat Days can't see your photos. Tap All photos to pick one.").font(.subheadline).foregroundStyle(.secondary).padding(16)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(assets, id: \.localIdentifier) { a in
                        Button { pick(a) } label: { AssetThumb(asset: a) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay { if busy { ProgressView().controlSize(.large) } }
        .task {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { allowed = false; return }
            let opts = PHFetchOptions(); opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]; opts.fetchLimit = 90
            opts.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            let r = PHAsset.fetchAssets(with: opts)
            var out: [PHAsset] = []; r.enumerateObjects { a, _, _ in out.append(a) }
            assets = out
        }
    }

    private func pick(_ a: PHAsset) {
        busy = true
        if a.mediaType == .video {
            let o = PHVideoRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: a, options: o) { av, _, _ in
                guard let u = (av as? AVURLAsset)?.url else { DispatchQueue.main.async { busy = false }; return }
                // copied, so the editor can read and trim it after Photos lets go
                let to = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + u.pathExtension)
                try? FileManager.default.copyItem(at: u, to: to)
                DispatchQueue.main.async { busy = false; chose(nil, to) }
            }
        } else {
            let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 1440, height: 2560), contentMode: .aspectFit, options: o) { img, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                DispatchQueue.main.async { busy = false; chose(img, nil) }
            }
        }
    }
}

struct AssetThumb: View {
    let asset: PHAsset
    @State private var img: UIImage?
    var body: some View {
        Color(white: 0.15).aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay { if let img { Image(uiImage: img).resizable().scaledToFill().allowsHitTesting(false) } }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Text(String(format: "%d:%02d", Int(asset.duration) / 60, Int(asset.duration) % 60)).font(.caption2.weight(.heavy)).foregroundStyle(.white).shadow(radius: 2).padding(5)
                }
            }
            .task {
                let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 420), contentMode: .aspectFill, options: o) { i, _ in
                    DispatchQueue.main.async { if let i { img = i } }
                }
            }
    }
}
