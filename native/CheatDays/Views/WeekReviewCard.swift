import SwiftUI

/// The week review on Today: the headline in a tinted circle, a tick or a warning for each goal with its numbers,
/// and what to keep or the one thing to change in a shaded box, with a link to ideas for that meal.
struct WeekReviewCard: View {
    let review: WeekReview
    var hide: () -> Void = {}
    var plan: (String) -> Void = { _ in }

    var body: some View {
        let r = review, good = r.rows.allSatisfy(\.ok)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                FluentIcon(emoji: r.icon, size: 20)
                    .frame(width: 36, height: 36)
                    .background((good ? Theme.walk : Theme.warn).opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.headline).lineLimit(2)
                    Text("Your last 7 days").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: hide) {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).tint(.secondary).accessibilityLabel("Hide for today")
            }
            VStack(spacing: 8) {
                ForEach(r.rows, id: \.label) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.body).foregroundStyle(row.ok ? Theme.walk : Theme.warn)
                        Text(row.label).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(row.value).font(.subheadline.weight(.medium)).monospacedDigit().foregroundStyle(.primary.opacity(0.75))
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
        .padding(.vertical, 6)
        // a faint wash of green or amber, so the card reads at a glance
        .listRowBackground(Color(.secondarySystemGroupedBackground).overlay((good ? Theme.walk : Theme.warn).opacity(0.07)))
        .accessibilityIdentifier("weekReview")
    }
}
