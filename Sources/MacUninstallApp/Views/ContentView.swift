import MacUninstallCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            AppListSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if model.isDropTargeted {
                DropOverlay()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if model.fullDiskAccess == .denied {
                FullDiskAccessBanner()
            }
            HelperBanner()

            switch model.phase {
            case .idle:
                EmptyStateView()
            case .scanning(let appName):
                ScanningView(appName: appName)
            case .reviewing:
                if let result = model.scanResult {
                    ReviewView(result: result)
                }
            case .removing:
                ProgressPanel(
                    title: "Removing…",
                    subtitle: "Quitting the app and moving its files out of the way."
                )
            case .finished:
                if let report = model.report, let result = model.scanResult {
                    SummaryView(report: report, appName: result.identity.displayName)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.handleDrop(url: url) }
        }
        return true
    }
}

/// Full-window affordance shown while a bundle is being dragged over the app.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                Text("Drop to scan").font(.title2.weight(.semibold))
                Text("Every file this app has left behind will be listed before anything is removed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .allowsHitTesting(false)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text("Remove an app completely")
                .font(.title2.weight(.semibold))
            Text("Drag an app here, or pick one from the list.\nYou will see everything it left behind before anything is removed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.fullDiskAccess == .granted {
                Label("Full Disk Access granted — all locations are visible.", systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct ScanningView: View {
    let appName: String

    var body: some View {
        ProgressPanel(title: "Scanning for \(appName)…", subtitle: "Checking every place apps store data.")
    }
}

struct ProgressPanel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(title).font(.title3.weight(.medium))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when Full Disk Access is missing, because the scan cannot be trusted
/// to be complete without it.
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(.callout.weight(.semibold))
                Text("Some folders will read as empty, so leftovers can be missed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
            Button("Re-check") { model.refreshPermissions() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
