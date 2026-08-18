import MacUninstallAppCore
import MacUninstallCore
import SwiftUI

/// Data with no app behind it, grouped by the identifier it belongs to.
///
/// Presented as a list of candidates rather than a removal plan: picking one opens
/// the ordinary review screen, so the same rules, reasons, and confirmation apply as
/// they would to an app you still have.
struct OrphanListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.orphanGroups.isEmpty {
                ContentUnavailableView(
                    "Nothing left behind",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Every identifier in your Library belongs to an app you still have."
                    )
                )
            } else {
                list
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leftovers from removed apps")
                        .font(DS.TypeScale.screenTitle)
                        .tracking(DS.Tracking.screenTitle)
                    Text(subtitle)
                        .font(DS.TypeScale.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button("Done") { model.startOver() }
                    .buttonStyle(QuietButtonStyle(small: true))
            }

            // The honest caveat: an app on an external disk, or installed somewhere
            // this does not look, will show up here as though it were gone.
            //
            // Not `.fixedSize(horizontal: false, vertical: true)`: this header sits in
            // a plain VStack above the list's own ScrollView, so nothing here absorbs
            // a height the text demands but doesn't get. `fixedSize` did exactly that
            // once before, in NoticeBanner (see the comment there) — the split view
            // laid out past the window's top edge and the sidebar looked permanently
            // scrolled down. Left to wrap normally, the text reports a height that fits.
            Text("""
                Each of these is a bundle identifier with no installed app behind it. \
                Nothing is pre-selected, and nothing is removed until you review it.
                """)
                .font(DS.TypeScale.secondary)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(DS.Space.pane)
    }

    private var subtitle: String {
        let count = model.orphanGroups.count
        let items = model.orphanGroups.reduce(0) { $0 + $1.leftovers.count }
        return "\(count) identifier\(count == 1 ? "" : "s") · \(items) item\(items == 1 ? "" : "s")"
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.orphanGroups) { group in
                    Button { model.inspect(group) } label: {
                        row(for: group)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    private func row(for group: OrphanGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.identifier)
                    .font(DS.TypeScale.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(categorySummary(for: group))
                    .font(DS.TypeScale.secondary)
                    .foregroundStyle(DS.Palette.textTertiary)
            }

            Spacer(minLength: 8)

            Text(group.totalSizeBytes.formattedBytes(partial: group.totalSizeIsPartial))
                .font(DS.TypeScale.mono)
                .foregroundStyle(DS.Palette.textSecondary)

            Image(systemName: "chevron.right")
                .font(DS.TypeScale.badge)
                .foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(.horizontal, DS.Space.pane)
        .padding(.vertical, DS.Metric.rowVerticalPadding)
        .contentShape(.rect)
    }

    private func categorySummary(for group: OrphanGroup) -> String {
        let categories = group.leftovers
            .map(\.category)
            .reduce(into: [LeftoverCategory]()) { unique, category in
                if !unique.contains(category) { unique.append(category) }
            }
        let count = group.leftovers.count
        return "\(count) item\(count == 1 ? "" : "s") · "
            + categories.map(\.rawValue).joined(separator: ", ")
    }
}
