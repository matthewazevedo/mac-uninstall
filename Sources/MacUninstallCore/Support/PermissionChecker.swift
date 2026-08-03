import Foundation

/// Detects whether the app can actually see everything it claims to scan.
///
/// Without Full Disk Access, protected folders silently read as empty rather than
/// returning an error. An uninstaller that does not detect this will confidently
/// report a clean sweep while leaving files behind, which is precisely the failure
/// this product exists to prevent.
public enum PermissionChecker {

    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// No protected folder existed to test against.
        case indeterminate

        public var allowsCompleteScan: Bool { self != .denied }
    }

    /// Probes a TCC-protected location to infer Full Disk Access.
    ///
    /// The probe reads a directory that exists on every Mac but is readable only
    /// with Full Disk Access. A thrown permission error means denied; a successful
    /// read means granted.
    public static func fullDiskAccessStatus(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Status {
        let fm = FileManager.default
        var sawCandidate = false

        for probe in SearchLocations.fullDiskAccessProbes(home: home) {
            guard fm.fileExists(atPath: probe.path) else { continue }
            sawCandidate = true
            do {
                _ = try fm.contentsOfDirectory(atPath: probe.path)
                return .granted
            } catch {
                let code = (error as NSError).code
                // EPERM/EACCES surface as these Cocoa errors when TCC denies access.
                if code == NSFileReadNoPermissionError || code == NSFileReadUnknownError {
                    continue
                }
            }
        }

        return sawCandidate ? .denied : .indeterminate
    }

    /// Opens the Full Disk Access pane so the user can grant it.
    public static var fullDiskAccessSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
