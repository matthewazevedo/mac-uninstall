import Foundation

/// What a privileged quarantine produced.
public struct QuarantineResult: Sendable, Equatable {
    /// Original path to the reason it did not move. Empty on full success.
    public var failures: [String: String]
    /// Original path to where the item now lives.
    ///
    /// Reported rather than inferred: two items from different folders can share a
    /// filename, and the mover renames one of them, so the caller cannot work the
    /// destination out for itself. This is what makes a removal undoable.
    public var destinations: [String: String]

    public init(failures: [String: String] = [:], destinations: [String: String] = [:]) {
        self.failures = failures
        self.destinations = destinations
    }
}

/// One quarantined item and where it came from.
public struct RestoreRequest: Sendable, Hashable {
    public var quarantinedPath: String
    public var originalPath: String

    public init(quarantinedPath: String, originalPath: String) {
        self.quarantinedPath = quarantinedPath
        self.originalPath = originalPath
    }
}

/// Performs the small set of removal actions that require root.
///
/// The interface is intentionally a fixed vocabulary rather than "run this command".
/// Two implementations exist — an authenticated one-shot AppleScript path and a
/// persistent `SMAppService` daemon — and the daemon must never be able to execute
/// arbitrary input, so the narrow interface is what both are held to.
public protocol PrivilegedExecutor: Sendable {

    /// Moves items into a quarantine directory, leaving a manifest behind.
    func quarantine(items: [URL], into directory: URL) async throws -> QuarantineResult

    /// Moves quarantined items back where they came from.
    /// - Returns: Original path to failure message; empty on full success.
    func restore(_ items: [RestoreRequest]) async throws -> [String: String]

    /// Unloads a system launch daemon. Failures are non-fatal and may be ignored.
    ///
    /// Daemons only. A user agent lives in the calling user's own launchd domain,
    /// which the user can reach without elevation — and a root process cannot name
    /// that domain anyway, since its own uid is 0. Leaving the domain out of the
    /// vocabulary is what stops the two from ever being confused.
    func bootoutDaemon(label: String) async throws
}

public enum RemovalError: LocalizedError {
    case refusedUnsafePath(URL, ProtectedPaths.Rejection)
    case authorizationFailed
    case authorizationCancelled
    case helperUnavailable(String)
    case helperNeedsApproval
    case invalidLaunchdLabel(String)

    public var errorDescription: String? {
        switch self {
        case .refusedUnsafePath(let url, let rejection):
            "Refused to remove \(url.path): \(rejection.explanation)"
        case .authorizationFailed:
            "Administrator authorization failed."
        case .authorizationCancelled:
            "Administrator authorization was cancelled."
        case .helperUnavailable(let detail):
            "The privileged helper is unavailable: \(detail)"
        case .helperNeedsApproval:
            "The privileged helper needs to be enabled in System Settings > General > Login Items."
        case .invalidLaunchdLabel(let label):
            "Refused to act on the launchd label \(label), which is not a plain identifier."
        }
    }
}

/// Elevation via `do shell script … with administrator privileges`.
///
/// Every invocation prompts the user, so nothing persists on the system. This is the
/// fallback when the daemon is not installed or the user has not approved it, and it
/// remains the right tool for a one-shot action.
///
/// The script is written to a private per-user temporary directory with `0700`
/// permissions and executed by path rather than interpolated into AppleScript source,
/// so no file path is ever parsed as code.
public struct AppleScriptPrivilegedExecutor: PrivilegedExecutor {

    /// Printed by the generated script for an item that did not move.
    ///
    /// Failures are reported by index rather than by path because a filename may
    /// contain anything at all, including a newline, which no line-based parse of
    /// paths could survive.
    static let failureMarker = "MACUNINSTALL_FAILED"

    public init() {}

    // MARK: - Quarantine

    public func quarantine(items: [URL], into directory: URL) async throws -> QuarantineResult {
        guard !items.isEmpty else { return QuarantineResult() }

        let destinations = Self.destinations(for: items, in: directory)
        let output = try await run(script: Self.quarantineScript(
            items: items, into: directory, destinations: destinations
        ))

        var failures: [String: String] = [:]
        for index in Self.failedIndices(in: output) where items.indices.contains(index) {
            failures[items[index].path] = "Could not be moved to quarantine."
        }

        // Only report a destination for something that actually arrived there.
        var moved = destinations
        for path in failures.keys { moved.removeValue(forKey: path) }
        return QuarantineResult(failures: failures, destinations: moved)
    }

    /// Picks a destination per item, renaming rather than overwriting on a collision.
    ///
    /// Two items from different folders routinely share a filename — every vendor has
    /// exactly one `com.acme.App.plist` per location — and `mv -f` would silently
    /// destroy the first one, in the step whose entire promise is that it is
    /// reversible. The daemon disambiguates the same way.
    static func destinations(for items: [URL], in directory: URL) -> [String: String] {
        var used: Set<String> = []
        var result: [String: String] = [:]

        for item in items {
            var destination = directory.appending(path: item.lastPathComponent).path
            if used.contains(destination) {
                destination = directory
                    .appending(path: "\(UUID().uuidString)-\(item.lastPathComponent)").path
            }
            used.insert(destination)
            result[item.path] = destination
        }
        return result
    }

    static func quarantineScript(
        items: [URL],
        into directory: URL,
        destinations: [String: String]
    ) -> String {
        let manifest = directory.appending(path: "MANIFEST.txt").path
        var script = "/bin/mkdir -p \(shellQuote(directory.path))\n"

        for (index, item) in items.enumerated() {
            guard let destination = destinations[item.path] else { continue }
            // `if` rather than `&&`: the script runs under `set -e`, so one failed
            // move would otherwise abandon every item after it and report the whole
            // batch as failed — including the items that had already moved.
            script += "if /bin/mv -f \(shellQuote(item.path)) \(shellQuote(destination)); then "
            script += "/usr/bin/printf '%s\\n' \(shellQuote(item.path)) >> \(shellQuote(manifest)); "
            script += "else echo \"\(failureMarker) \(index)\"; fi\n"
        }

        script += ownershipCommand(forQuarantine: directory)
        return script
    }

    /// Hands the quarantine tree back to the user who owns it.
    ///
    /// Everything above ran as root, so without this the folder and everything in it
    /// belongs to root — inside the user's own Library, where it can be neither opened
    /// nor restored without authenticating. The daemon does exactly this, for exactly
    /// this reason (`HelperService.handOwnershipToUser`). Skipping it here would make
    /// the promise that quarantined items are recoverable false for every user who has
    /// not yet approved the helper, which is all of them on a first run.
    static func ownershipCommand(forQuarantine directory: URL) -> String {
        // The whole app-owned tree, not just this session's folder, so the
        // intermediate directories `mkdir -p` created are handed over too.
        let target = HelperValidation.quarantineRoot(containing: directory.path) ?? directory.path
        return "/usr/sbin/chown -R \(getuid()):\(getgid()) \(shellQuote(target))\n"
    }

    // MARK: - Restore

    public func restore(_ items: [RestoreRequest]) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }

        let output = try await run(script: Self.restoreScript(items))

        var failures: [String: String] = [:]
        for index in Self.failedIndices(in: output) where items.indices.contains(index) {
            failures[items[index].originalPath] = "Could not be moved back."
        }
        return failures
    }

    static func restoreScript(_ items: [RestoreRequest]) -> String {
        var script = ""
        for (index, item) in items.enumerated() {
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            // Never overwrite: something may have been reinstalled into that path
            // since the removal, and putting the old copy back would destroy it.
            script += "if [ -e \(shellQuote(item.originalPath)) ]; then "
            script += "echo \"\(failureMarker) \(index)\"; "
            script += "elif /bin/mkdir -p \(shellQuote(parent)) "
            script += "&& /bin/mv -f \(shellQuote(item.quarantinedPath)) \(shellQuote(item.originalPath)); then "
            script += "/usr/sbin/chown -R \(ownerSpec(for: item.originalPath)) \(shellQuote(item.originalPath)); "
            script += "else echo \"\(failureMarker) \(index)\"; fi\n"
        }
        return script
    }

    /// Ownership a restored item should have, from where it is going back to.
    ///
    /// Quarantined items were handed to the user so the folder could be opened, so a
    /// straight move back would leave a user-writable file in a system location — and
    /// a user-writable launch daemon is a local privilege escalation, which is the
    /// kind of thing this app exists to clean up rather than create.
    static func ownerSpec(for destination: String) -> String {
        destination.hasPrefix("/Users/") ? "\(getuid()):\(getgid())" : "0:0"
    }

    // MARK: - Launchd

    public func bootoutDaemon(label: String) async throws {
        guard HelperValidation.isValidLaunchdLabel(label) else {
            throw RemovalError.invalidLaunchdLabel(label)
        }
        // A job that was not loaded is not a failure worth prompting about.
        _ = try await run(script: "/bin/launchctl bootout \(Self.shellQuote("system/" + label)) || true\n")
    }

    // MARK: - Execution

    @discardableResult
    private func run(script: String) async throws -> String {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appending(path: "removal.sh")
        try Data(("#!/bin/sh\nset -e\n" + script).utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        return try await runWithAdministratorPrivileges(scriptPath: scriptURL.path)
    }

    /// Creates a `0700` directory inside the per-user temporary area.
    private func makePrivateDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = base.appending(path: "MacUninstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    /// - Returns: Whatever the script wrote to standard output, which is how it
    ///   reports the items it could not move.
    @MainActor
    private func runWithAdministratorPrivileges(scriptPath: String) throws -> String {
        let source = """
        do shell script "/bin/sh " & quoted form of "\(scriptPath)" with administrator privileges
        """

        guard let appleScript = NSAppleScript(source: source) else {
            throw RemovalError.authorizationFailed
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            // -128 is the standard "user cancelled" code.
            throw code == -128 ? RemovalError.authorizationCancelled : RemovalError.authorizationFailed
        }
        return result.stringValue ?? ""
    }

    static func failedIndices(in output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(failureMarker) else { return nil }
            return Int(trimmed.dropFirst(failureMarker.count).trimmingCharacters(in: .whitespaces))
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
