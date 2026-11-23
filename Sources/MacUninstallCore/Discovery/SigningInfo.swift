import Foundation
import Security

/// What an app's code signature says about who it is and what it shares.
///
/// The app-group entitlement is the only authoritative record of which group
/// containers an app uses: macOS will not let an app open `<TeamID>.com.acme.shared`
/// unless that exact name is in its signed entitlements. Names are guesses; this is
/// not. 1Password and 1Password for Safari both list `2BUA8C4S2C.com.1password`, and
/// that container holds the SSH agent socket that `~/.ssh/config` points at.
public struct SigningInfo: Sendable, Hashable {
    public var teamID: String?
    /// `com.apple.security.application-groups`, e.g. `2BUA8C4S2C.com.1password`.
    public var appGroups: Set<String>

    public init(teamID: String? = nil, appGroups: Set<String> = []) {
        self.teamID = teamID
        self.appGroups = appGroups
    }

    /// Reads the signature in-process, without validating it.
    ///
    /// Validation is not the point — a damaged signature still says which containers
    /// the app expects to use — and skipping it keeps this cheap enough to run over
    /// every installed app, where ``AppScanner/enrichWithSignature(_:)`` spawns a
    /// `codesign` subprocess per bundle.
    public static func read(bundleURL: URL) -> SigningInfo? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }

        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []

        return SigningInfo(
            teamID: (team?.isEmpty ?? true) ? nil : team,
            appGroups: Set(groups)
        )
    }
}

/// Something a scan found but left out, because another installed app uses it.
public struct SharedItem: Sendable, Codable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    /// Display names of the installed apps entitled to it, e.g. `1Password`.
    public var usedBy: [String]

    public init(url: URL, usedBy: [String]) {
        self.url = url
        self.usedBy = usedBy
    }
}

/// Keeps one app's removal away from containers other installed apps still use.
public enum SharedContainers {

    /// Another installed app, as far as sharing is concerned.
    public struct OtherApp: Sendable {
        public var name: String
        public var signing: SigningInfo

        public init(name: String, signing: SigningInfo) {
            self.name = name
            self.signing = signing
        }
    }

    /// Splits leftovers into those safe to offer and those named after an app group
    /// another installed app is entitled to.
    ///
    /// Matching by team identifier is right for finding an app's data and wrong for
    /// deciding it is safe to delete: a vendor's apps share one container. Scanning
    /// 1Password for Safari matched `2BUA8C4S2C.com.1password`, the container
    /// 1Password itself keeps its SSH agent in. Shared items are not offered at all —
    /// an item another app depends on is not this app's leftover — but they are
    /// returned, so the UI can say what was held back and for whom.
    public static func partition(
        _ leftovers: [Leftover],
        usedBy others: [OtherApp]
    ) -> (kept: [Leftover], shared: [SharedItem]) {
        var owners: [String: [String]] = [:]
        for other in others {
            for group in other.signing.appGroups {
                let key = group.lowercased()
                if !(owners[key]?.contains(other.name) ?? false) {
                    owners[key, default: []].append(other.name)
                }
            }
        }
        guard !owners.isEmpty else { return (leftovers, []) }

        var kept: [Leftover] = []
        var shared: [SharedItem] = []
        for leftover in leftovers {
            let name = leftover.url.lastPathComponent.lowercased()
            let stem = Matcher.stem(of: leftover.url.lastPathComponent, isDirectory: false)
                .lowercased()
            if leftover.category != .application,
               let users = owners[stem] ?? owners[name] {
                shared.append(SharedItem(url: leftover.url, usedBy: users.sorted()))
            } else {
                kept.append(leftover)
            }
        }
        return (kept, shared)
    }
}
