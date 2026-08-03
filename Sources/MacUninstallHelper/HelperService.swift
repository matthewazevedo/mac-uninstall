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

    func quarantine(
        paths: [String],
        into directory: String,
        reply: @escaping ([String: String]) -> Void
    ) {
        var failures: [String: String] = [:]
        let fm = FileManager.default

        // The destination must be a quarantine directory under a real user's Library,
        // never an arbitrary location chosen by the caller.
        guard HelperValidation.isAcceptableQuarantineDirectory(directory) else {
            for path in paths {
                failures[path] = "Rejected an unacceptable quarantine destination."
            }
            reply(failures)
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
            reply(failures)
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
            reply(failures)
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
            } catch {
                failures[path] = error.localizedDescription
            }
        }

        writeManifest(paths: accepted.filter { failures[$0] == nil }, into: directory)
        reply(failures)
    }

    func bootout(label: String, isDaemon: Bool, reply: @escaping (String?) -> Void) {
        // A launchd label is a bare identifier. Anything else is rejected outright so
        // the argument cannot be used to reach a different domain.
        guard HelperValidation.isValidLaunchdLabel(label) else {
            reply("Rejected an invalid launchd label.")
            return
        }

        let domain = isDaemon ? "system" : "gui/\(getuid())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // Arguments are passed as an array, so there is no shell to inject into.
        process.arguments = ["bootout", "\(domain)/\(label)"]
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

    /// Records where each item came from, so a mistake can be undone by hand.
    private func writeManifest(paths: [String], into directory: String) {
        guard !paths.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appending(path: "MANIFEST.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let contents = existing + paths.joined(separator: "\n") + "\n"
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
