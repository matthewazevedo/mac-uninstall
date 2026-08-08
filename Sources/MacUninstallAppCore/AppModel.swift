import AppKit
import Foundation
import MacUninstallCore
import Observation

/// Drives the whole UI: which app is targeted, what was found, what is selected.
@MainActor
@Observable
public final class AppModel {

    public enum Phase: Equatable {
        case idle
        case scanning(appName: String)
        case findingOrphans
        case orphans
        case reviewing
        case removing
        case restoring
        case finished
    }

    /// Which way the last action ran, so the summary screen can say what happened
    /// rather than assuming everything is a removal.
    public enum ActionKind: Sendable, Equatable {
        case removal
        case restore
    }

    // MARK: - State

    public var phase: Phase = .idle
    public var installedApps: [AppIdentity] = []
    public var searchText: String = ""
    public var scanResult: ScanResult?
    public var selectedPaths: Set<String> = []
    public var report: RemovalReport?
    public var errorMessage: String?
    public var fullDiskAccess: PermissionChecker.Status = .indeterminate
    public var helperStatus: HelperClient.Status = .notRegistered
    public var isDropTargeted = false

    /// Leftovers grouped by an identifier with no installed app behind it.
    public var orphanGroups: [OrphanGroup] = []
    /// The most recent removal that can still be put back, or `nil` when there is
    /// nothing to undo — including when the Trash has since been emptied.
    public var undoableReceipt: RemovalReceipt?
    public private(set) var lastAction: ActionKind = .removal
    /// What the summary screen is reporting on.
    public private(set) var summaryTitle: String = ""

    /// True while the review screen is showing orphans rather than an installed app.
    private var isOrphanTarget = false

    private let scanner = AppScanner()
    private let receipts = ReceiptStore()

    /// One client for the app's lifetime so the XPC connection is reused rather than
    /// rebuilt for every request.
    private let helper = HelperClient()

    public init() {}

    // MARK: - Derived

    public var filteredApps: [AppIdentity] {
        guard !searchText.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// Apps the user installed, which this app can actually remove.
    public var removableApps: [AppIdentity] { filteredApps.filter(\.isRemovable) }

    /// Apps macOS ships and protects. Shown so the list matches Finder, but their
    /// bundles cannot be removed.
    public var systemApps: [AppIdentity] { filteredApps.filter { !$0.isRemovable } }

    public var selectedLeftovers: [Leftover] {
        scanResult?.leftovers.filter { selectedPaths.contains($0.id) } ?? []
    }

    public var selectedSizeBytes: Int64 {
        selectedLeftovers.compactMap(\.sizeBytes).reduce(0, +)
    }

    /// True when one of the selected items was too large to measure exactly, so the
    /// total is a floor and has to be shown as one.
    public var selectedSizeIsPartial: Bool {
        selectedLeftovers.contains { $0.sizeIsPartial }
    }

    public var selectionNeedsAdmin: Bool {
        selectedLeftovers.contains { $0.requiresAdmin }
    }

    /// True when the user has ticked something we deliberately did not pre-select.
    public var selectionIncludesUnreviewed: Bool {
        selectedLeftovers.contains { $0.confidence != .certain }
    }

    // MARK: - Lifecycle

    public func onAppear() {
        refreshPermissions()
        refreshHelperStatus()
        loadInstalledApps()
        refreshUndoAvailability()
    }

    // MARK: - Privileged helper

    /// Reads the daemon's registration state, then confirms it actually answers.
    ///
    /// launchd reporting "enabled" only means the job is installed. If the XPC
    /// handshake fails — a signature pin that no longer matches after re-signing, or a
    /// stale daemon from a previous build — the first sign of it would otherwise be a
    /// failed removal, which is the worst possible moment to find out.
    public func refreshHelperStatus() {
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
    public func installHelper() {
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

    /// Replaces an installed daemon, rather than registering alongside it.
    ///
    /// The unregister step is the whole point. `register()` reports an already
    /// registered job as success and returns without touching it, so a daemon left
    /// behind by a previous version — which is what an app update produces whenever
    /// the protocol version moves — would survive a plain reinstall and keep
    /// answering with the wrong version. Tearing the old job down first is the only
    /// thing that actually replaces it.
    public func reinstallHelper() {
        Task {
            // A failure here is not worth surfacing on its own: if the job was
            // already gone, that is exactly the state registering wants.
            try? await HelperClient.unregister()
            installHelper()
        }
    }

    public func openHelperSettings() {
        HelperClient.openApprovalSettings()
    }

    /// Shows the app in Finder so the user can drag it to Applications.
    public func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    public func refreshPermissions() {
        fullDiskAccess = PermissionChecker.fullDiskAccessStatus()
    }

    /// True when the current selection would be handled by the daemon rather than a
    /// password prompt, so the UI can say which is about to happen.
    public var privilegedWorkUsesHelper: Bool {
        selectionNeedsAdmin && helperStatus == .enabled
    }

    public func loadInstalledApps() {
        let scanner = self.scanner
        Task {
            let apps = await Task.detached { scanner.installedApps() }.value
            self.installedApps = apps
        }
    }

    public func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(PermissionChecker.fullDiskAccessSettingsURL)
    }

    // MARK: - Scanning

    /// Handles an app dropped onto the window.
    public func handleDrop(url: URL) {
        guard url.pathExtension.lowercased() == "app" else {
            errorMessage = "\(url.lastPathComponent) is not an application."
            return
        }
        guard let identity = scanner.readIdentity(at: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        scan(identity)
    }

    public func scan(_ identity: AppIdentity) {
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

    // MARK: - Orphans

    /// Looks for data whose app is already gone.
    ///
    /// This is the case every other entry point cannot serve: once the bundle has
    /// been dragged to the Trash there is no identity left to match against, which is
    /// exactly when people go looking for a tool like this.
    public func findOrphans() {
        errorMessage = nil
        report = nil
        scanResult = nil
        isOrphanTarget = false
        phase = .findingOrphans

        let scanner = self.scanner
        let known = installedApps
        Task {
            let groups = await Task.detached { () -> [OrphanGroup] in
                var apps = known.isEmpty ? scanner.installedApps() : known
                // This app's own preferences are not an orphan, even when it is
                // running from a build directory rather than /Applications.
                if let identifier = Bundle.main.bundleIdentifier {
                    apps.append(AppIdentity(
                        bundleURL: Bundle.main.bundleURL,
                        bundleID: identifier,
                        displayName: "Mac Uninstall"
                    ))
                }
                return await OrphanScanner().scan(installedApps: apps)
            }.value

            self.orphanGroups = groups
            self.phase = .orphans
        }
    }

    /// Opens one group of orphans in the ordinary review screen.
    public func inspect(_ group: OrphanGroup) {
        isOrphanTarget = true
        scanResult = ScanResult(
            identity: .orphan(identifier: group.identifier),
            leftovers: group.leftovers
        )
        // Nothing here is `certain`, so nothing is ticked. The absence of an app is
        // a strong hint, not proof.
        selectedPaths = Set(
            group.leftovers.filter { $0.confidence.selectedByDefault }.map(\.id)
        )
        phase = .reviewing
    }

    /// Fills in sizes after the list is already on screen.
    private func measureSizes(for result: ScanResult) {
        let leftovers = result.leftovers
        let scannedBundle = result.identity.bundleURL

        Task {
            let measured = await Task.detached {
                await LeftoverScanner().measureSizes(for: leftovers)
            }.value
            self.applyMeasuredSizes(measured, from: scannedBundle)
        }
    }

    /// Merges measured sizes into the current result.
    ///
    /// Discarded if the user has moved on to a different app, so a slow measurement
    /// of a big Library can never overwrite a newer scan with another app's numbers.
    func applyMeasuredSizes(_ measured: [Leftover], from scannedBundle: URL) {
        guard var current = scanResult, current.identity.bundleURL == scannedBundle else { return }

        let byID = Dictionary(measured.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        current.leftovers = current.leftovers.map { item in
            var item = item
            item.sizeBytes = byID[item.id]?.sizeBytes
            item.sizeIsPartial = byID[item.id]?.sizeIsPartial ?? false
            return item
        }
        scanResult = current
    }

    // MARK: - Selection

    public func toggle(_ leftover: Leftover) {
        if selectedPaths.contains(leftover.id) {
            selectedPaths.remove(leftover.id)
        } else {
            selectedPaths.insert(leftover.id)
        }
    }

    public func setSelection(_ isSelected: Bool, for items: [Leftover]) {
        for item in items {
            if isSelected { selectedPaths.insert(item.id) } else { selectedPaths.remove(item.id) }
        }
    }

    public func selectAll() {
        selectedPaths = Set(scanResult?.leftovers.map(\.id) ?? [])
    }

    public func selectCertainOnly() {
        selectedPaths = Set(
            scanResult?.leftovers.filter { $0.confidence.selectedByDefault }.map(\.id) ?? []
        )
    }

    public func revealInFinder(_ leftover: Leftover) {
        NSWorkspace.shared.activateFileViewerSelecting([leftover.url])
    }

    // MARK: - Removal

    public func performRemoval() {
        guard let scanResult, !selectedLeftovers.isEmpty else { return }
        phase = .removing
        lastAction = .removal
        summaryTitle = scanResult.identity.displayName

        let items = selectedLeftovers
        let identity = scanResult.identity
        // Orphans have no app to quit, and quitting on the strength of a shared
        // vendor prefix would take an unrelated running app down with it.
        let needsQuit = !isOrphanTarget

        Task {
            // Quit first: a running app rewrites its preferences on exit and would
            // recreate files we are about to delete.
            if needsQuit, !(await RunningAppGuard.quit(identity)) {
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
            self.recordReceipt(for: report, appName: identity.displayName)
            // The list was built before this removal, so it now describes a state
            // that no longer exists.
            self.orphanGroups = []
            self.isOrphanTarget = false
            self.phase = .finished
            self.loadInstalledApps()
        }
    }

    // MARK: - Undo

    /// Puts the last removal back.
    public func undoLastRemoval() {
        guard let receipt = undoableReceipt else { return }
        phase = .restoring
        lastAction = .restore
        summaryTitle = receipt.appName

        Task {
            let report = await Remover(
                privileged: AdaptivePrivilegedExecutor(helper: self.helper)
            ).restore(receipt)

            self.report = report
            self.scanResult = nil
            // A receipt that has been fully honoured describes nothing that is still
            // recoverable, so offering it again would be offering a no-op.
            if report.isFullSuccess { self.receipts.delete(receipt) }
            self.phase = .finished
            self.refreshUndoAvailability()
            self.loadInstalledApps()
        }
    }

    private func recordReceipt(for report: RemovalReport, appName: String) {
        guard let receipt = RemovalReceipt(report: report, appName: appName) else { return }
        try? receipts.save(receipt)
        undoableReceipt = receipt
    }

    /// Reads the newest removal that still has something to put back. Checking the
    /// filesystem is the point: an emptied Trash means the offer would not work.
    public func refreshUndoAvailability() {
        let receipts = self.receipts
        Task {
            self.undoableReceipt = await Task.detached { receipts.latestRestorable() }.value
        }
    }

    public func startOver() {
        scanResult = nil
        selectedPaths = []
        report = nil
        errorMessage = nil
        // Cancelling out of a group of orphans goes back to the list it came from,
        // rather than making the user run the search again.
        phase = (isOrphanTarget && !orphanGroups.isEmpty) ? .orphans : .idle
        isOrphanTarget = false
        refreshPermissions()
        refreshHelperStatus()
        refreshUndoAvailability()
    }
}

public extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    /// "≥ 4.2 GB" when the walk stopped at its bound. A confident wrong number is
    /// worse than an honest floor on a screen whose whole job is to be trusted.
    func formattedBytes(partial: Bool) -> String {
        partial ? "≥ " + formattedBytes : formattedBytes
    }
}

public extension Leftover {
    var sizeDescription: String {
        sizeBytes.map { $0.formattedBytes(partial: sizeIsPartial) } ?? "—"
    }
}
