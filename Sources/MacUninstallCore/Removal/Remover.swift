import Foundation

/// Outcome for one item in a removal plan.
public struct RemovalOutcome: Sendable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var succeeded: Bool
    public var message: String?

    public init(url: URL, succeeded: Bool, message: String? = nil) {
        self.url = url
        self.succeeded = succeeded
        self.message = message
    }
}

public struct RemovalReport: Sendable {
    public var outcomes: [RemovalOutcome]
    public var quarantineDirectory: URL?

    public var succeeded: [RemovalOutcome] { outcomes.filter(\.succeeded) }
    public var failed: [RemovalOutcome] { outcomes.filter { !$0.succeeded } }
    public var isFullSuccess: Bool { failed.isEmpty }
}

/// Removes leftovers, reversibly.
///
/// Nothing is ever destroyed outright. User-owned items go to the Trash so Finder's
/// "Put Back" works. Root-owned items are moved into a timestamped quarantine folder
/// with a manifest, so a mistake can always be undone.
public struct Remover: Sendable {

    public struct Options: Sendable {
        /// Unload launchd jobs before deleting their plists, otherwise the job keeps
        /// running until reboot and can recreate the files it owns.
        public var unloadLaunchItems: Bool
        /// Where root-owned items are staged instead of being deleted.
        public var quarantineRoot: URL

        public init(
            unloadLaunchItems: Bool = true,
            quarantineRoot: URL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/MacUninstall/Quarantine")
        ) {
            self.unloadLaunchItems = unloadLaunchItems
            self.quarantineRoot = quarantineRoot
        }
    }

    let options: Options
    let privileged: PrivilegedExecutor

    public init(options: Options = .init(), privileged: PrivilegedExecutor = AdaptivePrivilegedExecutor()) {
        self.options = options
        self.privileged = privileged
    }

    /// Removes the given items, revalidating every path against ``ProtectedPaths``.
    ///
    /// Validation is repeated here on purpose: the plan may have been built minutes
    /// earlier, and this is the only place that actually destroys anything.
    public func remove(_ leftovers: [Leftover]) async -> RemovalReport {
        var outcomes: [RemovalOutcome] = []
        var quarantineDirectory: URL?

        var userItems: [Leftover] = []
        var privilegedItems: [Leftover] = []

        for leftover in leftovers {
            if let rejection = ProtectedPaths.rejection(for: leftover.url) {
                outcomes.append(RemovalOutcome(
                    url: leftover.url,
                    succeeded: false,
                    message: RemovalError.refusedUnsafePath(leftover.url, rejection).localizedDescription
                ))
                continue
            }
            if leftover.requiresAdmin || !isRemovableWithoutElevation(leftover.url) {
                privilegedItems.append(leftover)
            } else {
                userItems.append(leftover)
            }
        }

        if options.unloadLaunchItems {
            await unloadLaunchJobs(in: leftovers)
        }

        for item in userItems {
            outcomes.append(trash(item.url))
        }

        if !privilegedItems.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let directory = options.quarantineRoot.appending(path: stamp)
            quarantineDirectory = directory
            outcomes.append(contentsOf: await quarantine(privilegedItems, into: directory))
        }

        return RemovalReport(outcomes: outcomes, quarantineDirectory: quarantineDirectory)
    }

    // MARK: - User-level

    private func trash(_ url: URL) -> RemovalOutcome {
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return RemovalOutcome(url: url, succeeded: true, message: "Moved to Trash.")
        } catch {
            return RemovalOutcome(url: url, succeeded: false, message: error.localizedDescription)
        }
    }

    private func isRemovableWithoutElevation(_ url: URL) -> Bool {
        // Deleting an item requires write permission on its parent directory.
        let parent = url.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    // MARK: - Privileged

    /// Moves root-owned items into a quarantine folder in one privileged batch.
    ///
    /// A single elevation covers every item, so the user is prompted once at most —
    /// and not at all once the helper daemon is approved.
    private func quarantine(_ items: [Leftover], into directory: URL) async -> [RemovalOutcome] {
        do {
            let failures = try await privileged.quarantine(items: items.map(\.url), into: directory)
            return items.map { item in
                if let message = failures[item.url.path] {
                    return RemovalOutcome(url: item.url, succeeded: false, message: message)
                }
                return RemovalOutcome(
                    url: item.url,
                    succeeded: true,
                    message: "Moved to quarantine at \(directory.path)."
                )
            }
        } catch {
            return items.map {
                RemovalOutcome(url: $0.url, succeeded: false, message: error.localizedDescription)
            }
        }
    }

    /// Boots out launchd jobs so they stop running and cannot recreate their files.
    private func unloadLaunchJobs(in leftovers: [Leftover]) async {
        let jobs = leftovers.filter { $0.category == .launchItems }
        guard !jobs.isEmpty else { return }

        for job in jobs {
            let label = job.url.deletingPathExtension().lastPathComponent
            let isDaemon = job.url.path.contains("/LaunchDaemons/")

            if isDaemon {
                // Needs elevation. Failure is non-fatal: the file is still removed and
                // the job cannot survive a reboot without it.
                try? await privileged.bootout(label: label, isDaemon: true)
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
            }
        }
    }
}
