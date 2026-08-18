import Foundation

/// Leftovers that share one bundle-identifier-shaped name whose app is gone.
public struct OrphanGroup: Sendable, Identifiable, Hashable, Codable {
    public var id: String { identifier }
    /// The identifier every item in the group belongs to, e.g. `com.acme.App`.
    public var identifier: String
    public var leftovers: [Leftover]

    public init(identifier: String, leftovers: [Leftover]) {
        self.identifier = identifier
        self.leftovers = leftovers
    }

    public var totalSizeBytes: Int64 { leftovers.compactMap(\.sizeBytes).reduce(0, +) }
    public var totalSizeIsPartial: Bool { leftovers.contains { $0.sizeIsPartial } }
}

/// Finds data belonging to apps that are no longer installed.
///
/// Every other entry point starts from a bundle on disk, which means the app cannot
/// help at the moment people most want it to: after something has already been
/// dragged to the Trash and the Trash emptied. There is no identity to match against
/// then — so this works the other way round, reading the identifiers the filesystem
/// already holds and subtracting everything that still has an app behind it.
///
/// Deliberately narrow. Only names shaped like bundle identifiers are considered: a
/// folder called `Acme` could belong to anything, and guessing at it would propose
/// deletions with no evidence behind them. Everything found is reported at
/// ``Confidence/possible``, because an identifier with no installed app is a strong
/// hint and not a proof — the app may live on an external disk, or simply not be
/// where this looks.
public struct OrphanScanner: Sendable {

    public struct Options: Sendable {
        public var measureSizes: Bool
        public var safetyCheck: @Sendable (URL) -> Bool

        public init(
            measureSizes: Bool = true,
            safetyCheck: @escaping @Sendable (URL) -> Bool = { ProtectedPaths.isSafeToRemove($0) }
        ) {
            self.measureSizes = measureSizes
            self.safetyCheck = safetyCheck
        }
    }

    let locations: [SearchLocation]
    let options: Options

    public init(
        locations: [SearchLocation] = SearchLocations.standard(),
        options: Options = .init()
    ) {
        self.locations = locations
        self.options = options
    }

    /// - Parameter installedApps: Everything still installed. Anything belonging to
    ///   one of these — or merely sharing its vendor namespace — is left alone.
    public func scan(installedApps: [AppIdentity]) async -> [OrphanGroup] {
        let live = LiveIdentifiers(apps: installedApps)

        let found = await withTaskGroup(of: [Leftover].self) { group in
            for location in locations {
                group.addTask { self.sweep(location, live: live) }
            }
            var all: [Leftover] = []
            for await leftovers in group { all.append(contentsOf: leftovers) }
            return all
        }

        var measured = LeftoverScanner.ordered(found)
        if options.measureSizes {
            measured = await LeftoverScanner(locations: []).measureSizes(for: measured)
        }

        return Self.grouped(measured)
    }

    private func sweep(_ location: SearchLocation, live: LiveIdentifiers) -> [Leftover] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: location.url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }

        let liveReceiptStems = location.category == .receipts
            ? Self.liveReceiptStems(in: entries, live: live)
            : []

        var found: [Leftover] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let stem = Matcher.stem(of: entry.lastPathComponent, isDirectory: isDirectory)

            guard Matcher.looksLikeBundleIdentifier(stem),
                  !Matcher.isAppleOwned(name: stem),
                  !live.claims(stem),
                  !live.claims(Self.normalized(stem)),
                  !liveReceiptStems.contains(stem),
                  options.safetyCheck(entry) else { continue }

            found.append(Leftover(
                url: entry,
                category: location.category,
                // Never more than this. Nothing here was matched against an app —
                // the evidence is the absence of one.
                confidence: .possible,
                reason: "Belongs to \(Self.groupIdentifier(for: stem)), which is not installed.",
                requiresAdmin: location.requiresAdmin
            ))
        }
        return found
    }

    /// A `.pkg` receipt's `PackageIdentifier` is Apple's installer namespace, which
    /// vendors are free to keep entirely separate from their app's own
    /// `CFBundleIdentifier` — Tailscale's receipt is `com.tailscale.ipn.macsys` for an
    /// app whose bundle ID is `io.tailscale.ipn.macsys`. No bundle-ID heuristic
    /// bridges that gap, so this reads what the receipt itself says it installed
    /// (`InstallPrefixPath`) instead of guessing from its name. Read once per
    /// directory rather than per file, because a receipt's sibling `.bom` carries the
    /// same stem but isn't itself a plist.
    static func liveReceiptStems(in entries: [URL], live: LiveIdentifiers) -> Set<String> {
        var stems: Set<String> = []
        for entry in entries where entry.pathExtension == "plist" {
            guard let plist = AppScanner.readPlist(at: entry),
                  let prefix = plist["InstallPrefixPath"] as? String,
                  live.claimsPath("/" + prefix) else { continue }
            stems.insert(Matcher.stem(of: entry.lastPathComponent, isDirectory: false))
        }
        return stems
    }

    static func grouped(_ leftovers: [Leftover]) -> [OrphanGroup] {
        var groups: [String: [Leftover]] = [:]
        for leftover in leftovers {
            let stem = Matcher.stem(of: leftover.url.lastPathComponent, isDirectory: false)
            groups[groupIdentifier(for: stem), default: []].append(leftover)
        }

        return groups
            .map { OrphanGroup(identifier: $0.key, leftovers: $0.value) }
            // Biggest first: the reason to run this is to reclaim space, and an
            // identifier is not something anyone wants to read alphabetically.
            .sorted {
                if $0.totalSizeBytes != $1.totalSizeBytes {
                    return $0.totalSizeBytes > $1.totalSizeBytes
                }
                return $0.identifier < $1.identifier
            }
    }

    /// `com.acme.App.helper` and `com.acme.App` are one app's data, so they are one
    /// group. Three segments is where a vendor's namespace stops and a product
    /// begins, in the convention Apple documents and vendors follow.
    static func groupIdentifier(for stem: String) -> String {
        let parts = normalized(stem).split(separator: ".")
        guard parts.count > 3 else { return normalized(stem) }
        return parts.prefix(3).joined(separator: ".")
    }

    /// Drops the wrappers that sit in front of a real identifier.
    ///
    /// Group containers are named `Q6L2SF6YDW.com.acme.shared` or
    /// `group.com.acme.shared`, so the identifier that decides whether an app still
    /// owns this folder is not at the start of the name. Reading it as one would list
    /// an installed app's group container as an orphan.
    static func normalized(_ stem: String) -> String {
        var parts = stem.split(separator: ".").map(String.init)
        var stripped = 0
        while parts.count > 3, stripped < 2, let first = parts.first,
              first.lowercased() == "group" || isTeamIdentifier(first) {
            parts.removeFirst()
            stripped += 1
        }
        return parts.joined(separator: ".")
    }

    /// Apple issues these as ten upper-case alphanumerics, e.g. `Q6L2SF6YDW`.
    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { ($0.isLetter && $0.isUppercase) || $0.isNumber }
    }

}

/// The identifiers that still have an app behind them.
struct LiveIdentifiers: Sendable {
    private let identifiers: Set<String>
    private let prefixes: Set<String>
    private let installedPaths: Set<String>

    init(apps: [AppIdentity]) {
        var identifiers: Set<String> = []
        var prefixes: Set<String> = []
        var installedPaths: Set<String> = []
        for app in apps {
            for identifier in app.strongIdentifiers { identifiers.insert(identifier.lowercased()) }
            if let prefix = app.reverseDNSPrefix { prefixes.insert(prefix.lowercased()) }
            installedPaths.insert(app.bundleURL.standardizedFileURL.path)
        }
        self.identifiers = identifiers
        self.prefixes = prefixes
        self.installedPaths = installedPaths
    }

    /// True when `path` is exactly where a still-installed app lives.
    func claimsPath(_ path: String) -> Bool {
        installedPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    /// True when an installed app could plausibly own this name.
    ///
    /// The vendor prefix is included on purpose, and it is the conservative choice:
    /// `com.google.Keystone` is Chrome's shared updater, not an orphan, for as long as
    /// any Google app is installed. Missing a real orphan costs the user nothing but a
    /// folder that stays; proposing a live app's shared component is the
    /// cross-contamination bug this project already fixed once.
    func claims(_ stem: String) -> Bool {
        let lowered = stem.lowercased()
        if identifiers.contains(where: { Matcher.matchesIdentifier(stem: lowered, identifier: $0) }) {
            return true
        }
        return prefixes.contains { lowered == $0 || lowered.hasPrefix($0 + ".") }
    }
}
