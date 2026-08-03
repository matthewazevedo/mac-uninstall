import AppKit
import Foundation
import MacUninstallCore

/// Ensures an app is not running before it is removed.
///
/// Deleting a running app leaves its processes alive holding open file handles, and
/// many apps rewrite their preferences on quit — recreating the very files that were
/// just deleted. Quitting first is what makes the removal stick.
@MainActor
public enum RunningAppGuard {

    public struct RunningProcess: Sendable, Identifiable {
        public var id: pid_t { pid }
        public var pid: pid_t
        public var name: String
        public var bundleID: String?
    }

    /// Returns processes belonging to this app, including helpers under the same
    /// reverse-DNS prefix, which are what usually keep running after the main quit.
    public static func runningProcesses(for identity: AppIdentity) -> [RunningProcess] {
        let prefix = identity.reverseDNSPrefix?.lowercased()

        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let appBundleID = app.bundleIdentifier?.lowercased() else {
                // Match by bundle path when the process declares no identifier.
                guard let url = app.bundleURL,
                      url.standardizedFileURL.path.hasPrefix(identity.bundleURL.path) else { return nil }
                return RunningProcess(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? url.lastPathComponent,
                    bundleID: nil
                )
            }

            let isExact = identity.strongIdentifiers.contains { appBundleID == $0.lowercased() }
            let isHelper = prefix.map { appBundleID.hasPrefix($0 + ".") } ?? false
            let isSameBundle = app.bundleURL.map {
                $0.standardizedFileURL.path.hasPrefix(identity.bundleURL.path)
            } ?? false

            guard isExact || isHelper || isSameBundle else { return nil }
            return RunningProcess(
                pid: app.processIdentifier,
                name: app.localizedName ?? appBundleID,
                bundleID: app.bundleIdentifier
            )
        }
    }

    /// Asks the app to quit, then escalates to a forced termination.
    ///
    /// - Returns: `true` if nothing belonging to the app is still running.
    @discardableResult
    public static func quit(
        _ identity: AppIdentity,
        gracePeriod: Duration = .seconds(4)
    ) async -> Bool {
        let processes = runningProcesses(for: identity)
        guard !processes.isEmpty else { return true }

        let pids = Set(processes.map(\.pid))
        let apps = NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) }

        for app in apps { app.terminate() }

        // Poll rather than sleeping the full period, so a fast quit is not penalised.
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while ContinuousClock.now < deadline {
            if runningProcesses(for: identity).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }

        for app in NSWorkspace.shared.runningApplications
        where pids.contains(app.processIdentifier) && !app.isTerminated {
            app.forceTerminate()
        }

        try? await Task.sleep(for: .milliseconds(500))
        return runningProcesses(for: identity).isEmpty
    }
}
