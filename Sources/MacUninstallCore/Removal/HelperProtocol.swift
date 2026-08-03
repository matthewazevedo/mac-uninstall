import Foundation

/// Names shared between the app and the privileged helper.
public enum HelperConstants {
    /// Mach service the daemon vends. Must match the `MachServices` key in the
    /// daemon's launchd plist.
    public static let machServiceName = "com.macuninstall.helper"

    /// Filename of the launchd plist inside `Contents/Library/LaunchDaemons`.
    public static let daemonPlistName = "com.macuninstall.helper.plist"

    /// Bumped whenever the protocol changes, so the app can detect a stale daemon
    /// left behind by a previous install and re-register it.
    public static let protocolVersion = 1
}

/// The complete set of operations the root daemon will perform.
///
/// Deliberately narrow. An earlier design passed a shell script across this boundary,
/// which is acceptable for a one-shot authenticated prompt but not for a daemon that
/// stays installed: anything able to reach the Mach service would get arbitrary root
/// execution. Every operation here is a specific, bounded action whose arguments the
/// helper re-validates before acting.
///
/// `@objc` and reply-block shaped because this crosses `NSXPCConnection`.
@objc public protocol HelperProtocol {

    /// Moves `paths` into `directory`, writing a manifest of their original locations.
    ///
    /// The helper independently rejects any path that fails ``ProtectedPaths``, so a
    /// compromised or buggy client cannot direct it at the system.
    ///
    /// - Parameter reply: Per-path error strings, empty when everything succeeded.
    func quarantine(
        paths: [String],
        into directory: String,
        reply: @escaping ([String: String]) -> Void
    )

    /// Unloads a launchd job so it stops running and cannot recreate its own files.
    func bootout(label: String, isDaemon: Bool, reply: @escaping (String?) -> Void)

    /// Protocol version of the installed daemon, used to detect a stale build.
    func version(reply: @escaping (Int) -> Void)
}
