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
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(DS.Palette.checkboxBorder, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(width: 46, height: 46)
            Text("Remove an app completely")
                .font(DS.TypeScale.screenTitle)
                .tracking(DS.Tracking.screenTitle)
            Text("Drag an app here, or pick one from the list.\nYou will see everything it left behind before anything is removed.")
                .font(DS.TypeScale.control)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)

            if model.fullDiskAccess == .granted {
                HStack(spacing: DS.Space.insideRow + 2) {
                    Circle().fill(DS.Palette.certain).frame(width: 8, height: 8)
                    Text("Full Disk Access granted — all locations are visible.")
                        .font(DS.TypeScale.secondary)
                        .foregroundStyle(DS.Palette.certainLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    DS.Palette.certain.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: DS.Radius.inlineContainer)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.inlineContainer)
                        .stroke(DS.Palette.certain.opacity(0.26))
                )
                .padding(.top, DS.Space.insideRow)
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
            Text(title)
                .font(DS.TypeScale.bodyEmphasis)
                .foregroundStyle(DS.Palette.textPrimary)
            ProgressView()
                .progressViewStyle(.linear)
                .tint(DS.Palette.accent)
                .frame(width: 260)
            Text(subtitle)
                .font(DS.TypeScale.secondary)
                .foregroundStyle(DS.Palette.textSecondary)
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
            Circle()
                .fill(DS.Palette.needsReview)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off").font(DS.TypeScale.bannerTitle)
                Text("Some folders will read as empty, so leftovers can be missed.")
                    .font(DS.TypeScale.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Button("Open Settings") { model.openFullDiskAccessSettings() }
            Button("Re-check") { model.refreshPermissions() }
        }
        .buttonStyle(QuietButtonStyle(small: true))
        .padding(.horizontal, DS.Space.pane)
        .padding(.vertical, DS.Space.control)
        .background(DS.Palette.needsReview.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}
