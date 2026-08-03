import MacUninstallCore
import SwiftUI

/// Explains the state of the privileged helper and offers the one action that
/// changes it.
///
/// The app works without the helper — it falls back to an authenticated prompt — so
/// this is framed as an optional convenience rather than a blocking requirement.
struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.helperStatus {
        case .enabled:
            EmptyView()

        case .requiresApproval:
            banner(
                icon: "person.badge.shield.checkmark",
                tint: .blue,
                title: "Finish enabling the background helper",
                detail: """
                    Turn on Mac Uninstall under Login Items to remove system-level \
                    leftovers without a password prompt each time.
                    """
            ) {
                Button("Open Login Items") { model.openHelperSettings() }
                Button("Re-check") { model.refreshHelperStatus() }
            }

        case .notRegistered:
            banner(
                icon: "bolt.badge.clock",
                tint: .secondary,
                title: "Install the background helper?",
                detail: """
                    Optional. Without it, removing launch daemons and privileged \
                    helpers asks for your password each time.
                    """
            ) {
                Button("Install") { model.installHelper() }
            }

        case .unavailable(let reason):
            banner(
                icon: "exclamationmark.triangle",
                tint: .orange,
                title: "The background helper is unavailable",
                detail: "\(reason) System-level removals will ask for your password instead."
            ) {
                Button("Re-check") { model.refreshHelperStatus() }
            }
        }
    }

    private func banner(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
