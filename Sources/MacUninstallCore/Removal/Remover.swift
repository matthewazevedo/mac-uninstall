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

public enum RemovalError: LocalizedError {
    case refusedUnsafePath(URL, ProtectedPaths.Rejection)
    case authorizationFailed
    case authorizationCancelled

    public var errorDescription: String? {
        switch self {
        case .refusedUnsafePath(let url, let rejection):
            "Refused to remove \(url.path): \(rejection.explanation)"
        case .authorizationFailed:
            "Administrator authorization failed."
        case .authorizationCancelled:
            "Administrator authorization was cancelled."
        }
    }
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

    public init(options: Options = .init(), privileged: PrivilegedExecutor = AppleScriptPrivilegedExecutor()) {
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

    /// Moves root-owned items into a quarantine folder in one authenticated batch.
    ///
    /// A single elevation covers all items, so the user sees one password prompt
    /// rather than one per file.
    private func quarantine(_ items: [Leftover], into directory: URL) async -> [RemovalOutcome] {
        var script = "set -e\n"
        script += "/bin/mkdir -p \(shellQuote(directory.path))\n"

        for item in items {
            let destination = directory.appending(path: item.url.lastPathComponent)
            script += "/bin/mv -f \(shellQuote(item.url.path)) \(shellQuote(destination.path))\n"
        }

        // Leave a manifest so the move is auditable and reversible by hand.
        let manifest = items.map(\.url.path).joined(separator: "\n")
        let manifestPath = directory.appending(path: "MANIFEST.txt").path
        script += "/bin/cat > \(shellQuote(manifestPath)) <<'MACUNINSTALL_EOF'\n\(manifest)\nMACUNINSTALL_EOF\n"

        do {
            try await privileged.run(script: script)
            return items.map {
                RemovalOutcome(url: $0.url, succeeded: true, message: "Moved to quarantine at \(directory.path).")
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
            let domain = isDaemon ? "system" : "gui/\(getuid())"

            if isDaemon {
                // Requires elevation; failure is non-fatal since the file removal
                // still happens and the job will not survive a reboot.
                try? await privileged.run(script: "/bin/launchctl bootout \(domain)/\(label) || true\n")
            } else {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", "\(domain)/\(label)"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
