import AVFoundation
import SwiftUI

/// Some of what was picked couldn't be added (22 Nov audit: they were left out without a word): which, and what to do.
struct ImportFailure: Identifiable {
    let id = UUID()
    var total: Int
    var failed: [Int]
    /// All of it again, so what's picked keeps its order.
    var retry: () -> Void
    /// On with the rest; nil when there's no rest.
    var carryOn: (() -> Void)?

    var message: String { Self.message(failed: failed, of: total) }

    static func message(failed: [Int], of total: Int) -> String {
        if total == 1 { return "It couldn't be added. If it's in iCloud, check your connection and try again." }
        let which: String = failed.map { (i: Int) -> String in ordinal(i + 1) }.joined(separator: ", ")
        return "\(failed.count) of \(total) couldn't be added (\(which)). If they're in iCloud, check your connection and try again."
    }

    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

private struct ImportFailedAlert: ViewModifier {
    @Binding var failure: ImportFailure?

    func body(content: Content) -> some View {
        let showing = Binding<Bool>(get: { failure != nil }, set: { (on: Bool) in if !on { failure = nil } })
        return content.alert("Couldn't add everything", isPresented: showing, presenting: failure) { (f: ImportFailure) in
            Button("Try again") { f.retry() }
            if let carryOn = f.carryOn {
                Button("Add the other \(f.total - f.failed.count)") { carryOn() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { (f: ImportFailure) in
            Text(f.message)
        }
    }
}

extension View {
    func importFailed(_ failure: Binding<ImportFailure?>) -> some View { modifier(ImportFailedAlert(failure: failure)) }
}

/// A video file's shape as it plays, the right way up: width over height.
enum VideoShape {
    static let tall: CGFloat = 9.0 / 16.0

    static func of(_ url: URL) async -> CGFloat {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let turn = try? await track.load(.preferredTransform) else { return tall }
        return upright(size, turn: turn)
    }

    static func upright(_ size: CGSize, turn: CGAffineTransform) -> CGFloat {
        let box: CGRect = CGRect(origin: .zero, size: size).applying(turn)
        guard box.width > 0, box.height > 0 else { return tall }
        return box.width / box.height
    }
}
