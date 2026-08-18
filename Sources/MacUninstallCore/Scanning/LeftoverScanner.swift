import Foundation

/// Sweeps every known location and reports what belongs to a given app.
public struct LeftoverScanner: Sendable {

    public struct Options: Sendable {
        /// Read the contents of small plists that did not match by name, looking for
        /// the app's identifier inside. This is what finds opaque leftovers such as
        /// `com.todesktop.230313mzl4w4u92.plist`, which no name rule could catch.
        public var deepInspectPlists: Bool
        /// Upper bound on file size for deep inspection, in bytes.
        public var deepInspectMaxBytes: Int
        /// Measure sizes on disk. Disabled in tests where it only adds noise.
        public var measureSizes: Bool
        /// Filters out paths that could never legitimately be removed, so they never
        /// reach the UI.
        ///
        /// This is a noise filter, not the safety gate — ``Remover`` revalidates every
        /// path against ``ProtectedPaths`` unconditionally before deleting anything.
        /// It is injectable purely so the scanner can be tested against a temporary
        /// directory tree.
        public var safetyCheck: @Sendable (URL) -> Bool

        public init(
            deepInspectPlists: Bool = true,
            deepInspectMaxBytes: Int = 2 * 1024 * 1024,
            measureSizes: Bool = true,
            safetyCheck: @escaping @Sendable (URL) -> Bool = { ProtectedPaths.isSafeToRemove($0) }
        ) {
            self.deepInspectPlists = deepInspectPlists
            self.deepInspectMaxBytes = deepInspectMaxBytes
            self.measureSizes = measureSizes
            self.safetyCheck = safetyCheck
        }
    }

    let locations: [SearchLocation]
    let options: Options

    public init(locations: [SearchLocation] = SearchLocations.standard(), options: Options = .init()) {
        self.locations = locations
        self.options = options
    }

    /// What one location yielded.
    private struct Sweep: Sendable {
        var leftovers: [Leftover] = []
        var inaccessible: [URL] = []
    }

    /// Finds everything belonging to `identity`, including the bundle itself.
    public func scan(for identity: AppIdentity) async -> ScanResult {
        let matcher = Matcher(identity: identity)
        let fm = FileManager.default

        var leftovers: [Leftover] = []
        var claimed: Set<String> = []

        // The application bundle is part of its own footprint, unless macOS protects
        // it — Apple's own apps under /System cannot be removed, and listing one would
        // promise something the removal step is guaranteed to refuse. This goes through
        // the same injectable check as every other path rather than ProtectedPaths
        // directly, so the rule is consistent and testable.
        if fm.fileExists(atPath: identity.bundleURL.path), options.safetyCheck(identity.bundleURL) {
            leftovers.append(Leftover(
                url: identity.bundleURL,
                category: .application,
                confidence: .certain,
                reason: "The application bundle itself.",
                // Removing an item needs write permission on its *parent*, not on the
                // item. Testing the bundle sent read-only apps down the privileged
                // path and quarantined them instead of trashing them.
                requiresAdmin: !fm.isWritableFile(
                    atPath: identity.bundleURL.deletingLastPathComponent().path
                )
            ))
            claimed.insert(identity.bundleURL.standardizedFileURL.path)
        }

        // Locations are swept concurrently. They are separate directory trees, so no
        // sweep can claim what another one found, and the work is almost entirely
        // spent waiting on the filesystem. Completion order is not allowed to matter:
        // the results are sorted and de-duplicated afterwards.
        let alreadyClaimed = claimed
        let sweeps = await withTaskGroup(of: Sweep.self) { group in
            for location in locations {
                group.addTask {
                    self.sweep(location, matcher: matcher, identity: identity, claimed: alreadyClaimed)
                }
            }
            var results: [Sweep] = []
            for await sweep in group { results.append(sweep) }
            return results
        }

        var inaccessible: [URL] = []
        for sweep in sweeps {
            leftovers.append(contentsOf: sweep.leftovers)
            inaccessible.append(contentsOf: sweep.inaccessible)
        }

        if options.measureSizes {
            leftovers = await measure(leftovers)
        }

        return ScanResult(
            identity: identity,
            leftovers: Self.ordered(leftovers),
            inaccessibleLocations: inaccessible.sorted { $0.path < $1.path }
        )
    }

    /// Strongest evidence first, with any path that turned up twice kept once.
    static func ordered(_ leftovers: [Leftover]) -> [Leftover] {
        var seen: Set<String> = []
        return leftovers
            .sorted { ($0.confidence, $0.url.path) > ($1.confidence, $1.url.path) }
            .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    private func sweep(
        _ location: SearchLocation,
        matcher: Matcher,
        identity: AppIdentity,
        claimed: Set<String>
    ) -> Sweep {
        let fm = FileManager.default
        var claimed = claimed
        var sweep = Sweep()

        guard let entries = try? fm.contentsOfDirectory(
            at: location.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            // Distinguish "cannot read" from "does not exist"; only the former
            // means the report is incomplete.
            if fm.fileExists(atPath: location.url.path) {
                sweep.inaccessible.append(location.url)
            }
            return sweep
        }

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let path = entry.standardizedFileURL.path
            guard !claimed.contains(path) else { continue }

            let parentMatch = matcher.match(name: entry.lastPathComponent, isDirectory: isDirectory)

            // A confident match is the app's own folder — take it whole rather
            // than descending into files it exclusively owns.
            if let parentMatch, parentMatch.confidence >= .likely {
                guard options.safetyCheck(entry) else { continue }
                claimed.insert(path)
                sweep.leftovers.append(Leftover(
                    url: entry,
                    category: location.category,
                    confidence: parentMatch.confidence,
                    reason: parentMatch.reason,
                    requiresAdmin: location.requiresAdmin
                ))
                continue
            }

            // Otherwise look one level deeper. A vendor folder such as
            // `Application Support/Google` is shared, so a specific child like
            // `Google/Chrome` must win over claiming the whole parent — deleting
            // the parent would take Google Drive's data with it.
            if location.descendsIntoVendorFolders && isDirectory {
                let nested = scanOneLevel(
                    in: entry, matcher: matcher, location: location, claimed: &claimed
                )
                if !nested.isEmpty {
                    sweep.leftovers.append(contentsOf: nested)
                    continue
                }
            }

            // No specific child matched, so fall back to the vendor-level hit.
            // It stays low confidence and is never pre-selected.
            if let parentMatch {
                guard options.safetyCheck(entry) else { continue }
                claimed.insert(path)
                sweep.leftovers.append(Leftover(
                    url: entry,
                    category: location.category,
                    confidence: parentMatch.confidence,
                    reason: parentMatch.reason,
                    requiresAdmin: location.requiresAdmin
                ))
                continue
            }

            // Content-based evidence for names that look like nothing.
            if options.deepInspectPlists,
               !isDirectory,
               entry.pathExtension.lowercased() == "plist",
               let reason = deepEvidence(in: entry, identity: identity) {
                guard options.safetyCheck(entry) else { continue }
                claimed.insert(path)
                sweep.leftovers.append(Leftover(
                    url: entry,
                    category: location.category,
                    // A file that merely mentions the app is weaker evidence than
                    // one named after it, so this always needs a human decision.
                    confidence: .possible,
                    reason: reason,
                    requiresAdmin: location.requiresAdmin
                ))
            }
        }

        return sweep
    }

    /// Looks inside a vendor folder for a subfolder belonging to this app.
    ///
    /// Returns the child matches rather than the parent, so uninstalling Chrome
    /// proposes `Application Support/Google/Chrome` and leaves Google Drive alone.
    private func scanOneLevel(
        in directory: URL,
        matcher: Matcher,
        location: SearchLocation,
        claimed: inout Set<String>
    ) -> [Leftover] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }

        var found: [Leftover] = []
        for entry in entries {
            let path = entry.standardizedFileURL.path
            guard !claimed.contains(path) else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard let match = matcher.match(name: entry.lastPathComponent, isDirectory: isDirectory),
                  options.safetyCheck(entry) else { continue }
            claimed.insert(path)
            found.append(Leftover(
                url: entry,
                category: location.category,
                confidence: match.confidence,
                reason: match.reason + " Found inside \(directory.lastPathComponent).",
                requiresAdmin: location.requiresAdmin
            ))
        }
        return found
    }

    /// Reads a plist and reports whether it references the app's identifier or path.
    ///
    /// Only files that belong to no other identifiable owner are considered. macOS's
    /// own preference files mention every installed app by design, so a mention there
    /// proves nothing and deleting them would break the system.
    private func deepEvidence(in url: URL, identity: AppIdentity) -> String? {
        guard !Matcher.isAppleOwned(name: url.lastPathComponent) else { return nil }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              size <= options.deepInspectMaxBytes,
              // Map rather than copy: a scan inspects hundreds of preference files,
              // and none of them need to be held in memory.
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        // Search the raw bytes, which covers both XML and binary plists without
        // paying to deserialise every candidate.
        var needles: [(String, String)] = []
        if let bundleID = identity.bundleID {
            needles.append((bundleID, "Its contents reference the identifier \(bundleID)."))
        }
        needles.append((
            identity.bundleURL.path,
            "Its contents reference the path \(identity.bundleURL.path)."
        ))

        for (needle, reason) in needles {
            guard let needleData = needle.data(using: .utf8), !needleData.isEmpty else { continue }
            if data.range(of: needleData) != nil { return reason }
        }
        return nil
    }

    /// Measures each item concurrently; sizes are advisory, so failures are tolerated.
    ///
    /// Exposed separately so callers can show the file list immediately and fill in
    /// sizes afterwards. Walking a multi-gigabyte support folder takes seconds, and
    /// nobody should wait on a byte count to see what is about to be deleted.
    public func measureSizes(for leftovers: [Leftover]) async -> [Leftover] {
        await measure(leftovers)
    }

    private func measure(_ leftovers: [Leftover]) async -> [Leftover] {
        await withTaskGroup(of: (String, DiskSize.Measurement?).self) { group in
            for leftover in leftovers {
                let url = leftover.url
                group.addTask { (url.path, DiskSize.ofItem(at: url)) }
            }
            var sizes: [String: DiskSize.Measurement] = [:]
            for await (path, size) in group {
                if let size { sizes[path] = size }
            }
            return leftovers.map { item in
                var item = item
                item.sizeBytes = sizes[item.url.path]?.bytes
                item.sizeIsPartial = sizes[item.url.path]?.isPartial ?? false
                return item
            }
        }
    }
}

/// Size measurement with a hard bound, so a scan cannot stall on a huge tree.
enum DiskSize {

    /// Reached only by trees like a node_modules folder or a browser cache. High
    /// enough that ordinary app data is measured exactly; bounded so one pathological
    /// item cannot hold up the whole list.
    static let maxEntriesPerItem = 100_000

    struct Measurement: Sendable {
        var bytes: Int64
        /// True when the walk stopped at its bound before the tree ended, so the
        /// number is a floor. A confident wrong total is worse than an honest one:
        /// the whole point of the review screen is that its numbers can be trusted.
        var isPartial: Bool
    }

    /// - Parameter limit: How many entries to walk before giving up and reporting a
    ///   floor. Injectable so the bounded case can be tested without building a tree
    ///   of a hundred thousand files.
    static func ofItem(at url: URL, limit: Int = maxEntriesPerItem) -> Measurement? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Measurement(
                bytes: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0),
                isPartial: false
            )
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        var count = 0
        var isPartial = false
        for case let child as URL in enumerator {
            count += 1
            if count > limit {
                isPartial = true
                break
            }
            guard let values = try? child.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return Measurement(bytes: total, isPartial: isPartial)
    }
}
