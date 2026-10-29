import SwiftUI
import UIKit

/// The show-me tour: dims the app and lights up one real thing at a time, with a note pointing at it.
/// Things on Today report where they are on screen (`.tourSpot`); the tab buttons are found in the tab bar itself,
/// so every outline sits exactly on what it circles, whatever the phone.
@MainActor @Observable final class Tour {
    static let shared = Tour()

    enum Spot: String { case hero, plan, add, meal, workouts, me }
    enum Shape { case card(CGFloat), capsule, circle }
    struct Step { let spot: Spot; let shape: Shape; let pad: CGFloat; let title: String; let text: String }

    static let steps: [Step] = [
        Step(spot: .hero, shape: .card(26), pad: 0, title: "What's left today",
             text: "Your calories left to eat. Tap the arrow to see protein, carbs and fat."),
        Step(spot: .plan, shape: .capsule, pad: 4, title: "Plan your next meal",
             text: "Tap Plan and tell it what's in the fridge. It suggests meals that fit what you've got left today. On your cheat day it plans the whole day."),
        Step(spot: .add, shape: .circle, pad: 5, title: "Add food",
             text: "Tap + to search, scan a barcode, snap a photo or just tell the assistant what you had."),
        Step(spot: .meal, shape: .capsule, pad: 8, title: "Straight into a meal",
             text: "Or add to a meal here. Tap a food afterwards to change the amount; swipe left to remove it."),
        Step(spot: .workouts, shape: .capsule, pad: 2, title: "Workouts",
             text: "Start a routine and tick sets as you go. The rest timer runs on its own."),
        Step(spot: .me, shape: .capsule, pad: 2, title: "Me",
             text: "Your weight, rank and Settings. You can watch this tour again from Settings.")
    ]

    var frames: [Spot: CGRect] = [:]
    /// The step showing; nil when the tour's off.
    var index: Int?
    /// Set on signing in (and by Settings' replay); the tour starts once nothing else is on screen.
    var pending = UserDefaults.standard.bool(forKey: "tour.pending") {
        didSet { UserDefaults.standard.set(pending, forKey: "tour.pending") }
    }
    var active: Bool { index != nil }

    /// Off to Today, scrolled to the top, then the first step there's something to point at.
    func startIfPending() {
        guard pending, index == nil else { return }
        pending = false
        NotificationCenter.default.post(name: .openTab, object: 0)
        NotificationCenter.default.post(name: .tourScrollTop, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.index = self.firstShowable(from: 0) }
    }

    func next() {
        guard let i = index else { return }
        withAnimation(.snappy) { index = firstShowable(from: i + 1) }
    }

    func stop() { withAnimation(.snappy) { index = nil } }

    /// Where a step's thing is right now, or nil if it isn't fully on screen (then the step is skipped).
    func rect(for step: Step) -> CGRect? {
        let r: CGRect?
        switch step.spot {
        case .workouts: r = Self.tabFrame("Workouts", at: 1)
        case .me: r = Self.tabFrame("Me", at: 3)
        default: r = frames[step.spot]
        }
        guard let r, r.width > 0, r.minY >= 0, r.maxY <= UIScreen.main.bounds.height else { return nil }
        return r
    }

    private func firstShowable(from start: Int) -> Int? {
        (start..<Self.steps.count).first { rect(for: Self.steps[$0]) != nil }
    }

    /// A tab's button in the tab bar, read from the tab bar's own views; if that can't be found, its share of the bar.
    static func tabFrame(_ title: String, at position: Int) -> CGRect? {
        guard let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        let bottom = win.bounds.height - 160
        func visible(_ v: UIView) -> Bool { !v.isHidden && v.alpha > 0.01 }
        func find(_ v: UIView, _ match: (UIView) -> Bool) -> UIView? {
            guard visible(v) else { return nil }
            if match(v), v.convert(v.bounds, to: nil).minY > bottom { return v }
            for s in v.subviews { if let f = find(s, match) { return f } }
            return nil
        }
        // the button itself, by its accessibility name
        if let b = find(win, { $0.accessibilityLabel == title && $0.bounds.width >= 40 && $0.bounds.width <= 160 }) {
            return b.convert(b.bounds, to: nil)
        }
        // the title label, then up to the control holding it
        if let label = find(win, { ($0 as? UILabel)?.text == title }) {
            var v: UIView? = label
            while let c = v, !(c is UIControl), c.superview != nil, c.bounds.width < 50 || c.bounds.height < 40 { v = c.superview }
            if let c = v { return c.convert(c.bounds, to: nil) }
        }
        if let bar = find(win, { $0 is UITabBar }) {
            let f = bar.convert(bar.bounds, to: nil), w = f.width / 4
            return CGRect(x: f.minX + w * CGFloat(position), y: f.minY, width: w, height: min(f.height, 60))
        }
        return nil
    }
}

extension Notification.Name { static let tourScrollTop = Notification.Name("tourScrollTop") }

extension View {
    /// Tells the tour where this is on screen.
    func tourSpot(_ s: Tour.Spot) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Tour.shared.frames[s] = $0 }
    }
}

/// `.tourSpot` on just one of several alike rows (the first meal's Add).
struct TourSpotIf: ViewModifier {
    let spot: Tour.Spot
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.tourSpot(spot) } else { content }
    }
}

/// The dimmed screen with the lit-up hole, its outline, and the note. Tap anywhere for the next one.
struct TourOverlay: View {
    private var tour: Tour { Tour.shared }

    var body: some View {
        if let i = tour.index, let r = tour.rect(for: Tour.steps[i]) {
            let step = Tour.steps[i]
            let hole = r.insetBy(dx: -step.pad, dy: -step.pad)
            GeometryReader { g in
                let below = hole.midY < g.size.height / 2
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.72)
                        .mask {
                            Rectangle().overlay(alignment: .topLeading) {
                                shape(step.shape, hole).fill(.black).blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }
                    shape(step.shape, hole).stroke(Theme.accent, lineWidth: 2)
                    shape(step.shape, hole.insetBy(dx: -5, dy: -5)).stroke(Theme.accent.opacity(0.25), lineWidth: 5)
                    // the note sits under the thing if it's in the top half, over it if not, with its arrow pointing at it
                    let reach = (g.size.width - 32) / 2 - 26
                    VStack(spacing: 0) {
                        if below { Color.clear.frame(height: hole.maxY + 16) } else { Spacer(minLength: 0) }
                        note(step, i)
                            .background(alignment: below ? .top : .bottom) {
                                Rectangle().fill(Color(white: 0.96)).frame(width: 14, height: 14).rotationEffect(.degrees(45))
                                    .offset(x: min(max(hole.midX - g.size.width / 2, -reach), reach), y: below ? -6 : 6)
                            }
                        if below { Spacer(minLength: 0) } else { Color.clear.frame(height: g.size.height - hole.minY + 16) }
                    }
                    .padding(.horizontal, 16)
                    .frame(width: g.size.width, height: g.size.height)
                }
                .contentShape(Rectangle())
                .onTapGesture { tour.next() }
            }
            .ignoresSafeArea()
            .transition(.opacity)
            .sensoryFeedback(.selection, trigger: i)
        }
    }

    private func shape(_ s: Tour.Shape, _ r: CGRect) -> Path {
        switch s {
        case .card(let c): return Path(roundedRect: r, cornerRadius: c + 2, style: .continuous)
        case .capsule: return Path(roundedRect: r, cornerRadius: r.height / 2, style: .continuous)
        case .circle: return Path(ellipseIn: r)
        }
    }

    private func note(_ step: Tour.Step, _ i: Int) -> some View {
        let last = i == Tour.steps.count - 1
        return VStack(alignment: .leading, spacing: 4) {
            Text(step.title).font(.headline)
            Text(step.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(i + 1) of \(Tour.steps.count)").font(.footnote).foregroundStyle(.black.opacity(0.5))
                Spacer()
                if !last { Button("Skip") { tour.stop() }.font(.subheadline).foregroundStyle(.black.opacity(0.55)).padding(.trailing, 10) }
                Button { tour.next() } label: {
                    Text(last ? "Done" : "Next").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color(red: 0.04, green: 0.08, blue: 0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .buttonStyle(.plain).padding(.top, 8)
        }
        .foregroundStyle(Color(red: 0.04, green: 0.08, blue: 0.13))
        .padding(14)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }
}
