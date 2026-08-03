import Foundation

/// Argument checks the root daemon applies to everything it receives.
///
/// These live in the shared library rather than in the helper executable so they can
/// be tested directly. They are the daemon's own checks, independent of anything the
/// client already validated — the client is not trusted.
public enum HelperValidation {

    /// The quarantine destination must be a real user's MacUninstall quarantine area.
    ///
    /// Without this the caller could name any destination, turning "move a file with
    /// root privileges" into "write anywhere on the system".
    public static func isAcceptableQuarantineDirectory(_ directory: String) -> Bool {
        let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
        guard standardized.hasPrefix("/Users/") else { return false }
        guard standardized.contains("/Library/Application Support/MacUninstall/Quarantine/") else {
            return false
        }
        // `standardizedFileURL` resolves `..`, but reject any residual traversal too.
        return !standardized.contains("/../") && !directory.contains("/../")
    }

    /// Launchd labels are reverse-DNS style identifiers and nothing else.
    ///
    /// The label is concatenated into a launchd domain target, so anything exotic —
    /// a slash, a space, a traversal — could reach a domain the caller did not name.
    public static func isValidLaunchdLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 256 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return label.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !label.contains("..")
    }
}
