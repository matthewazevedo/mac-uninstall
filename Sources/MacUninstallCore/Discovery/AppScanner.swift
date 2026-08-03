import Foundation

/// Finds installed applications and reads their identity from disk.
public struct AppScanner: Sendable {

    public init() {}

    /// Directories searched for `.app` bundles, in the order users expect them.
    public static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appending(path: "Applications"),
        ]
    }

    /// Enumerates installed apps with lightweight identity only.
    ///
    /// Code-signature lookup is deliberately skipped here: it costs a subprocess per
    /// bundle and is only needed once the user picks a target. Call
    /// ``enrichWithSignature(_:)`` at that point.
    public func installedApps() -> [AppIdentity] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var results: [AppIdentity] = []

        for root in Self.searchRoots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries where entry.pathExtension == "app" {
                let path = entry.standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                if let identity = readIdentity(at: entry) {
                    results.append(identity)
                }
            }
        }

        return results.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Reads identity from a bundle's `Info.plist` and on-disk structure.
    public func readIdentity(at bundleURL: URL) -> AppIdentity? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundleURL.path) else { return nil }

        let infoPlistURL = bundleURL.appending(path: "Contents/Info.plist")
        let info = Self.readPlist(at: infoPlistURL) ?? [:]

        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fallbackName

        var identity = AppIdentity(
            bundleURL: bundleURL.standardizedFileURL,
            bundleID: info["CFBundleIdentifier"] as? String,
            displayName: displayName,
            executableName: info["CFBundleExecutable"] as? String,
            version: (info["CFBundleShortVersionString"] as? String)
                ?? (info["CFBundleVersion"] as? String)
        )

        identity.urlSchemes = Self.urlSchemes(from: info)
        identity.helperBundleIDs = Self.nestedBundleIDs(in: bundleURL, ownedBy: identity)
        identity.appStoreItemID = Self.appStoreItemID(bundleURL: bundleURL, info: info)

        return identity
    }

    /// Fills in team identifier and signing organisation by inspecting the signature.
    ///
    /// The signing organisation is the most reliable source of a vendor name, which is
    /// what matches folders like `~/Library/Application Support/Microsoft`.
    public func enrichWithSignature(_ identity: AppIdentity) -> AppIdentity {
        var identity = identity
        guard let output = Self.runCodesign(on: identity.bundleURL) else { return identity }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                if value != "not set" { identity.teamID = value }
            } else if line.hasPrefix("Authority=Developer ID Application: ")
                        || line.hasPrefix("Authority=Apple Mac OS Application Signing") {
                identity.signingOrganization = Self.organization(fromAuthority: String(line))
            }
        }
        return identity
    }

    /// Extracts `Anthropic PBC` from `Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)`.
    static func organization(fromAuthority line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        if let paren = value.lastIndex(of: "("), value.hasSuffix(")") {
            value = String(value[value.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return value.isEmpty ? nil : value
    }

    static func urlSchemes(from info: [String: Any]) -> Set<String> {
        guard let types = info["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var schemes: Set<String> = []
        for type in types {
            for scheme in (type["CFBundleURLSchemes"] as? [String] ?? []) {
                // Generic schemes would match half the system.
                let lowered = scheme.lowercased()
                guard !["http", "https", "file", "ftp", "mailto"].contains(lowered),
                      lowered.count >= 3 else { continue }
                schemes.insert(lowered)
            }
        }
        return schemes
    }

    /// Collects bundle identifiers of nested helpers, XPC services, and login items.
    /// These frequently own their own preference and cache files.
    ///
    /// Only identifiers that share the app's own namespace are kept. Apps embed
    /// third-party frameworks — Sparkle, Electron, crash reporters — whose bundle IDs
    /// are shared across hundreds of unrelated apps. Treating those as evidence would
    /// make uninstalling one app delete another app's data.
    static func nestedBundleIDs(in bundleURL: URL, ownedBy identity: AppIdentity) -> Set<String> {
        let fm = FileManager.default
        var ids: Set<String> = []
        let searchDirs = [
            "Contents/Library/LoginItems",
            "Contents/Library/LaunchServices",
            "Contents/XPCServices",
            "Contents/PlugIns",
            "Contents/Helpers",
            "Contents/Frameworks",
        ]

        for dir in searchDirs {
            let url = bundleURL.appending(path: dir)
            guard let entries = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let ext = entry.pathExtension
                guard ["app", "xpc", "appex", "bundle", "framework"].contains(ext) else { continue }
                // Frameworks keep Info.plist at a different depth than apps.
                let candidates = [
                    entry.appending(path: "Contents/Info.plist"),
                    entry.appending(path: "Resources/Info.plist"),
                ]
                for candidate in candidates {
                    if let plist = readPlist(at: candidate),
                       let id = plist["CFBundleIdentifier"] as? String {
                        if belongsToApp(id, identity: identity) { ids.insert(id) }
                        break
                    }
                }
            }
        }
        return ids
    }

    /// True when a nested bundle identifier is genuinely part of this app's namespace
    /// rather than a shared third-party component.
    static func belongsToApp(_ id: String, identity: AppIdentity) -> Bool {
        guard let bundleID = identity.bundleID else { return false }
        let lowered = id.lowercased()
        let owner = bundleID.lowercased()

        if lowered == owner || lowered.hasPrefix(owner + ".") { return true }
        // Siblings under the same vendor namespace, e.g. com.acme.App and com.acme.Updater.
        if let prefix = identity.reverseDNSPrefix?.lowercased(), lowered.hasPrefix(prefix + ".") {
            return true
        }
        return false
    }

    /// Mac App Store apps carry a receipt; their prefs show up as `<itemID>.plist`.
    static func appStoreItemID(bundleURL: URL, info: [String: Any]) -> String? {
        let receipt = bundleURL.appending(path: "Contents/_MASReceipt/receipt")
        guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
        // The item ID is not stored in the bundle in plain form; the closest
        // reliable value available without parsing the signed receipt is the
        // iTunes item identifier some apps declare directly.
        if let id = info["ITunesItemIdentifier"] {
            return String(describing: id)
        }
        return nil
    }

    static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any]
    }

    static func runCodesign(on bundleURL: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", bundleURL.path]

        let pipe = Pipe()
        // codesign writes its description to stderr.
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
