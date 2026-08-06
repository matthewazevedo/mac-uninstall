import AppKit
import MacUninstallCore
import SwiftUI

/// Row styling here is off the design system's 26pt icon and mono version line, and
/// stays that way only because nothing has re-derived those metrics since.
///
/// An earlier note blamed the taller rows for the sidebar opening scrolled past the
/// user's own apps. That was wrong: the list overflows its viewport at any row height,
/// and the real cause was a banner in the *detail* column forcing the whole split view
/// to lay out taller than the window. See ``NoticeBanner``.
struct AppListSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List {
            // Your own apps first. macOS ships around 65 of its own, which would
            // otherwise bury the handful the user actually installed — but leaving
            // them out makes the list look broken to anyone expecting Safari and Mail.
            if !model.removableApps.isEmpty {
                Section("Applications") {
                    ForEach(model.removableApps, id: \.bundleURL) { row(for: $0) }
                }
            }
            if !model.systemApps.isEmpty {
                Section("Included with macOS") {
                    ForEach(model.systemApps, id: \.bundleURL) { row(for: $0) }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search apps")
        .navigationTitle("Applications")
        .overlay {
            if model.installedApps.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func row(for app: AppIdentity) -> some View {
        Button {
            model.scan(app)
        } label: {
            HStack(spacing: 10) {
                AppIcon(url: app.bundleURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName).lineLimit(1)
                    if let version = app.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !app.isRemovable {
                    // Listed so the sidebar matches what the user sees in Finder, but
                    // the bundle itself is protected by macOS.
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("A macOS system app. It cannot be removed, but its data can be cleared.")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Renders a bundle's real icon at a fixed size.
struct AppIcon: View {
    let url: URL
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}
