import Foundation

/// How sure we are that an item belongs to the app being removed.
///
/// This distinction is the whole safety story. `~/Library/Preferences/com.acme.App.plist`
/// is unambiguous. `~/Library/Application Support/Google` is *not* — deleting it while
/// uninstalling Chrome would also destroy Google Drive's data. So vendor-level hits are
/// surfaced but never pre-selected, and the UI explains why.
public enum Confidence: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Matched the app's own bundle ID, a helper bundle ID, or the bundle path itself.
    case certain = 3
    /// Matched a reverse-DNS sibling prefix or the executable name.
    case likely = 2
    /// Matched a vendor name or a fuzzy display-name variant. Shared with other
    /// products from the same vendor — always requires a human decision.
    case possible = 1

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .certain: "Certain"
        case .likely: "Likely"
        case .possible: "Needs review"
        }
    }

    /// Only unambiguous matches are ticked by default.
    public var selectedByDefault: Bool { self == .certain }
}

/// What kind of leftover this is, used for grouping in the UI.
public enum LeftoverCategory: String, Sendable, Codable, CaseIterable {
    case application = "Application"
    case supportFiles = "Support Files"
    case caches = "Caches"
    case preferences = "Preferences"
    case containers = "Containers"
    case logs = "Logs"
    case savedState = "Saved State"
    case launchItems = "Launch Agents & Daemons"
    case privilegedHelpers = "Privileged Helpers"
    case receipts = "Installer Receipts"
    case plugins = "Plug-ins & Extensions"
    case cookiesAndStorage = "Cookies & Web Storage"

    /// Categories whose removal changes system-wide behaviour and therefore
    /// needs an administrator prompt.
    public var typicallyRequiresAdmin: Bool {
        switch self {
        case .launchItems, .privilegedHelpers, .receipts: true
        default: false
        }
    }
}

/// A single file or directory proposed for removal.
public struct Leftover: Sendable, Identifiable, Hashable, Codable {
    public var id: String { url.path }

    public var url: URL
    public var category: LeftoverCategory
    public var confidence: Confidence
    /// Human-readable justification, e.g. "Matches bundle ID com.acme.App".
    /// Shown verbatim in the UI so the user can audit every proposed deletion.
    public var reason: String
    /// Total size on disk in bytes, or `nil` if it could not be measured.
    public var sizeBytes: Int64?
    /// True when the current user cannot remove this without elevation.
    public var requiresAdmin: Bool

    public init(
        url: URL,
        category: LeftoverCategory,
        confidence: Confidence,
        reason: String,
        sizeBytes: Int64? = nil,
        requiresAdmin: Bool = false
    ) {
        self.url = url
        self.category = category
        self.confidence = confidence
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.requiresAdmin = requiresAdmin
    }
}

/// The complete result of scanning for one app's footprint.
public struct ScanResult: Sendable, Codable {
    public var identity: AppIdentity
    public var leftovers: [Leftover]
    /// Locations we could not read. Non-empty means the report is incomplete and
    /// the UI must say so rather than claiming a clean sweep.
    public var inaccessibleLocations: [URL]

    public init(identity: AppIdentity, leftovers: [Leftover], inaccessibleLocations: [URL] = []) {
        self.identity = identity
        self.leftovers = leftovers
        self.inaccessibleLocations = inaccessibleLocations
    }

    public var totalSizeBytes: Int64 {
        leftovers.compactMap(\.sizeBytes).reduce(0, +)
    }

    /// True when some locations were unreadable, meaning we cannot honestly
    /// promise the app was fully removed.
    public var isIncomplete: Bool { !inaccessibleLocations.isEmpty }

    /// True while sizes are still being measured in the background, so the UI can
    /// avoid showing a misleading "Zero KB" total.
    public var isMeasuringSizes: Bool {
        !leftovers.isEmpty && leftovers.allSatisfy { $0.sizeBytes == nil }
    }

    public func grouped() -> [(category: LeftoverCategory, items: [Leftover])] {
        LeftoverCategory.allCases.compactMap { category in
            let items = leftovers
                .filter { $0.category == category }
                .sorted { ($0.confidence, $0.url.path) > ($1.confidence, $1.url.path) }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
