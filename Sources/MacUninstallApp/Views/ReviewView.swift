import MacUninstallCore
import SwiftUI

/// The audit screen: every proposed deletion, why it was proposed, and what it costs.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    let result: ScanResult

    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if result.leftovers.isEmpty {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "checkmark.circle",
                    description: Text("No files belonging to \(result.identity.displayName) were found.")
                )
            } else {
                list
            }

            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIcon(url: result.identity.bundleURL, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.identity.displayName).font(.title2.weight(.semibold))
                    Text(result.identity.bundleID ?? result.identity.bundleURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(result.leftovers.count) items")
                        .font(.callout.weight(.medium))
                    Text(result.isMeasuringSizes ? "Measuring…" : result.totalSizeBytes.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if result.isIncomplete {
                Label(
                    "\(result.inaccessibleLocations.count) location(s) could not be read. This list may be incomplete.",
                    systemImage: "eye.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Select all") { model.selectAll() }
                Button("Only certain matches") { model.selectCertainOnly() }
                Spacer()
                Button("Cancel", role: .cancel) { model.startOver() }
            }
            .controlSize(.small)
        }
        .padding(16)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(result.grouped(), id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            LeftoverRow(leftover: item)
                            Divider().padding(.leading, 44)
                        }
                    } header: {
                        CategoryHeader(category: group.category, items: group.items)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionSummary)
                    .font(.callout.weight(.medium))
                Text(reversibilityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.selectionNeedsAdmin {
                Label("Needs your password", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Remove Selected") { showConfirmation = true }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedLeftovers.isEmpty)
        }
        .padding(16)
        .confirmationDialog(
            "Remove \(model.selectedLeftovers.count) items belonging to \(result.identity.displayName)?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.performRemoval() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var selectionSummary: String {
        let count = model.selectedLeftovers.count
        guard !result.isMeasuringSizes else { return "\(count) selected" }
        return "\(count) selected · \(model.selectedSizeBytes.formattedBytes)"
    }

    private var reversibilityNote: String {
        model.selectionNeedsAdmin
            ? "User files go to the Trash. System files are moved to a quarantine folder you can restore from."
            : "Everything goes to the Trash, so you can put it back."
    }

    private var confirmationMessage: String {
        var message = "\(result.identity.displayName) will be quit first. "
        message += model.selectionNeedsAdmin
            ? "Nothing is erased: user files go to the Trash and system files are moved to a quarantine folder."
            : "Nothing is erased — everything goes to the Trash."
        if model.selectionIncludesUnreviewed {
            message += "\n\nYour selection includes items that may be shared with other apps from the same vendor."
        }
        return message
    }
}

struct CategoryHeader: View {
    @Environment(AppModel.self) private var model
    let category: LeftoverCategory
    let items: [Leftover]

    private var allSelected: Bool {
        items.allSatisfy { model.selectedPaths.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .init(
                get: { allSelected },
                set: { model.setSelection($0, for: items) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(category.rawValue).font(.subheadline.weight(.semibold))
            Text("\(items.count)")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Spacer()
            Text(items.compactMap(\.sizeBytes).reduce(0, +).formattedBytes)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

struct LeftoverRow: View {
    @Environment(AppModel.self) private var model
    let leftover: Leftover

    private var isSelected: Bool { model.selectedPaths.contains(leftover.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: .init(
                get: { isSelected },
                set: { _ in model.toggle(leftover) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(leftover.url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ConfidenceBadge(confidence: leftover.confidence)
                    if leftover.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(leftover.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(leftover.reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(leftover.sizeBytes?.formattedBytes ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onTapGesture { model.toggle(leftover) }
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(leftover) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(leftover.url.path, forType: .string)
            }
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    private var color: Color {
        switch confidence {
        case .certain: .green
        case .likely: .blue
        case .possible: .orange
        }
    }

    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
