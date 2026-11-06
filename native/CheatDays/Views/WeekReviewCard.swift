import SwiftUI

/// The week review on Today: a coloured status label over a one-line headline, a tick or a warning for each goal
/// with its numbers, and what to keep or the one thing to change in a shaded box, with a link to ideas for that meal.
struct WeekReviewCard: View {
    let review: WeekReview
    var hide: () -> Void = {}
    var plan: (String) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var type

    var body: some View {
        let r = review, good = r.rows.allSatisfy(\.ok), big = type.isAccessibilitySize, tint = good ? Theme.walk : Theme.warn
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // the dot sits on the first line; at the biggest sizes "last 7 days" gets its own line, so no "·" dangles
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    (Text(r.status).foregroundColor(tint) + Text(big ? "\nlast 7 days" : " · last 7 days").foregroundColor(.secondary))
                        .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(0.6)
                }
                Text(r.title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
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
            // closing it sits at the foot, out of the headline's way
            HStack {
                Spacer()
                Button(action: hide) { Text("Hide for today").font(.footnote.weight(.medium)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        // the same grey as the meal rows under it; the icon's circle and the ticks carry the green or amber
        .listRowBackground(Color(.secondarySystemGroupedBackground))
        .accessibilityIdentifier("weekReview")
    }
}
