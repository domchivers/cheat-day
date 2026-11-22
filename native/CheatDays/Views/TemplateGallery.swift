import SwiftUI

/// The templates to pick from, each playing with the edit's own clips and the log's words
/// (design/templates-pro-mockup.html, 1).
struct TemplateGallery: View {
    let clips: [Clip]
    let log: EditTemplate.Log
    let pick: (EditTemplate) -> Void
    let close: () -> Void
    @State private var reels: [[CGImage]] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                cards
                Text("Playing with the clips in your edit and the words from your log.")
                    .font(.system(size: 11.5)).foregroundStyle(ProInk.quiet).multilineTextAlignment(.center)
                    .padding(16)
            }
        }
        .foregroundStyle(Color.white)
        .task(id: clips.map { (c: Clip) -> UUID in c.id }) { await load() }
    }

    private var header: some View {
        HStack {
            Text("Templates").font(.system(size: 16, weight: .bold))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Close")
        }
        .padding(.leading, 20).padding(.trailing, 6)
        .frame(height: 52)
    }

    private var cards: some View {
        let columns: [GridItem] = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(EditTemplate.all.indices, id: \.self) { (n: Int) in
                let t: EditTemplate = EditTemplate.all[n]
                TemplateCard(template: t, slots: t.slots(log, recipe: nil), reels: reels, offset: n, pick: { pick(t) })
            }
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }

    private func load() async {
        var made: [[CGImage]] = []
        for c in clips.prefix(TemplateReel.most) {
            let frames: [CGImage] = await TemplateReel.frames(c)
            guard !Task.isCancelled else { return }
            if !frames.isEmpty {
                made.append(frames)
                reels = made   // (each shows as it's ready)
            }
        }
    }
}

private struct TemplateCard: View {
    let template: EditTemplate
    let slots: [EditTemplate.Slot]
    let reels: [[CGImage]]
    let offset: Int
    let pick: () -> Void
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        let count: Int = slots.count
        let runs: Int = Int(TemplateReel.length(slots).rounded())
        let sub: String = "\(count) clip\(count == 1 ? "" : "s") · \(EditFlow.clock(Double(runs)))"
        return Button(action: pick) {
            VStack(alignment: .leading, spacing: 0) {
                playing
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(template.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).padding(.top, 6)
                Text(sub).font(.system(size: 11)).foregroundStyle(ProInk.quiet)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(template.name), \(sub). \(template.about)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick() }
    }

    private var playing: some View {
        TimelineView(.animation(minimumInterval: 1 / TemplateReel.rate, paused: still)) { context in
            shot(at: still ? 0.2 : context.date.timeIntervalSinceReferenceDate)
        }
    }

    private func shot(at seconds: Double) -> some View {
        let now: (slot: Int, into: Double, through: Double) = TemplateReel.at(seconds, slots: slots)
        let image: CGImage? = picture(slot: now.slot, into: now.into)
        let slot: EditTemplate.Slot? = slots.indices.contains(now.slot) ? slots[now.slot] : nil
        return ZStack(alignment: .top) {
            ProInk.tile
            if let image {
                FillPicture(image: image)
            } else {
                Image(systemName: template.icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(ProInk.quiet)
                    .frame(maxHeight: .infinity)
            }
            if let slot, !slot.name.isEmpty || !slot.detail.isEmpty { words(slot).padding(.top, 18) }
        }
        .overlay(alignment: .bottom) { through(now.through) }
    }

    private func picture(slot: Int, into: Double) -> CGImage? {
        guard !reels.isEmpty else { return nil }
        let reel: [CGImage] = reels[(slot + offset) % reels.count]
        guard !reel.isEmpty else { return nil }
        return reel[min(reel.count - 1, max(0, Int(into * TemplateReel.rate)))]
    }

    private func words(_ slot: EditTemplate.Slot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !slot.name.isEmpty { Text(slot.name).font(.system(size: 11, weight: .heavy)) }
            if !slot.detail.isEmpty { Text(slot.detail).font(.system(size: 9, weight: .semibold)).opacity(0.9) }
        }
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 8)
    }

    private func through(_ part: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.27))
                Capsule().fill(Color.white).frame(width: g.size.width * CGFloat(min(1, max(0, part))))
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 8).padding(.bottom, 6)
    }
}
