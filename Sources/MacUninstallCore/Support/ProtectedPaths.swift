import Foundation

/// Last line of defence before anything is removed.
///
/// Every path is checked here immediately before deletion, regardless of how it
/// entered the plan. A scanner bug, a malicious app name, or a symlink pointing
/// somewhere unexpected must not be able to turn this app into `rm -rf /`.
public enum ProtectedPaths {

    /// Paths that must never be removed under any circumstances.
    public static let exactProtected: Set<String> = {
        var paths: Set<String> = [
            "/", "/Applications", "/Applications/Utilities", "/Library", "/System",
            "/Users", "/bin", "/sbin", "/usr", "/usr/bin", "/usr/local", "/etc",
            "/var", "/private", "/private/var", "/private/etc", "/tmp", "/opt", "/cores",
            "/Volumes", "/Network", "/System/Applications", "/System/Library",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
            "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/Extensions",
            "/Library/PrivilegedHelperTools", "/Library/Logs", "/Library/Internet Plug-Ins",
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for sub in [
            "", "/Library", "/Desktop", "/Documents", "/Downloads", "/Movies", "/Music",
            "/Pictures", "/Public", "/Applications", "/.Trash",
            "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
            "/Library/Containers", "/Library/Group Containers", "/Library/Logs",
            "/Library/LaunchAgents", "/Library/Saved Application State",
            "/Library/HTTPStorages", "/Library/WebKit", "/Library/Cookies",
            "/Library/Application Scripts", "/Library/Internet Plug-Ins",
            "/Library/Mobile Documents", "/Library/Keychains", "/Library/CloudStorage",
        ] {
            paths.insert(home + sub)
        }
        return paths
    }()

    /// Directory trees we refuse to touch even for descendants, because damage
    /// there is unrecoverable or breaks the OS.
    public static let protectedTrees: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/etc",
            "/private/etc", "/dev", "/Network", "/cores",
            home + "/Library/Keychains",
            home + "/Library/Mobile Documents",   // iCloud Drive
            home + "/Library/CloudStorage",        // Dropbox/OneDrive/Drive mounts
        ]
    }()

    /// The only roots a leftover may legitimately live under. Anything outside
    /// these is rejected, which bounds the blast radius to app-data territory.
    public static let allowedRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "/Library",
            "/usr/local/lib",
            "/private/var/db/receipts",
            "/var/db/receipts",
            home + "/Applications",
            home + "/Library",
        ]
    }()

    /// Reasons a path may be rejected, so the UI can explain the refusal.
    public enum Rejection: Sendable, Equatable {
        case protectedExactPath
        case insideProtectedTree(String)
        case outsideAllowedRoots
        case tooShallow
        case notAbsolute
        case symlinkEscapesAllowedRoots(String)

        public var explanation: String {
            switch self {
            case .protectedExactPath:
                "This is a system or top-level user folder and can never be removed."
            case .insideProtectedTree(let tree):
                "Inside the protected location \(tree)."
            case .outsideAllowedRoots:
                "Outside the folders where application data is expected to live."
            case .tooShallow:
                "Too close to the filesystem root to be app data."
            case .notAbsolute:
                "Not an absolute path."
            case .symlinkEscapesAllowedRoots(let target):
                "Resolves through a symbolic link to \(target), outside the allowed folders."
            }
        }
    }

    /// Returns `nil` when the path is safe to remove, or the reason it is not.
    ///
    /// The symlink check resolves the path first so a link planted inside a scanned
    /// folder cannot redirect a deletion outside the allowed roots.
    public static func rejection(for url: URL) -> Rejection? {
        let path = url.standardizedFileURL.path

        guard path.hasPrefix("/") else { return .notAbsolute }
        if exactProtected.contains(path) { return .protectedExactPath }

        for tree in protectedTrees where path == tree || path.hasPrefix(tree + "/") {
            return .insideProtectedTree(tree)
        }

        // Require real depth, so a stray two-component path cannot slip through.
        // Application bundles are the deliberate exception: `/Applications/Acme.app`
        // is only two components and is the most common removal target of all.
        let components = path.split(separator: "/")
        if components.count < 3 && !isDirectChildOfApplications(path) {
            return .tooShallow
        }

        guard isUnder(allowedRoots, path: path) else { return .outsideAllowedRoots }

        // A symlink must not lead somewhere we would otherwise refuse.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved != path {
            if exactProtected.contains(resolved) { return .symlinkEscapesAllowedRoots(resolved) }
            for tree in protectedTrees where resolved == tree || resolved.hasPrefix(tree + "/") {
                return .symlinkEscapesAllowedRoots(resolved)
            }
            guard isUnder(allowedRoots, path: resolved) else {
                return .symlinkEscapesAllowedRoots(resolved)
            }
        }

        return nil
    }

    public static func isSafeToRemove(_ url: URL) -> Bool {
        rejection(for: url) == nil
    }

    private static func isUnder(_ roots: [String], path: String) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") }
    }

    /// True for `/Applications/Acme.app` and `~/Applications/Acme.app`, the only
    /// legitimate removal targets shallow enough to trip the depth rule.
    private static func isDirectChildOfApplications(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parents = ["/Applications", home + "/Applications"]
        let parent = (path as NSString).deletingLastPathComponent
        return parents.contains(parent)
    }
}
