import Foundation

/// One directory to sweep for leftovers, plus how to interpret what is found there.
public struct SearchLocation: Sendable {
    public var url: URL
    public var category: LeftoverCategory
    /// Removing items here needs elevation.
    public var requiresAdmin: Bool
    /// When true, only direct children are considered; when false, the scanner
    /// also inspects one level deeper. Preferences are flat; Application Support
    /// nests vendor folders one level down.
    public var childrenOnly: Bool

    public init(url: URL, category: LeftoverCategory, requiresAdmin: Bool = false, childrenOnly: Bool = true) {
        self.url = url
        self.category = category
        self.requiresAdmin = requiresAdmin
        self.childrenOnly = childrenOnly
    }
}

public enum SearchLocations {

    /// Every location an app is known to write to, assembled fresh so tests can
    /// run against a redirected home directory.
    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SearchLocation] {
        let lib = home.appending(path: "Library")
        let root = URL(fileURLWithPath: "/Library")

        var locations: [SearchLocation] = [
            // ---- User level -------------------------------------------------
            .init(url: lib.appending(path: "Application Support"), category: .supportFiles, childrenOnly: false),
            .init(url: lib.appending(path: "Caches"), category: .caches, childrenOnly: false),
            .init(url: lib.appending(path: "Preferences"), category: .preferences, childrenOnly: false),
            .init(url: lib.appending(path: "Preferences/ByHost"), category: .preferences),
            .init(url: lib.appending(path: "Containers"), category: .containers),
            .init(url: lib.appending(path: "Group Containers"), category: .containers),
            .init(url: lib.appending(path: "Application Scripts"), category: .containers),
            .init(url: lib.appending(path: "Logs"), category: .logs, childrenOnly: false),
            .init(url: lib.appending(path: "Saved Application State"), category: .savedState),
            .init(url: lib.appending(path: "HTTPStorages"), category: .cookiesAndStorage),
            .init(url: lib.appending(path: "WebKit"), category: .cookiesAndStorage),
            .init(url: lib.appending(path: "Cookies"), category: .cookiesAndStorage),
            .init(url: lib.appending(path: "LaunchAgents"), category: .launchItems),
            .init(url: lib.appending(path: "Internet Plug-Ins"), category: .plugins),
            .init(url: lib.appending(path: "QuickLook"), category: .plugins),
            .init(url: lib.appending(path: "Services"), category: .plugins),
            .init(url: lib.appending(path: "Screen Savers"), category: .plugins),
            .init(url: lib.appending(path: "Automator"), category: .plugins),
            .init(url: lib.appending(path: "Spelling"), category: .supportFiles),
            .init(url: lib.appending(path: "Fonts"), category: .supportFiles),
            .init(url: lib.appending(path: "PreferencePanes"), category: .plugins),
            .init(url: lib.appending(path: "Widgets"), category: .plugins),
            .init(url: lib.appending(path: "Frameworks"), category: .supportFiles),
            .init(url: lib.appending(path: "Developer"), category: .supportFiles),

            // ---- Machine level (admin) -------------------------------------
            .init(url: root.appending(path: "Application Support"), category: .supportFiles, requiresAdmin: true, childrenOnly: false),
            .init(url: root.appending(path: "Caches"), category: .caches, requiresAdmin: true, childrenOnly: false),
            .init(url: root.appending(path: "Preferences"), category: .preferences, requiresAdmin: true),
            .init(url: root.appending(path: "Logs"), category: .logs, requiresAdmin: true, childrenOnly: false),
            .init(url: root.appending(path: "LaunchAgents"), category: .launchItems, requiresAdmin: true),
            .init(url: root.appending(path: "LaunchDaemons"), category: .launchItems, requiresAdmin: true),
            .init(url: root.appending(path: "PrivilegedHelperTools"), category: .privilegedHelpers, requiresAdmin: true),
            .init(url: root.appending(path: "Extensions"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "Internet Plug-Ins"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "PreferencePanes"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "QuickLook"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "Services"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "Screen Savers"), category: .plugins, requiresAdmin: true),
            .init(url: root.appending(path: "Frameworks"), category: .supportFiles, requiresAdmin: true),
            .init(url: URL(fileURLWithPath: "/private/var/db/receipts"), category: .receipts, requiresAdmin: true),
            .init(url: URL(fileURLWithPath: "/usr/local/lib"), category: .supportFiles, requiresAdmin: true),
        ]

        // Only keep locations that exist, so the scan does not waste time or
        // report noise for folders this Mac has never created.
        let fm = FileManager.default
        locations = locations.filter { fm.fileExists(atPath: $0.url.path) }
        return locations
    }

    /// Locations that are protected by Full Disk Access and therefore act as a
    /// probe for whether the app has been granted it.
    public static func fullDiskAccessProbes(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appending(path: "Library/Safari"),
            home.appending(path: "Library/Cookies"),
            home.appending(path: "Library/Application Support/com.apple.TCC"),
        ]
    }
}
