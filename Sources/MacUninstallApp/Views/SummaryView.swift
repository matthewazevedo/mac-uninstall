import AppKit
import MacUninstallCore
import SwiftUI

/// Closes the loop: what was removed, what was not, and how to undo it.
struct SummaryView: View {
    @Environment(AppModel.self) private var model
    let report: RemovalReport
    let appName: String

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    banner

                    if !report.failed.isEmpty {
                        section(
                            title: "Could not be removed",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: DS.Palette.needsReview,
                            outcomes: report.failed
                        )
                    }

                    section(
                        title: "Removed",
                        systemImage: "checkmark.circle.fill",
                        tint: DS.Palette.certain,
                        outcomes: report.succeeded
                    )

                    if let quarantine = report.quarantineDirectory {
                        quarantineNote(quarantine)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Open Trash") {
                    NSWorkspace.shared.open(
                        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
                    )
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Done") { model.startOver() }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(report.isFullSuccess ? DS.Palette.certain : DS.Palette.needsReview)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.isFullSuccess ? "\(appName) removed" : "\(appName) partially removed")
                    .font(DS.TypeScale.summaryTitle)
                    .tracking(DS.Tracking.summaryTitle)
                Text("\(report.succeeded.count) of \(report.outcomes.count) items handled.")
                    .font(DS.TypeScale.control)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private func section(
        title: String,
        systemImage: String,
        tint: Color,
        outcomes: [RemovalOutcome]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.insideRow) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title).font(DS.TypeScale.categoryHeader)
            }

            ForEach(outcomes) { outcome in
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.url.path)
                        .font(DS.TypeScale.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let message = outcome.message {
                        Text(message)
                            .font(DS.TypeScale.secondary)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func quarantineNote(_ directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System files are recoverable").font(DS.TypeScale.bannerTitle)
            Text("""
                Items that needed administrator rights were moved here rather than deleted, \
                alongside a MANIFEST.txt listing their original paths. Delete this folder once \
                you are satisfied nothing broke.
                """)
                .font(DS.TypeScale.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
            HStack {
                Text(directory.path)
                    .font(DS.TypeScale.monoSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .buttonStyle(QuietButtonStyle(small: true))
            }
        }
        .padding(DS.Space.control)
        .background(DS.Palette.quarantineFill, in: RoundedRectangle(cornerRadius: 8))
    }
}
