import Foundation
import MacUninstallCore

/// Implements the privileged operations. Every instance runs as root.
///
/// The guiding rule is that this class trusts nothing the client sends. The app has
/// already validated these paths, but the daemon is reachable by anything that gets
/// past the connection check, so it validates them again itself.
final class HelperService: NSObject, HelperProtocol, @unchecked Sendable {

    func version(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    // MARK: - Quarantine

    func quarantine(
        paths: [String],
        into directory: String,
        reply: @escaping ([String: String], [String: String]) -> Void
    ) {
        var failures: [String: String] = [:]
        var destinations: [String: String] = [:]
        let fm = FileManager.default

        // The destination must be a quarantine directory under a real user's Library,
        // never an arbitrary location chosen by the caller.
        guard HelperValidation.isAcceptableQuarantineDirectory(directory) else {
            for path in paths {
                failures[path] = "Rejected an unacceptable quarantine destination."
            }
            reply(failures, [:])
            return
        }

        var accepted: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let rejection = ProtectedPaths.rejection(for: url) {
                // The client should never have asked. Refuse and say why.
                failures[path] = "Refused by the helper: \(rejection.explanation)"
                continue
            }
            guard fm.fileExists(atPath: path) else {
                failures[path] = "No longer present."
                continue
            }
            accepted.append(path)
        }

        guard !accepted.isEmpty else {
            reply(failures, [:])
            return
        }

        do {
            try fm.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            for path in accepted { failures[path] = "Could not create the quarantine folder." }
            reply(failures, [:])
            return
        }

        for path in accepted {
            let source = URL(fileURLWithPath: path)
            var destination = URL(fileURLWithPath: directory)
                .appending(path: source.lastPathComponent)

            // Distinct items can share a filename; keep both rather than clobbering.
            if fm.fileExists(atPath: destination.path) {
                destination = URL(fileURLWithPath: directory)
                    .appending(path: "\(UUID().uuidString)-\(source.lastPathComponent)")
            }

            do {
                try fm.moveItem(at: source, to: destination)
                destinations[path] = destination.path
            } catch {
                failures[path] = error.localizedDescription
            }
        }

        writeManifest(paths: Array(destinations.keys), into: directory)

        // Everything this daemon creates would otherwise belong to root, inside the
        // user's own Library, at 0700 — unreadable even in Finder. That would make the
        // promise that quarantined items are recoverable simply false.
        handOwnershipToUser(ofTreeContaining: directory)

        reply(failures, destinations)
    }

    // MARK: - Restore

    func restore(items: [String: String], reply: @escaping ([String: String]) -> Void) {
        var failures: [String: String] = [:]
        let fm = FileManager.default

        for (quarantined, original) in items {
            // Both ends are pinned. Without the source check, "put this back" would
            // move any file on the system; without the destination check, it would
            // write one anywhere.
            guard HelperValidation.isQuarantinedItem(quarantined) else {
                failures[original] = "Refused by the helper: not an item in quarantine."
                continue
            }
            if let rejection = ProtectedPaths.rejection(for: URL(fileURLWithPath: original)) {
                failures[original] = "Refused by the helper: \(rejection.explanation)"
                continue
            }
            guard fm.fileExists(atPath: quarantined) else {
                failures[original] = "No longer in quarantine."
                continue
            }
            // Something may have been reinstalled there since the removal, and putting
            // the old copy back over it would destroy the new one.
            guard !fm.fileExists(atPath: original) else {
                failures[original] = "Something is already at that location."
                continue
            }

            do {
                try fm.createDirectory(
                    atPath: (original as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try fm.moveItem(atPath: quarantined, toPath: original)
            } catch {
                failures[original] = error.localizedDescription
                continue
            }

            restoreOwnership(of: original)
        }

        reply(failures)
    }

    /// Puts ownership back to what the destination implies.
    ///
    /// Quarantined items were handed to the user so the folder could be opened, so a
    /// straight move back would leave a user-writable file in a system location — and
    /// a user-writable launch daemon is a local privilege escalation, which is the kind
    /// of thing this app exists to clean up rather than create. The owner is derived
    /// from where the item is going, never from anything the client said.
    private func restoreOwnership(of path: String) {
        let owner: (uid: NSNumber, gid: NSNumber)
        if path.hasPrefix("/Users/"), let user = Self.homeOwner(of: path) {
            owner = user
        } else {
            owner = (0, 0)  // root:wheel, which is what a system location expects.
        }
        setOwner(owner, onTreeAt: path)
    }

    // MARK: - Launchd

    func bootoutDaemon(label: String, reply: @escaping (String?) -> Void) {
        // A launchd label is a bare identifier. Anything else is rejected outright so
        // the argument cannot be used to reach a different domain.
        guard HelperValidation.isValidLaunchdLabel(label) else {
            reply("Rejected an invalid launchd label.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // Arguments are passed as an array, so there is no shell to inject into. The
        // domain is always `system`: this process is root, so it cannot name the
        // user's GUI domain — `gui/$(getuid())` here would always resolve to `gui/0`,
        // which is nobody's session.
        process.arguments = ["bootout", "system/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    // MARK: - Ownership

    /// Gives the whole quarantine tree back to the user who owns the home directory
    /// it sits in, so they can open, inspect, and restore from it.
    private func handOwnershipToUser(ofTreeContaining directory: String) {
        guard let root = HelperValidation.quarantineRoot(containing: directory),
              let owner = Self.homeOwner(of: root) else { return }
        setOwner(owner, onTreeAt: root)
    }

    private func setOwner(_ owner: (uid: NSNumber, gid: NSNumber), onTreeAt root: String) {
        let fm = FileManager.default
        var paths = [root]
        if let enumerator = fm.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                paths.append((root as NSString).appendingPathComponent(relative))
            }
        }

        for path in paths {
            try? fm.setAttributes(
                [.ownerAccountID: owner.uid, .groupOwnerAccountID: owner.gid],
                ofItemAtPath: path
            )
        }
    }

    /// Reads the owning user from the home directory the path sits under, rather than
    /// trusting anything the client sent.
    static func homeOwner(of path: String) -> (uid: NSNumber, gid: NSNumber)? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count > 2, components[1] == "Users" else { return nil }
        let home = "/Users/" + components[2]
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: home),
              let uid = attributes[.ownerAccountID] as? NSNumber,
              let gid = attributes[.groupOwnerAccountID] as? NSNumber else { return nil }
        return (uid, gid)
    }

    /// Records where each item came from, so a mistake can be undone by hand.
    private func writeManifest(paths: [String], into directory: String) {
        guard !paths.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appending(path: "MANIFEST.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let contents = existing + paths.sorted().joined(separator: "\n") + "\n"
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
