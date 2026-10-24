import AppKit
import Combine
import Sparkle
import SwiftUI

/// What the last update check found, shown in Settings as Software Update does.
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case failed
}

/// Sparkle owns scheduling, preferences, signature verification and installation.
/// Keep one controller alive for the lifetime of the application.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var status = UpdateStatus.idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?

    private let updater: SPUUpdater?
    private let events = UpdaterEvents()
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
                                 userDriver: UserDriver(hostBundle: .main, delegate: nil), delegate: events)
        self.updater = updater
        events.found = { [weak self] version in self?.status = .available(version: version) }
        events.notFound = { [weak self] in self?.status = .upToDate }
        events.finished = { [weak self] error in
            guard let self else { return }
            if let error = error as NSError?,
               !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) {
                status = .failed
            } else if status == .checking {
                status = .idle
            }
        }
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

    /// Checks with Sparkle's windows: progress, then the result or the update.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }

    /// Checks without any window, for Settings to show the result in place.
    func checkForUpdatesQuietly() {
        guard let updater, updater.canCheckForUpdates else { return }
        status = .checking
        updater.checkForUpdateInformation()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater?.automaticallyDownloadsUpdates = enabled
    }
}

/// Sparkle's reports on update checks, quiet or not, passed on to AppUpdater.
private final class UpdaterEvents: NSObject, SPUUpdaterDelegate {
    var found: @MainActor (String) -> Void = { _ in }
    var notFound: @MainActor () -> Void = {}
    var finished: @MainActor ((any Error)?) -> Void = { _ in }

    // Sparkle calls its delegate on the main thread.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { found(version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { notFound() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { finished(error) }
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
