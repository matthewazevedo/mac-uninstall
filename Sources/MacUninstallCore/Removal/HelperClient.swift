import Foundation
import ServiceManagement

/// Talks to the privileged daemon over XPC, registering it on first use.
///
/// `SMAppService` installs the daemon from inside the app bundle, so there is no
/// separate installer and no `setuid` binary on disk. The user approves it once in
/// System Settings; after that, removals need no password prompt at all.
public actor HelperClient: PrivilegedExecutor {

    public enum Status: Sendable, Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        /// The app is not in /Applications, which is where launchd looks for a
        /// bundled daemon.
        case needsInstallInApplications
        case unavailable(String)

        public var isUsable: Bool { self == .enabled }
    }

    private var connection: NSXPCConnection?

    public init() {}

    // MARK: - Registration

    nonisolated public static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
    }

    nonisolated public static var status: Status {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound:
            // launchd only resolves a bundled daemon for apps installed in
            // /Applications. Running from a build folder, a DMG, or Downloads gives
            // the same "not found" result as a genuinely missing helper, so tell the
            // two apart rather than sending the user hunting for a bundle problem.
            isInstalledInApplications
                ? .unavailable("The helper is missing from the app bundle.")
                : .needsInstallInApplications
        @unknown default: .unavailable("Unknown service status.")
        }
    }

    /// True when the app runs from a system or user Applications folder.
    nonisolated public static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    /// Registers the daemon, returning the resulting status.
    ///
    /// Registration is idempotent; `alreadyRegistered` is a success, not an error.
    @discardableResult
    nonisolated public static func register() -> Status {
        do {
            try service.register()
        } catch {
            let nsError = error as NSError
            // kSMErrorAlreadyRegistered
            if nsError.code != 134 {
                return .unavailable(error.localizedDescription)
            }
        }
        return status
    }

    nonisolated public static func unregister() async throws {
        try await service.unregister()
    }

    /// Opens the Login Items pane where the user enables the helper.
    nonisolated public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Connection

    private func activeConnection() throws -> NSXPCConnection {
        guard Self.status.isUsable else {
            throw Self.status == .requiresApproval
                ? RemovalError.helperNeedsApproval
                : RemovalError.helperUnavailable(String(describing: Self.status))
        }

        if connection == nil {
            let new = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            new.interruptionHandler = { [weak self] in
                Task { await self?.clearConnection() }
            }
            new.resume()
            connection = new
        }

        guard let connection else {
            throw RemovalError.helperUnavailable("Could not open a connection.")
        }
        return connection
    }

    private func clearConnection() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - PrivilegedExecutor

    /// Guarantees a continuation is resumed exactly once.
    ///
    /// An XPC call completes through either its reply block or its error handler.
    /// Resuming a continuation twice traps, so the two paths are funnelled through
    /// this rather than trusting that only one of them ever fires.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: sending Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    /// Runs one call against the daemon, mapping transport failures to a usable error.
    private func withProxy<T: Sendable>(
        _ body: @Sendable @escaping (HelperProtocol, @Sendable @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = try activeConnection()

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.finish(.failure(RemovalError.helperUnavailable(error.localizedDescription)))
            }) as? HelperProtocol else {
                once.finish(.failure(RemovalError.helperUnavailable("Could not obtain a proxy.")))
                return
            }

            body(proxy) { once.finish($0) }
        }
    }

    public func quarantine(items: [URL], into directory: URL) async throws -> [String: String] {
        guard !items.isEmpty else { return [:] }
        let paths = items.map(\.path)
        let destination = directory.path

        return try await withProxy { proxy, finish in
            proxy.quarantine(paths: paths, into: destination) { failures in
                finish(.success(failures))
            }
        }
    }

    public func bootout(label: String, isDaemon: Bool) async throws {
        let _: String? = try await withProxy { proxy, finish in
            proxy.bootout(label: label, isDaemon: isDaemon) { message in
                finish(.success(message))
            }
        }
    }

    /// Round-trips the protocol version, which also confirms the daemon is reachable
    /// and not a stale build left by a previous install.
    public func installedVersion() async throws -> Int {
        try await withProxy { proxy, finish in
            proxy.version { finish(.success($0)) }
        }
    }
}

/// Chooses the daemon when it is available and falls back to an authenticated prompt.
///
/// The fallback matters: the helper needs a one-time approval in System Settings, and
/// the app must still work before that happens rather than dead-ending the user.
public struct AdaptivePrivilegedExecutor: PrivilegedExecutor {
    let helper: HelperClient
    let fallback: PrivilegedExecutor

    public init(
        helper: HelperClient = HelperClient(),
        fallback: PrivilegedExecutor = AppleScriptPrivilegedExecutor()
    ) {
        self.helper = helper
        self.fallback = fallback
    }

    public func quarantine(items: [URL], into directory: URL) async throws -> [String: String] {
        if HelperClient.status.isUsable {
            do {
                return try await helper.quarantine(items: items, into: directory)
            } catch {
                // Fall through to the prompt rather than failing the removal outright.
            }
        }
        return try await fallback.quarantine(items: items, into: directory)
    }

    public func bootout(label: String, isDaemon: Bool) async throws {
        if HelperClient.status.isUsable {
            if (try? await helper.bootout(label: label, isDaemon: isDaemon)) != nil { return }
        }
        try await fallback.bootout(label: label, isDaemon: isDaemon)
    }
}
