import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns scheduling, preferences, signature verification and installation.
/// Keep one controller alive for the lifetime of the application.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private let updater: SPUUpdater?
    private var started = false

    init() {
        // `swift run` and command-line tools aren't installed app bundles.
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            updater = nil
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: UserDriver(hostBundle: .main, delegate: nil), delegate: nil)
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastUpdateCheckDate)
    }

    var isAvailable: Bool { updater != nil }

    func start() {
        guard !started, let updater else { return }
        started = true
        do {
            try updater.start()
        } catch {
            NSLog("Citrus Battery couldn't start the updater: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater?.automaticallyDownloadsUpdates = enabled
    }
}

/// Sparkle's standard interface, with a shorter message when there's no update.
private final class UserDriver: SPUStandardUserDriver {
    override func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        // Other reasons, such as a feed that couldn't be read, keep Sparkle's alert.
        guard error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) else {
            super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
            return
        }
        // Sparkle's own alert replaces its "Checking for updates…" window; do the same.
        for window in NSApp.windows where window.isVisible && window.windowController?.className.hasPrefix("SU") == true {
            window.orderOut(nil)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Citrus Battery \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        acknowledgement()
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
