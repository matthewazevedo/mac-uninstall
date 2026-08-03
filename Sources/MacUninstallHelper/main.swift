import Foundation
import MacUninstallCore
import Security
import os

let log = Logger(subsystem: "com.macuninstall.helper", category: "helper")

/// Accepts XPC connections, but only from the app that shipped this helper.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {

    let service = HelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        // Pin the caller to this app's code signature. Without this, any process on
        // the machine could reach a root daemon. The system evaluates the requirement
        // against the peer and refuses the connection itself, so it cannot be spoofed
        // the way a self-reported identifier could.
        newConnection.setCodeSigningRequirement(CodeSigning.clientRequirement)

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

enum CodeSigning {

    /// The requirement a client must satisfy, derived from this helper's own signature.
    ///
    /// Reading it at runtime rather than baking in a team identifier means the same
    /// source builds correctly for a Developer ID release and for a local ad-hoc build,
    /// without a build-time substitution step that could silently produce a helper that
    /// accepts anyone.
    static let clientRequirement: String = {
        let appIdentifier = "com.macuninstall.app"

        guard let teamID = ownTeamIdentifier() else {
            // Ad-hoc builds carry no team identifier. Fall back to matching the app's
            // designated identifier, which is enough for local development but is not
            // a distribution configuration.
            log.warning("""
                No team identifier in this helper's signature. Falling back to an \
                identifier-only requirement, which is for local development only.
                """)
            return "identifier \"\(appIdentifier)\""
        }

        return """
            anchor apple generic \
            and identifier "\(appIdentifier)" \
            and certificate leaf[subject.OU] = "\(teamID)"
            """
    }()

    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

log.info("MacUninstall helper started, protocol version \(HelperConstants.protocolVersion).")

dispatchMain()
