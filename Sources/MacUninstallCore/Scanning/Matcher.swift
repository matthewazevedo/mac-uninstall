import Foundation

/// Decides whether a given file or folder name belongs to a specific app.
///
/// The rules are ordered from unambiguous to speculative, and the first hit wins.
/// Each result carries the reason it matched so the UI can show the user exactly
/// why a file is on the chopping block.
public struct Matcher: Sendable {

    public struct Match: Sendable, Equatable {
        public var confidence: Confidence
        public var reason: String
    }

    /// Names too generic to match on. A folder called `Updater` or an app called
    /// `Notes` must never sweep in unrelated files.
    static let genericNames: Set<String> = [
        "app", "application", "applications", "updater", "update", "helper", "agent",
        "service", "services", "daemon", "tools", "utility", "utilities", "common",
        "shared", "data", "cache", "caches", "logs", "temp", "tmp", "user", "users",
        "default", "defaults", "settings", "preferences", "config", "support",
        "notes", "music", "mail", "photos", "calendar", "contacts", "reminders",
        "safari", "finder", "system", "library", "desktop", "documents", "downloads",
        "installer", "setup", "launcher", "core", "main", "base", "framework",
    ]

    /// Apple-owned prefixes we never attribute to a third-party app.
    static let appleReservedPrefixes = ["com.apple.", "group.com.apple."]

    /// True for files owned by macOS itself.
    ///
    /// System preference files are shared registries: `com.apple.dock.plist` names
    /// every app with a Dock tile, and `com.apple.networkextension.plist` names every
    /// VPN client. Being mentioned in one is normal and is never evidence of
    /// ownership — deleting them would wipe the user's Dock or network configuration.
    public static func isAppleOwned(name: String) -> Bool {
        let lowered = name.lowercased()
        return appleReservedPrefixes.contains { lowered.hasPrefix($0) }
    }

    let identity: AppIdentity

    public init(identity: AppIdentity) {
        self.identity = identity
    }

    /// Evaluates a directory entry name, e.g. `com.acme.App.plist` or `Acme`.
    ///
    /// - Parameters:
    ///   - name: The last path component as it appears on disk.
    ///   - isDirectory: Directories and files use slightly different name shapes.
    public func match(name: String, isDirectory: Bool) -> Match? {
        let stem = Self.stem(of: name, isDirectory: isDirectory)
        let loweredStem = stem.lowercased()

        // Never attribute Apple's own files to a third-party app, unless the app
        // genuinely is Apple's (its own bundle ID would then share the prefix).
        let ownBundleIsApple = identity.bundleID.map { id in
            Self.appleReservedPrefixes.contains { id.hasPrefix($0) }
        } ?? false
        if !ownBundleIsApple,
           Self.appleReservedPrefixes.contains(where: { loweredStem.hasPrefix($0) }) {
            return nil
        }

        // 1. Exact or dotted-prefix match on a bundle identifier we know belongs
        //    to this app. `com.acme.App` also claims `com.acme.App.helper`.
        for identifier in identity.strongIdentifiers where !identifier.isEmpty {
            if Self.matchesIdentifier(stem: loweredStem, identifier: identifier.lowercased()) {
                return Match(
                    confidence: .certain,
                    reason: "Matches the app's identifier \(identifier)."
                )
            }
        }

        // 2. A sibling identifier under the same reverse-DNS prefix. This finds
        //    shared updaters such as com.google.Keystone.Agent, which belong to
        //    the vendor but may be used by their other apps too.
        if let prefix = identity.reverseDNSPrefix?.lowercased(),
           loweredStem.hasPrefix(prefix + ".") {
            return Match(
                confidence: .likely,
                reason: "Shares the identifier prefix \(prefix) with this app."
            )
        }

        // 3. The executable name, which commonly names log and crash folders.
        if let executable = identity.executableName,
           Self.isDistinctive(executable),
           loweredStem == executable.lowercased() {
            return Match(
                confidence: .likely,
                reason: "Named after the app's executable \(executable)."
            )
        }

        // 4. The display name, e.g. a folder literally called `Fastmail`.
        if Self.isDistinctive(identity.displayName),
           loweredStem == identity.displayName.lowercased()
            || loweredStem == identity.displayName.lowercased().replacingOccurrences(of: " ", with: "") {
            return Match(
                confidence: .likely,
                reason: "Named after the app \(identity.displayName)."
            )
        }

        // 5. Vendor-level folders. Shared with the vendor's other products, so
        //    this is surfaced for review and never auto-selected.
        for vendor in identity.vendorNames where Self.isDistinctive(vendor) {
            if loweredStem == vendor.lowercased()
                || loweredStem == vendor.lowercased().replacingOccurrences(of: " ", with: "") {
                return Match(
                    confidence: .possible,
                    reason: "Belongs to the vendor \(vendor). Other apps from the same vendor may share it."
                )
            }
        }

        // 6. Team identifier prefixes, used by group containers such as
        //    `Q6L2SF6YDW.com.acme.shared`.
        if let team = identity.teamID?.lowercased(), loweredStem.hasPrefix(team + ".") {
            return Match(
                confidence: .likely,
                reason: "Registered to the developer team \(identity.teamID ?? team)."
            )
        }

        return nil
    }

    /// True when `stem` is the identifier itself or a dot/dash-separated child of it.
    ///
    /// The separator requirement stops `com.acme.App` from claiming
    /// `com.acme.AppStoreThing`, which is a different product.
    static func matchesIdentifier(stem: String, identifier: String) -> Bool {
        if stem == identifier { return true }
        guard stem.hasPrefix(identifier) else { return false }
        let next = stem[stem.index(stem.startIndex, offsetBy: identifier.count)]
        return next == "." || next == "-" || next == "_"
    }

    /// Strips the extensions that carry no identity, so `com.acme.App.plist`
    /// and `com.acme.App.savedState` both reduce to `com.acme.App`.
    static func stem(of name: String, isDirectory: Bool) -> String {
        let strippable = [
            ".plist", ".savedState", ".binarycookies", ".bom", ".app", ".sfl2", ".sfl3",
            ".lockfile", ".log",
        ]
        var stem = name
        for ext in strippable where stem.lowercased().hasSuffix(ext.lowercased()) {
            stem = String(stem.dropLast(ext.count))
            break
        }
        return stem
    }

    /// Rejects names that are too short or too common to be evidence.
    static func isDistinctive(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.count >= 4 && !genericNames.contains(trimmed)
    }
}
