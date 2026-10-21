import AppKit
import Combine
import ServiceManagement

/// Applies the Dock icon preference and keeps the app running in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var defaultsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconPreference()
        if ProcessInfo.processInfo.environment["CITRUS_DEBUG_OPEN"] == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        if ProcessInfo.processInfo.environment["CITRUS_DEBUG_WINDOWS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for window in NSApp.windows {
                    FileHandle.standardError.write(Data("window \(type(of: window)) title=\"\(window.title)\" visible=\(window.isVisible) frame=\(window.frame)\n".utf8))
                }
            }
        }
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyDockIconPreference() }
    }

    /// Closing the window leaves the menu bar item running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.showInMenuBar
    }

    private func applyDockIconPreference() {
        // The Dock icon can only be hidden while the menu bar item gives access to the app.
        let showDock = UserDefaults.standard.showDockIcon || !UserDefaults.standard.showInMenuBar
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}

extension UserDefaults {
    var showInMenuBar: Bool { object(forKey: PreferenceKey.showInMenuBar) as? Bool ?? true }
    var showDockIcon: Bool { object(forKey: PreferenceKey.showDockIcon) as? Bool ?? true }
}

/// Open at login via SMAppService (macOS 13+). Only works from an app bundle.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
