import MacUninstallCore
import SwiftUI

/// Explains the state of the privileged helper and offers the one action that
/// changes it.
///
/// The app works without the helper — it falls back to an authenticated prompt — so
/// this is framed as an optional convenience rather than a blocking requirement.
///
/// Structured as one concrete layout driven by computed properties, deliberately
/// mirroring ``FullDiskAccessBanner``. An earlier version built each state through a
/// generic `@ViewBuilder` helper, so every `switch` branch produced a different opaque
/// view type; that broke the layout of the entire window, blanking the unrelated
/// sidebar column rather than failing locally.
struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.helperStatus != .enabled {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.helperStatus == .notRegistered {
                    Button("Install") { model.installHelper() }
                } else if model.helperStatus == .needsInstallInApplications {
                    Button("Reveal") { model.revealApp() }
                } else {
                    if model.helperStatus == .requiresApproval {
                        Button("Open Login Items") { model.openHelperSettings() }
                    }
                    Button("Re-check") { model.refreshHelperStatus() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint.opacity(0.10))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var icon: String {
        switch model.helperStatus {
        case .requiresApproval: "person.badge.shield.checkmark"
        case .notRegistered: "bolt.badge.clock"
        case .needsInstallInApplications: "folder.badge.plus"
        default: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch model.helperStatus {
        case .requiresApproval: .blue
        case .notRegistered: .secondary
        case .needsInstallInApplications: .blue
        default: .orange
        }
    }

    private var title: String {
        switch model.helperStatus {
        case .requiresApproval: "Finish enabling the background helper"
        case .notRegistered: "Install the background helper?"
        case .needsInstallInApplications: "Move Mac Uninstall to your Applications folder"
        default: "The background helper is unavailable"
        }
    }

    private var detail: String {
        switch model.helperStatus {
        case .requiresApproval:
            "Turn on Mac Uninstall under Login Items to remove system-level leftovers without a password prompt each time."
        case .notRegistered:
            "Optional. Without it, removing launch daemons and privileged helpers asks for your password each time."
        case .needsInstallInApplications:
            "The background helper only works when the app runs from Applications. Until then, system-level removals ask for your password."
        case .unavailable(let reason):
            "\(reason) System-level removals will ask for your password instead."
        case .enabled:
            ""
        }
    }
}
