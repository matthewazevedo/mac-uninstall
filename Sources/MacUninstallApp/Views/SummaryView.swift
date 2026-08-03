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
                            tint: .orange,
                            outcomes: report.failed
                        )
                    }

                    section(
                        title: "Removed",
                        systemImage: "checkmark.circle.fill",
                        tint: .green,
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
                Spacer()
                Button("Done") { model.startOver() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: report.isFullSuccess ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(report.isFullSuccess ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.isFullSuccess ? "\(appName) removed" : "\(appName) partially removed")
                    .font(.title2.weight(.semibold))
                Text("\(report.succeeded.count) of \(report.outcomes.count) items handled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)

            ForEach(outcomes) { outcome in
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.url.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let message = outcome.message {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func quarantineNote(_ directory: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("System files are recoverable", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.headline)
            Text("""
                Items that needed administrator rights were moved here rather than deleted, \
                alongside a MANIFEST.txt listing their original paths. Delete this folder once \
                you are satisfied nothing broke.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(directory.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
