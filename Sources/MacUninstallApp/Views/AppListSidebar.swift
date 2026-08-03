import AppKit
import MacUninstallCore
import SwiftUI

struct AppListSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(model.filteredApps, id: \.bundleURL) { app in
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
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search apps")
        .navigationTitle("Applications")
        .overlay {
            if model.installedApps.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
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
