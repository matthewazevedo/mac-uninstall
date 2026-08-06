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
            NoticeBanner(tint: tint, title: title, detail: detail) {
                HStack(spacing: DS.Space.insideRow) {
                    if model.helperStatus == .notRegistered {
                        Button("Install") { model.installHelper() }
                    } else if model.helperStatus == .needsInstallInApplications {
                        Button("Reveal") { model.revealApp() }
                    } else {
                        if model.helperStatus == .requiresApproval {
                            Button("Open Login Items") { model.openHelperSettings() }
                        } else {
                            // The unavailable state is usually a daemon left behind by
                            // an older version, which an app update produces whenever
                            // the protocol version moves. Re-checking can only ever
                            // confirm that; replacing the daemon is what clears it.
                            Button("Reinstall") { model.reinstallHelper() }
                        }
                        Button("Re-check") { model.refreshHelperStatus() }
                    }
                }
                .buttonStyle(QuietButtonStyle(small: true))
            }
            .padding(.horizontal, DS.Space.pane)
            .padding(.top, DS.Space.insideRow)
        }
    }

    private var tint: Color {
        switch model.helperStatus {
        case .requiresApproval: DS.Palette.accent
        case .notRegistered: DS.Palette.textTertiary
        case .needsInstallInApplications: DS.Palette.accent
        default: DS.Palette.needsReview
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
