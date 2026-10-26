import AppKit
import Combine
import ServiceManagement

/// Applies the Dock icon preference and keeps the app running in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    weak var history: HistoryController?
    private var waitingToTerminate = false
    private var defaultsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconPreference()
        if UserDefaults.standard.startHiddenAtLogin, Self.launchedAtLogin {
            // SwiftUI opens the main window just after launch; hide it once it's there.
            for delay in [0, 0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.hideWindows() }
            }
        }
        updater.start()
        if ProcessInfo.processInfo.environment["CITRUS_GUI_SMOKE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else {
                    FileHandle.standardError.write(Data("No visible application window after launch\n".utf8))
                    exit(1)
                }
                guard self.updater.isAvailable, self.updater.canCheckForUpdates else {
                    FileHandle.standardError.write(Data("Updater did not start correctly\n".utf8))
                    exit(1)
                }
                print("Citrus updater startup check passed")
                print("Citrus GUI launch check passed")
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["CITRUS_DEBUG_OPEN"] == "panel" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.clickStatusItem() }
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

    /// Opens the menu bar panel by clicking our own status item (for UI captures).
    private static func clickStatusItem() {
        @MainActor
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(button(in:)).first
        }
        func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            log("status window \(type(of: window)) content=\(String(describing: window.contentView.map { type(of: $0) }))")
            if let content = window.contentView, let button = button(in: content) {
                log("clicking \(type(of: button))")
                button.performClick(nil)
                return
            }
        }
        log("no status item button found")
    }

    /// Whether macOS opened the app as a login item (at startup or login).
    private static var launchedAtLogin: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CITRUS_DEBUG_LOGIN_LAUNCH"] != nil { return true }
        #endif
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Login items don't always say so; just after startup, assume it was one.
        return LaunchAtLogin.isEnabled && ProcessInfo.processInfo.systemUptime < 300
    }

    /// Leaves the app in the menu bar, or minimised in the Dock without one.
    private static func hideWindows() {
        let showInMenuBar = UserDefaults.standard.showInMenuBar
        for window in NSApp.windows where window.isVisible && window.level == .normal && window.canBecomeMain {
            if showInMenuBar {
                window.close()
            } else if !window.isMiniaturized {
                window.miniaturize(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let history else { return .terminateNow }
        guard !waitingToTerminate else { return .terminateLater }
        waitingToTerminate = true
        history.prepareForTermination { [weak self] in self?.finishTermination(sender) }
        // A slow import or an unavailable disk must not keep the app open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishTermination(sender) }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard waitingToTerminate else { return }
        waitingToTerminate = false
        sender.reply(toApplicationShouldTerminate: true)
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
    var startHiddenAtLogin: Bool { object(forKey: PreferenceKey.startHiddenAtLogin) as? Bool ?? true }
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
