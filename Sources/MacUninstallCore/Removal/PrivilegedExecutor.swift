import Foundation

/// Performs the small set of removal actions that require root.
///
/// The interface is intentionally a fixed vocabulary rather than "run this command".
/// Two implementations exist — an authenticated one-shot AppleScript path and a
/// persistent `SMAppService` daemon — and the daemon must never be able to execute
/// arbitrary input, so the narrow interface is what both are held to.
public protocol PrivilegedExecutor: Sendable {

    /// Moves items into a quarantine directory, leaving a manifest behind.
    /// - Returns: Per-path failure messages; empty on full success.
    func quarantine(items: [URL], into directory: URL) async throws -> [String: String]

    /// Unloads a launchd job. Failures are non-fatal and may be ignored by callers.
    func bootout(label: String, isDaemon: Bool) async throws
}

public enum RemovalError: LocalizedError {
    case refusedUnsafePath(URL, ProtectedPaths.Rejection)
    case authorizationFailed
    case authorizationCancelled
    case helperUnavailable(String)
    case helperNeedsApproval

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

    public init() {}

    public func quarantine(items: [URL], into directory: URL) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }

        var script = "/bin/mkdir -p \(Self.shellQuote(directory.path))\n"
        for item in items {
            let destination = directory.appending(path: item.lastPathComponent)
            script += "/bin/mv -f \(Self.shellQuote(item.path)) \(Self.shellQuote(destination.path))\n"
        }

        let manifest = items.map(\.path).joined(separator: "\n")
        let manifestPath = directory.appending(path: "MANIFEST.txt").path
        script += "/bin/cat > \(Self.shellQuote(manifestPath)) <<'MACUNINSTALL_EOF'\n\(manifest)\nMACUNINSTALL_EOF\n"

        try await run(script: script)
        return [:]
    }

    public func bootout(label: String, isDaemon: Bool) async throws {
        let domain = isDaemon ? "system" : "gui/\(getuid())"
        try await run(script: "/bin/launchctl bootout \(Self.shellQuote(domain + "/" + label)) || true\n")
    }

    private func run(script: String) async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scriptURL = directory.appending(path: "removal.sh")
        try Data(("#!/bin/sh\nset -e\n" + script).utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        try await runWithAdministratorPrivileges(scriptPath: scriptURL.path)
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

    @MainActor
    private func runWithAdministratorPrivileges(scriptPath: String) throws {
        let source = """
        do shell script "/bin/sh " & quoted form of "\(scriptPath)" with administrator privileges
        """

        guard let appleScript = NSAppleScript(source: source) else {
            throw RemovalError.authorizationFailed
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            // -128 is the standard "user cancelled" code.
            throw code == -128 ? RemovalError.authorizationCancelled : RemovalError.authorizationFailed
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
