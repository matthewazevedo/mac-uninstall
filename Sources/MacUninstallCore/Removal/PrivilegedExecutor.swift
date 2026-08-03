import Foundation

/// Runs a shell script with administrator rights.
///
/// Abstracted behind a protocol for two reasons: tests must never trigger a real
/// password prompt, and the implementation is expected to move to a bundled
/// `SMAppService` helper once the app is signed with a Developer ID.
public protocol PrivilegedExecutor: Sendable {
    func run(script: String) async throws
}

/// Elevation via `do shell script … with administrator privileges`.
///
/// The script is written to a private per-user temporary directory with `0700`
/// permissions and executed by path, rather than being interpolated into the
/// AppleScript source. That avoids quoting bugs and means no file path or app name
/// is ever parsed as AppleScript.
public struct AppleScriptPrivilegedExecutor: PrivilegedExecutor {

    public init() {}

    public func run(script: String) async throws {
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
        // The path contains only a UUID we generated, so it needs no escaping —
        // but quote it anyway so the script is well-formed regardless.
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
}
