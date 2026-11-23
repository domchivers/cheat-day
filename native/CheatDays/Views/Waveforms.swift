import Observation
import SwiftUI

/// The files' waves, each read once while the editor's open.
@MainActor
@Observable
final class Waveforms {
    private(set) var files: [URL: WaveFile] = [:]
    @ObservationIgnored private var reading: Set<URL> = []
    @ObservationIgnored private var last: Task<WaveFile, Never>?

    func load(_ url: URL) async {
        guard files[url] == nil, !reading.contains(url) else { return }
        reading.insert(url)
        // (one after another: all at once, they held up the preview's own sound)
        let before: Task<WaveFile, Never>? = last
        let job: Task<WaveFile, Never> = Task.detached(priority: .utility) { () -> WaveFile in
            _ = await before?.value
            return await WaveFile.read(url)
        }
        last = job
        let made: WaveFile = await job.value
        reading.remove(url)
        files[url] = made
    }
}

/// A long wave a piece at a time: one canvas thousands of points wide is too big a picture to draw.
private enum WaveTiles {
    static let width: CGFloat = 600

    static func count(_ whole: CGFloat) -> Int { max(1, Int((whole / width).rounded(.up))) }
    static func wide(_ k: Int, of whole: CGFloat) -> CGFloat { max(0, min(width, whole - CGFloat(k) * width)) }

    /// More than a screen's width either side of the line.
    static let near: CGFloat = 1000

    /// The pieces near the line, which is so far along the wave.
    static func shown(line: CGFloat, of whole: CGFloat) -> [Int] {
        let last: Int = count(whole) - 1
        guard line + near >= 0, line - near <= whole else { return [] }
        let low: Int = max(0, min(last, Int((line - near) / width)))
        let high: Int = max(low, min(last, Int((line + near) / width)))
        return Array(low...high)
    }
}

/// The pieces of a long wave that are by the line, put where they go.
private struct WaveRun<Piece: View>: View {
    let clock: EditPlayhead
    let from: Double
    let width: CGFloat
    let height: CGFloat
    let pps: CGFloat
    @ViewBuilder let piece: (Int) -> Piece

    var body: some View {
        let shown: [Int] = WaveTiles.shown(line: CGFloat(clock.time - from) * pps, of: width)
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(shown, id: \.self) { (k: Int) in
                piece(k)
                    .frame(width: WaveTiles.wide(k, of: width), height: height)
                    .offset(x: CGFloat(k) * WaveTiles.width)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// A clip's wave under its frames: as loud as it'll be heard, flat grey with its sound off, faded under a voiceover.
/// (Values only, no closures: the same again, it isn't drawn again.)
struct ClipWave: View {
    let clip: Clip
    let file: WaveFile?
    let heard: Bool
    let width: CGFloat
    let height: CGFloat
    let pps: CGFloat
    /// Where a voiceover plays over it, seconds along it.
    let under: [ClosedRange<Double>]
    let clock: EditPlayhead
    /// Where the clip starts in the video.
    let from: Double

    private static let green = Color(red: 0.24, green: 0.86, blue: 0.52)

    var body: some View {
        let colour: Color = heard ? Self.green : Color.white.opacity(0.25)
        return WaveRun(clock: clock, from: from, width: width, height: height, pps: pps) { (k: Int) in
            ClipWaveTile(clip: clip, file: file, heard: heard, pps: pps, left: CGFloat(k) * WaveTiles.width, colour: colour)
        }
        .background(colour.opacity(0.12))
        .overlay(alignment: .leading) { shade }
        .allowsHitTesting(false)
    }

    private var shade: some View {
        ZStack(alignment: .leading) {
            ForEach(under.indices, id: \.self) { (i: Int) in
                Rectangle().fill(Color(red: 0.067, green: 0.067, blue: 0.075).opacity(0.6))
                    .frame(width: max(0, CGFloat(under[i].upperBound - under[i].lowerBound) * pps), height: height)
                    .offset(x: CGFloat(under[i].lowerBound) * pps)
            }
        }
    }
}

private struct ClipWaveTile: View {
    let clip: Clip
    let file: WaveFile?
    let heard: Bool
    let pps: CGFloat
    let left: CGFloat
    let colour: Color

    var body: some View {
        Canvas { (ctx: inout GraphicsContext, size: CGSize) in
            var path = Path()
            let start: Double = clip.start + Double(left / max(pps, 1)) * clip.speed
            let bars: [WaveMath.Bar] = WaveMath.bars(width: Double(size.width), pps: Double(pps), fileStart: start, speed: clip.speed)
            for bar in bars {
                var level: Float = 0
                if heard, let file, bar.low >= clip.heardStart - 0.02, bar.low < clip.heardEnd {
                    level = file.peak(from: bar.low, to: bar.high) * clip.level(at: bar.low)
                }
                let tall: CGFloat = max(1, size.height * CGFloat(min(1, level)))
                path.move(to: CGPoint(x: CGFloat(bar.x) + 0.7, y: (size.height - tall) / 2))
                path.addLine(to: CGPoint(x: CGFloat(bar.x) + 0.7, y: (size.height + tall) / 2))
            }
            ctx.stroke(path, with: .color(colour), lineWidth: 1.4)
        }
    }
}

/// A sound's wave in its bar: as loud as it'll be, its keyframes' line over it, and where music goes round again.
struct SoundBarWave: View {
    let sound: EditSound
    let file: WaveFile?
    let width: CGFloat
    let height: CGFloat
    let pps: CGFloat
    let ink: Color
    let clock: EditPlayhead

    var body: some View {
        WaveRun(clock: clock, from: sound.from, width: width, height: height, pps: pps) { (k: Int) in
            SoundWaveTile(sound: sound, file: file, pps: pps, left: CGFloat(k) * WaveTiles.width, ink: ink)
        }
        .overlay(alignment: .topLeading) { marks }
        .allowsHitTesting(false)
    }

    private var marks: some View {
        let keys: [VolumeKey] = (sound.keys ?? []).sorted { (a: VolumeKey, b: VolumeKey) -> Bool in a.at < b.at }
        let rounds: [Double] = WaveMath.rounds(sound)
        return ZStack(alignment: .topLeading) {
            ForEach(rounds.indices, id: \.self) { (i: Int) in
                again.offset(x: CGFloat(rounds[i]) * pps)
            }
            if !keys.isEmpty { keyLine(keys) }
            ForEach(keys.indices, id: \.self) { (i: Int) in
                Rectangle().fill(Color(red: 1, green: 0.816, blue: 0.231)).frame(width: 6, height: 6).rotationEffect(.degrees(45))
                    .position(place(keys[i]))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
    }

    private var again: some View {
        HStack(spacing: 2) {
            Rectangle().fill(Color.white).frame(width: 1, height: height)
            Image(systemName: "repeat").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
        }
    }

    private func place(_ key: VolumeKey) -> CGPoint {
        let x: CGFloat = CGFloat(sound.videoTime(key.at) - sound.from) * pps
        let y: CGFloat = 4 + (height - 8) * CGFloat(1 - min(1, max(0, key.volume)))
        return CGPoint(x: x, y: y)
    }

    private func keyLine(_ keys: [VolumeKey]) -> some View {
        Path { (p: inout Path) in
            guard let first = keys.first, let last = keys.last else { return }
            p.move(to: CGPoint(x: 0, y: place(first).y))
            for key in keys { p.addLine(to: place(key)) }
            p.addLine(to: CGPoint(x: width, y: place(last).y))
        }
        .stroke(Color.white.opacity(0.9), lineWidth: 1.2)
    }
}

private struct SoundWaveTile: View {
    let sound: EditSound
    let file: WaveFile?
    let pps: CGFloat
    let left: CGFloat
    let ink: Color

    var body: some View {
        Canvas { (ctx: inout GraphicsContext, size: CGSize) in
            guard let file else { return }
            let points: Double = Double(max(pps, 1))
            let low: Double = Double(left) / points, high: Double = Double(left + size.width) / points
            var path = Path()
            let parts: [EditSound.Stretch] = sound.stretches(until: sound.to)
            for part in parts {
                let a: Double = max(low, part.from - sound.from)
                let b: Double = min(high, part.from - sound.from + part.length)
                guard b > a else { continue }
                let start: Double = part.fileStart + (a - (part.from - sound.from)) * sound.speed
                let bars: [WaveMath.Bar] = WaveMath.bars(width: (b - a) * points, pps: points, fileStart: start, speed: sound.speed)
                for bar in bars {
                    let x: Double = (a - low) * points + bar.x
                    let at: Double = sound.from + low + x / points
                    let level: Float = file.peak(from: bar.low, to: bar.high) * sound.level(at: at)
                    let tall: CGFloat = max(1, (size.height - 8) * CGFloat(min(1, level)))
                    path.move(to: CGPoint(x: CGFloat(x) + 0.7, y: (size.height - tall) / 2))
                    path.addLine(to: CGPoint(x: CGFloat(x) + 0.7, y: (size.height + tall) / 2))
                }
            }
            ctx.stroke(path, with: .color(ink), lineWidth: 1.4)
        }
    }
}

/// A bar's name, kept in view as its start slides off the screen.
struct PinnedName: View {
    let name: String
    let width: CGFloat
    /// White on the bar itself, no tag (a voice's, 23 Nov).
    var plain = false

    var body: some View {
        let most: CGFloat = max(0, width - 56)
        return Text(name).font(.system(size: plain ? 10 : 8.5, weight: plain ? .bold : .semibold)).lineLimit(1)
            .foregroundStyle(plain ? Color.white : Color.black.opacity(0.82))
            .shadow(color: plain ? Color.black.opacity(0.3) : Color.clear, radius: 1, y: 0.5)
            .padding(.horizontal, plain ? 5 : 3)
            .background(plain ? Color.clear : Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .frame(maxWidth: max(0, width - 4), alignment: .leading)
            .padding(.leading, 2).padding(.top, plain ? 1 : 2)
            .visualEffect { content, proxy in
                // (the timeline's edge to edge: the screen's left is its left)
                content.offset(x: min(most, max(0, -proxy.frame(in: .global).minX)))
            }
            .allowsHitTesting(false)
    }
}

/// What a handle's held on: a yellow mark at each pause, solid at the one it's on.
struct PauseMarks: View {
    let places: [CGFloat]
    let held: CGFloat?
    let height: CGFloat

    var body: some View {
        let dashed = StrokeStyle(lineWidth: 2, dash: [4, 3])
        let yellow = Color(red: 1, green: 0.816, blue: 0.231)
        let tall: CGFloat = height
        return ZStack(alignment: .topLeading) {
            Path { (p: inout Path) in
                for x in places {
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: tall))
                }
            }
            .stroke(yellow, style: dashed)
            if let held {
                Rectangle().fill(yellow).frame(width: 3, height: tall).offset(x: held - 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The words a handle's held between, and how long what's left is.
struct PauseBubble: View {
    let before: String
    let after: String
    let seconds: Double

    var body: some View {
        HStack(spacing: 5) {
            if before.isEmpty && after.isEmpty {
                Text("Pause")
            } else {
                if !before.isEmpty { Text(before) }
                Text("|").foregroundStyle(Color(red: 0.78, green: 0.58, blue: 0))
                if !after.isEmpty { Text(after) }
            }
            Text(String(format: "%.1f s", max(0, seconds))).fontWeight(.medium).foregroundStyle(Color(white: 0.4)).padding(.leading, 3)
        }
        .font(.system(size: 12, weight: .bold)).lineLimit(1)
        .foregroundStyle(Color.black)
        .padding(.horizontal, 9).frame(height: 26)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }
}
