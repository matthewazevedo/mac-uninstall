import Observation
import Sparkle
import SwiftUI

/// Owns Sparkle's updater for the life of the app.
///
/// Configuration lives in the Info.plist rather than here — the feed URL, the public
/// key updates are verified against, and the decision to check on a schedule but never
/// install unattended. See ``Scripts/build-app.sh``.
///
/// Deliberately thin: Sparkle already provides the whole update UI, and a second
/// layer of our own would only be somewhere for the two to disagree.
@MainActor
@Observable
final class UpdaterModel {

    /// False while a check is already running, so the menu item can be disabled
    /// rather than starting a second check on top of the first.
    var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        // Starting the updater here rather than lazily means a scheduled check can
        // happen without the user opening a menu, which is the point of it.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            // KVO does not promise the main thread, and this drives a menu item.
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
