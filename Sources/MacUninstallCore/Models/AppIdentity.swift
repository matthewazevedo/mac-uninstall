import Foundation

/// Everything we know about an installed app, used to recognise its leftovers.
///
/// A single bundle identifier is nowhere near enough. Real apps scatter files under
/// vendor names (`~/Library/Application Support/Google`), team identifiers, helper
/// bundle IDs, App Store item IDs, and — for Electron wrappers — completely opaque
/// identifiers such as `com.todesktop.230313mzl4w4u92`. Every one of those is a
/// separate signal, so we collect them all up front and match on the union.
public struct AppIdentity: Sendable, Hashable, Codable {
    /// Location of the `.app` bundle itself.
    public var bundleURL: URL
    /// `CFBundleIdentifier`, e.g. `com.anthropic.claudefordesktop`.
    public var bundleID: String?
    /// User-facing name without the `.app` extension, e.g. `Claude`.
    public var displayName: String
    /// `CFBundleExecutable`, which often names log and cache folders.
    public var executableName: String?
    /// Developer team identifier from the code signature, e.g. `Q6L2SF6YDW`.
    public var teamID: String?
    /// Organisation from the signing authority, e.g. `Anthropic PBC`.
    public var signingOrganization: String?
    /// Mac App Store item identifier, which appears in prefs as `<digits>.plist`.
    public var appStoreItemID: String?
    /// Bundle identifiers of nested helpers, XPC services, and login items.
    public var helperBundleIDs: Set<String>
    /// Custom URL schemes the app registers, e.g. `claude`.
    public var urlSchemes: Set<String>
    /// Version string, shown in the UI so the user knows what they are removing.
    public var version: String?

    public init(
        bundleURL: URL,
        bundleID: String? = nil,
        displayName: String,
        executableName: String? = nil,
        teamID: String? = nil,
        signingOrganization: String? = nil,
        appStoreItemID: String? = nil,
        helperBundleIDs: Set<String> = [],
        urlSchemes: Set<String> = [],
        version: String? = nil
    ) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.displayName = displayName
        self.executableName = executableName
        self.teamID = teamID
        self.signingOrganization = signingOrganization
        self.appStoreItemID = appStoreItemID
        self.helperBundleIDs = helperBundleIDs
        self.urlSchemes = urlSchemes
        self.version = version
    }
}

public extension AppIdentity {
    /// The reverse-DNS prefix shared by the app and its helpers, e.g.
    /// `com.google` for `com.google.Chrome`. Used to catch sibling bundle IDs
    /// like `com.google.Keystone.Agent` that no other signal would find.
    var reverseDNSPrefix: String? {
        guard let bundleID else { return nil }
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }

    /// Candidate vendor names for matching folders such as
    /// `~/Library/Application Support/BraveSoftware`.
    ///
    /// Derived from the signing organisation and from the company segment of the
    /// bundle identifier, since those are the two forms vendors actually use.
    var vendorNames: Set<String> {
        var names: Set<String> = []

        if let org = signingOrganization {
            // Trim legal suffixes and their punctuation, so "Turing Software, LLC"
            // yields "Turing Software" rather than "Turing Software,".
            let suffixes: Set<String> = ["inc", "llc", "ltd", "pbc", "corp", "gmbh",
                                         "co", "sa", "bv", "ab", "oy", "plc", "kk", "ag"]
            let punctuation = CharacterSet(charactersIn: ".,;")
            var words = org.split(separator: " ")
                .map { $0.trimmingCharacters(in: punctuation) }
                .filter { !$0.isEmpty }
            while let last = words.last,
                  suffixes.contains(last.lowercased().replacingOccurrences(of: ".", with: "")) {
                words.removeLast()
            }
            if !words.isEmpty {
                names.insert(words.joined(separator: " "))
                names.insert(words.joined())
            }
        }

        // `com.brave.Browser` -> `brave`; skip generic TLD-ish leading segments.
        if let bundleID {
            let parts = bundleID.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                let generic: Set<String> = ["com", "org", "net", "io", "co", "app", "dev", "me"]
                if let vendor = parts.first(where: { !generic.contains($0.lowercased()) }) {
                    names.insert(vendor)
                }
            }
        }

        // Never match on something so short it would hit unrelated folders.
        return names.filter { $0.count >= 3 }
    }

    /// False for apps macOS protects: Apple's own apps under `/System`, and anything
    /// reached through a symlink into a cryptex such as Safari.
    ///
    /// Their leftovers are still ordinary files the user may want to clear, but the
    /// bundle itself cannot be removed, so the UI must not offer to. This defers to
    /// ``ProtectedPaths`` rather than pattern-matching paths, so there is one source of
    /// truth for what is untouchable.
    var isRemovable: Bool { ProtectedPaths.isSafeToRemove(bundleURL) }

    /// Every identifier that, seen as a file or folder name, is near-certain
    /// evidence of this specific app.
    var strongIdentifiers: Set<String> {
        var ids: Set<String> = []
        if let bundleID { ids.insert(bundleID) }
        ids.formUnion(helperBundleIDs)
        if let appStoreItemID { ids.insert(appStoreItemID) }
        return ids
    }
}
