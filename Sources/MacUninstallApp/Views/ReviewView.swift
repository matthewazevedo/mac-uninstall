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
                    Text(result.identity.displayName)
                        .font(DS.TypeScale.screenTitle)
                        .tracking(DS.Tracking.screenTitle)
                    // Identifiers are what the filesystem wrote, so they are set in mono.
                    Text(result.identity.bundleID ?? result.identity.bundleURL.path)
                        .font(DS.TypeScale.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(result.leftovers.count) items")
                        .font(DS.TypeScale.bodyEmphasis)
                    Text(result.isMeasuringSizes ? "Measuring…" : result.totalSizeBytes.formattedBytes)
                        .font(DS.TypeScale.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            if !result.identity.isRemovable {
                Label(
                    "\(result.identity.displayName) is a macOS system app, so the app itself cannot be removed. Its data below can still be cleared.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if result.isIncomplete {
                Label(
                    "\(result.inaccessibleLocations.count) location(s) could not be read. This list may be incomplete.",
                    systemImage: "eye.trianglebadge.exclamationmark"
                )
                .font(DS.TypeScale.secondary)
                .foregroundStyle(DS.Palette.needsReview)
            }

            HStack(spacing: 8) {
                Button("Select all") { model.selectAll() }
                Button("Only certain matches") { model.selectCertainOnly() }
                Spacer()
                Button("Cancel") { model.startOver() }
            }
            .buttonStyle(QuietButtonStyle(small: true))
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
                    .font(DS.TypeScale.bodyEmphasis)
                Text(reversibilityNote)
                    .font(DS.TypeScale.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Spacer()

            if model.selectionNeedsAdmin {
                Label(
                    model.privilegedWorkUsesHelper ? "Uses the background helper" : "Needs your password",
                    systemImage: model.privilegedWorkUsesHelper ? "checkmark.shield.fill" : "lock.fill"
                )
                .font(DS.TypeScale.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
            }

            Button("Remove Selected") { showConfirmation = true }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedLeftovers.isEmpty)
        }
        .padding(16)
        .confirmationDialog(
            "Remove \(model.selectedLeftovers.count) items belonging to \(result.identity.displayName)?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            // Not destructive: nothing is erased, and a red button would say otherwise.
            Button("Remove") { model.performRemoval() }
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

            Text(category.rawValue).font(DS.TypeScale.categoryHeader)
            Text("\(items.count)")
                .font(DS.TypeScale.monoSmall)
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(DS.Palette.hairline, in: Capsule())
            Spacer()
            // "Zero KB" would claim a measurement that has not happened yet.
            Text(items.contains { $0.sizeBytes != nil }
                 ? items.compactMap(\.sizeBytes).reduce(0, +).formattedBytes
                 : "—")
                .font(DS.TypeScale.monoSmall)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.horizontal, DS.Space.pane)
        .padding(.vertical, DS.Metric.categoryHeaderVerticalPadding)
        .background(DS.Palette.bar)
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
                        .font(DS.TypeScale.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ConfidenceBadge(confidence: leftover.confidence)
                    if leftover.requiresAdmin {
                        // The only other row ornament.
                        Image(systemName: "lock")
                            .font(DS.TypeScale.monoSmall)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }

                Text(leftover.url.deletingLastPathComponent().path)
                    .font(DS.TypeScale.mono)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(leftover.reason)
                    .font(DS.TypeScale.secondary)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text(leftover.sizeBytes?.formattedBytes ?? "—")
                .font(DS.TypeScale.mono)
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(.horizontal, DS.Space.pane)
        .padding(.vertical, DS.Metric.rowVerticalPadding)
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
