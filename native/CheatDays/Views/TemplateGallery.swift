import SwiftUI

/// The templates to pick from, each shown as what it's for in the app's own art, with the log's words
/// (design/template-cards-mockup.html, A; 23 Nov: the edit's own footage behind them was blurry, and made no sense
/// when it wasn't of what was logged). The edit's clips play once one's picked.
struct TemplateGallery: View {
    let log: EditTemplate.Log
    let pick: (EditTemplate) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                cards
                Text("The words from your log. Tap one to see it with your clips.")
                    .font(.system(size: 11.5)).foregroundStyle(ProInk.quiet).multilineTextAlignment(.center)
                    .padding(16)
            }
        }
        .foregroundStyle(Color.white)
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
            ForEach(EditTemplate.all) { (t: EditTemplate) in
                TemplateCard(template: t, slots: t.slots(log, recipe: nil), foods: t.foods(for: log),
                             bars: t.bars(for: log), pick: { pick(t) })
            }
        }
        .padding(.horizontal, 16).padding(.top, 4)
    }
}

private struct TemplateCard: View {
    let template: EditTemplate
    let slots: [EditTemplate.Slot]
    /// The food each slot's of, where it's of one.
    let foods: [String]
    /// The week's days, each as a part of the biggest.
    let bars: [Double]
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
        let slot: EditTemplate.Slot? = slots.indices.contains(now.slot) ? slots[now.slot] : nil
        return ZStack(alignment: .top) {
            tinted
            art(now.slot).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 34)
            if let slot, !slot.name.isEmpty || !slot.detail.isEmpty { words(slot).padding(.top, 18) }
        }
        .overlay(alignment: .bottom) { purpose }
        .overlay(alignment: .bottom) { through(now.through) }
    }

    private var tinted: some View {
        let colours: [Color] = [StoryArt.color(template.tint.0), StoryArt.color(template.tint.1)]
        return LinearGradient(colors: colours, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Color.black.opacity(0.4))
    }

    private var purpose: some View {
        Text(template.purpose).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(Color.white.opacity(0.8))
            .padding(.horizontal, 8).padding(.bottom, 15)
    }

    @ViewBuilder private func art(_ slot: Int) -> some View {
        switch template.id {
        case "gym":
            Image("sticker-1f3cb").resizable().interpolation(.high).scaledToFit().frame(width: 76, height: 76)
        case "recipe":
            FluentIcon(emoji: "🍳", size: 76)
        case "before":
            halves(slot)
        case "week":
            week(slot)
        default:
            if foods.indices.contains(slot) && !foods[slot].isEmpty {
                FoodDot(name: foods[slot], size: 76)
            } else {
                Image(systemName: template.icon).font(.system(size: 50, weight: .semibold))
            }
        }
    }

    private func halves(_ slot: Int) -> some View {
        HStack(spacing: 3) {
            half("Then", on: slot == 0)
            half("Now", on: slot == 1)
        }
        .padding(.horizontal, 20)
    }

    private func half(_ name: String, on: Bool) -> some View {
        let fill: Color = on ? Color.white.opacity(0.22) : Color.black.opacity(0.25)
        return Text(name).font(.system(size: 14, weight: .heavy))
            .frame(maxWidth: .infinity).frame(height: 72)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func week(_ slot: Int) -> some View {
        HStack(alignment: .bottom, spacing: 7) {
            ForEach(slots.indices, id: \.self) { (i: Int) in day(i, on: i == slot) }
        }
        .frame(height: 72, alignment: .bottom)
    }

    private func day(_ i: Int, on: Bool) -> some View {
        let part: Double = bars.indices.contains(i) ? bars[i] : 0.6
        let ink: Color = on ? Color.white : Color.white.opacity(0.27)
        return VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink).frame(width: 13, height: max(6, 54 * CGFloat(part)))
            Text(String(slots[i].name.prefix(1))).font(.system(size: 10)).foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
        }
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
