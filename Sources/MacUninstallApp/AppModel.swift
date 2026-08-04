import AppKit
import Foundation
import MacUninstallCore
import Observation

/// Drives the whole UI: which app is targeted, what was found, what is selected.
@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case idle
        case scanning(appName: String)
        case reviewing
        case removing
        case finished
    }

    // MARK: - State

    var phase: Phase = .idle
    var installedApps: [AppIdentity] = []
    var searchText: String = ""
    var scanResult: ScanResult?
    var selectedPaths: Set<String> = []
    var report: RemovalReport?
    var errorMessage: String?
    var fullDiskAccess: PermissionChecker.Status = .indeterminate
    var helperStatus: HelperClient.Status = .notRegistered
    var isDropTargeted = false

    private let scanner = AppScanner()

    /// One client for the app's lifetime so the XPC connection is reused rather than
    /// rebuilt for every request.
    private let helper = HelperClient()

    // MARK: - Derived

    var filteredApps: [AppIdentity] {
        guard !searchText.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// Apps the user installed, which this app can actually remove.
    var removableApps: [AppIdentity] { filteredApps.filter(\.isRemovable) }

    /// Apps macOS ships and protects. Shown so the list matches Finder, but their
    /// bundles cannot be removed.
    var systemApps: [AppIdentity] { filteredApps.filter { !$0.isRemovable } }

    var selectedLeftovers: [Leftover] {
        scanResult?.leftovers.filter { selectedPaths.contains($0.id) } ?? []
    }

    var selectedSizeBytes: Int64 {
        selectedLeftovers.compactMap(\.sizeBytes).reduce(0, +)
    }

    var selectionNeedsAdmin: Bool {
        selectedLeftovers.contains { $0.requiresAdmin }
    }

    /// True when the user has ticked something we deliberately did not pre-select.
    var selectionIncludesUnreviewed: Bool {
        selectedLeftovers.contains { $0.confidence != .certain }
    }

    // MARK: - Lifecycle

    func onAppear() {
        refreshPermissions()
        refreshHelperStatus()
        loadInstalledApps()
    }

    // MARK: - Privileged helper

    /// Reads the daemon's registration state, then confirms it actually answers.
    ///
    /// launchd reporting "enabled" only means the job is installed. If the XPC
    /// handshake fails — a signature pin that no longer matches after re-signing, or a
    /// stale daemon from a previous build — the first sign of it would otherwise be a
    /// failed removal, which is the worst possible moment to find out.
    func refreshHelperStatus() {
        helperStatus = HelperClient.status
        guard helperStatus == .enabled else { return }

        Task {
            do {
                let version = try await helper.installedVersion()
                guard version != HelperConstants.protocolVersion else { return }
                self.helperStatus = .unavailable(
                    "The installed helper speaks version \(version), but this app expects "
                    + "version \(HelperConstants.protocolVersion). Reinstall it."
                )
            } catch {
                self.helperStatus = .unavailable(error.localizedDescription)
            }
        }
    }

    /// Registers the daemon. macOS then requires a one-time approval in Login Items,
    /// which is why the result is surfaced rather than assumed to be success.
    func installHelper() {
        helperStatus = HelperClient.register()
        switch helperStatus {
        case .requiresApproval:
            HelperClient.openApprovalSettings()
        case .unavailable(let reason):
            // Registration is the only step that produces a real diagnosis, so do not
            // let it fail silently behind a banner.
            errorMessage = "The background helper could not be installed. \(reason)"
        default:
            break
        }
    }

    func openHelperSettings() {
        HelperClient.openApprovalSettings()
    }

    /// Shows the app in Finder so the user can drag it to Applications.
    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func refreshPermissions() {
        fullDiskAccess = PermissionChecker.fullDiskAccessStatus()
    }

    /// True when the current selection would be handled by the daemon rather than a
    /// password prompt, so the UI can say which is about to happen.
    var privilegedWorkUsesHelper: Bool {
        selectionNeedsAdmin && helperStatus == .enabled
    }

    func loadInstalledApps() {
        let scanner = self.scanner
        Task {
            let apps = await Task.detached { scanner.installedApps() }.value
            self.installedApps = apps
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PermissionChecker.fullDiskAccessSettingsURL)
    }

    // MARK: - Scanning

    /// Handles an app dropped onto the window.
    func handleDrop(url: URL) {
        guard url.pathExtension == "app" else {
            errorMessage = "\(url.lastPathComponent) is not an application."
            return
        }
        guard let identity = scanner.readIdentity(at: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        scan(identity)
    }

    func scan(_ identity: AppIdentity) {
        errorMessage = nil
        report = nil
        phase = .scanning(appName: identity.displayName)

        let scanner = self.scanner
        Task {
            // Signature lookup and the sweep are both blocking work; keep them off
            // the main actor so the progress UI stays responsive.
            //
            // Sizes are deliberately skipped here. Measuring a multi-gigabyte support
            // folder takes seconds, and the list is useful the moment it exists.
            let result = await Task.detached { () -> ScanResult in
                let enriched = scanner.enrichWithSignature(identity)
                return await LeftoverScanner(options: .init(measureSizes: false))
                    .scan(for: enriched)
            }.value

            self.scanResult = result
            self.selectedPaths = Set(
                result.leftovers.filter { $0.confidence.selectedByDefault }.map(\.id)
            )
            self.phase = .reviewing
            self.measureSizes(for: result)
        }
    }

    /// Fills in sizes after the list is already on screen.
    ///
    /// The result is discarded if the user has moved on to a different app, so a slow
    /// measurement can never overwrite a newer scan.
    private func measureSizes(for result: ScanResult) {
        let leftovers = result.leftovers
        let scannedBundle = result.identity.bundleURL

        Task {
            let measured = await Task.detached {
                await LeftoverScanner().measureSizes(for: leftovers)
            }.value

            guard var current = self.scanResult,
                  current.identity.bundleURL == scannedBundle else { return }

            let sizes = Dictionary(
                measured.compactMap { item in item.sizeBytes.map { (item.id, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            current.leftovers = current.leftovers.map { item in
                var item = item
                item.sizeBytes = sizes[item.id]
                return item
            }
            self.scanResult = current
        }
    }

    // MARK: - Selection

    func toggle(_ leftover: Leftover) {
        if selectedPaths.contains(leftover.id) {
            selectedPaths.remove(leftover.id)
        } else {
            selectedPaths.insert(leftover.id)
        }
    }

    func setSelection(_ isSelected: Bool, for items: [Leftover]) {
        for item in items {
            if isSelected { selectedPaths.insert(item.id) } else { selectedPaths.remove(item.id) }
        }
    }

    func selectAll() {
        selectedPaths = Set(scanResult?.leftovers.map(\.id) ?? [])
    }

    func selectCertainOnly() {
        selectedPaths = Set(
            scanResult?.leftovers.filter { $0.confidence.selectedByDefault }.map(\.id) ?? []
        )
    }

    func revealInFinder(_ leftover: Leftover) {
        NSWorkspace.shared.activateFileViewerSelecting([leftover.url])
    }

    // MARK: - Removal

    func performRemoval() {
        guard let scanResult, !selectedLeftovers.isEmpty else { return }
        phase = .removing

        let items = selectedLeftovers
        let identity = scanResult.identity

        Task {
            // Quit first: a running app rewrites its preferences on exit and would
            // recreate files we are about to delete.
            let quit = await RunningAppGuard.quit(identity)
            if !quit {
                self.errorMessage = """
                    \(identity.displayName) is still running and could not be quit. \
                    Quit it manually, then try again.
                    """
                self.phase = .reviewing
                return
            }

            let report = await Remover(
                privileged: AdaptivePrivilegedExecutor(helper: self.helper)
            ).remove(items)
            self.report = report
            self.phase = .finished
            self.loadInstalledApps()
        }
    }

    func startOver() {
        scanResult = nil
        selectedPaths = []
        report = nil
        errorMessage = nil
        phase = .idle
        refreshPermissions()
        refreshHelperStatus()
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
