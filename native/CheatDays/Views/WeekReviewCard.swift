import SwiftUI

/// The week review on Today: a coloured status label over a one-line headline, a tick or a warning for each goal
/// with its numbers, and what to keep or the one thing to change in a shaded box, with a link to ideas for that meal.
struct WeekReviewCard: View {
    let review: WeekReview
    var hide: () -> Void = {}
    var plan: (String) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var type
    @State private var why = false   // the full story opened

    var body: some View {
        let r = review, good = r.rows.allSatisfy(\.ok), big = type.isAccessibilitySize, tint = good ? Theme.walk : Theme.warn
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // the dot is a symbol inside the text, so it grows and lines up with the words at every size; at the
                // biggest sizes "last 7 days" gets its own line, so no "·" dangles
                (Text(Image(systemName: "circle.fill")).font(.caption2).foregroundColor(tint) + Text(" ")
                 + Text(r.status).foregroundColor(tint) + Text(big ? "\nlast 7 days" : " · last 7 days").foregroundColor(.secondary))
                    .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                Text(r.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if !big {
                // at a glance (21 Nov, design/today-cards-mockup.html, 2): each goal as one number, its colour saying
                // whether it's on track
                HStack(spacing: 6) {
                    ForEach(r.rows, id: \.label) { row in
                        VStack(spacing: 1) {
                            Text(Self.short(row.value)).font(.subheadline.weight(.heavy)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(row.ok ? Theme.walk : Theme.warn)
                            Text(Self.caption(row)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(r.line.isEmpty ? r.tip : r.line).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            if big || why {
            VStack(spacing: 8) {
                ForEach(r.rows, id: \.label) { row in
                    HStack(alignment: big ? .firstTextBaseline : .center, spacing: 10) {
                        Image(systemName: row.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.body).foregroundStyle(row.ok ? Theme.walk : Theme.warn)
                        // at the biggest text sizes the value goes under its label, so neither wraps in a narrow column
                        if big {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label).font(.subheadline.weight(.semibold))
                                Text(row.value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary.opacity(0.75))
                                if let n = row.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label).font(.subheadline.weight(.semibold))
                                // what the weight is judged against, so a warning says why
                                if let n = row.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 8)
                            Text(row.value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary.opacity(0.75))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(r.tip).font(.footnote).fixedSize(horizontal: false, vertical: true)
                if let meal = r.plan {
                    Button { plan(meal) } label: { Text("Ideas for \(meal.lowercased()) ›").font(.footnote.weight(.semibold)) }
                        .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // closing it sits at the foot, out of the headline's way, on the left: on the right the floating + sat
            // on top of it whenever the card was at the bottom of the screen
            HStack {
                if !big {
                    Button { withAnimation(.snappy(duration: 0.22)) { why.toggle() } } label: {
                        Text(why ? "Less" : "Why ›").font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accent).padding(.trailing, 14)
                }
                Button(action: hide) { Text("Hide for today").font(.footnote.weight(.medium)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                Spacer()   // (both on the left: the floating + sits over the right)
            }
        }
        .padding(.vertical, 6)
        // the same grey as the meal rows under it; the icon's circle and the ticks carry the green or amber
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        .accessibilityIdentifier("weekReview")
    }

    /// A row's value as one number: "7 of 7 days" is 7/7, "−0.4 kg a week" is −0.4 kg.
    static func short(_ v: String) -> String {
        if v.hasSuffix(" days") { return v.replacingOccurrences(of: " days", with: "").replacingOccurrences(of: " of ", with: "/") }
        if v.hasSuffix(" a week") { return String(v.dropLast(" a week".count)) }
        return v
    }

    /// What the number is.
    static func caption(_ row: WeekReview.Row) -> String {
        switch row.label {
        case "Within budget": return "in budget"
        case "Protein goal hit": return "protein"
        case "Weight": return "a week"
        default: return row.label.lowercased()
        }
    }
}
