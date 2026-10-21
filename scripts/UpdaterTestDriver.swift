// A disposable test application. This file is never bundled with Citrus Battery.
import AppKit
import CryptoKit
import Sparkle

@MainActor
func record(_ message: String) {
    let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("result.log")
    let data = Data((message + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}

@MainActor
final class TestDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("CHECKING") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("FOUND \(appcastItem.versionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("NOT_FOUND \((error as NSError).code)")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        record("ERROR \(error.code) \(error)")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("DOWNLOADING") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { record("EXTRACTING") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("INSTALLING")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

@MainActor
final class TestAppDelegate: NSObject, NSApplicationDelegate {
    let driver = TestDriver()
    var updater: SPUUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2.0" {
            record("RELAUNCHED 2.0")
            NSApp.terminate(nil)
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            record("START_ERROR \(error)")
            NSApp.terminate(nil)
        }
    }
}

@main
enum TestEntry {
    @MainActor
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--generate-key" {
            let key = Curve25519.Signing.PrivateKey()
            let base = URL(fileURLWithPath: CommandLine.arguments[2])
            try key.rawRepresentation.base64EncodedString().write(to: base, atomically: true, encoding: .utf8)
            try key.publicKey.rawRepresentation.base64EncodedString().write(
                to: base.appendingPathExtension("pub"), atomically: true, encoding: .utf8)
            return
        }
        let app = NSApplication.shared
        let delegate = TestAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
