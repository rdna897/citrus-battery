import AppKit
import CitrusKit
import SwiftUI

/// View and Help menu items.
struct AppCommands: Commands {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var navigator: Navigator
    @ObservedObject var iosDevices: IOSDeviceMonitor
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Citrus Battery") { AboutCitrusBattery.show() }
            CheckForUpdatesButton(updater: updater)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { show(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { monitor.refresh() }
                .keyboardShortcut("r")
            Button("Refresh iPhone/iPad") { iosDevices.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("History") { show(.history) }
                .keyboardShortcut("y")
            Button("Sleep") { show(.sleep) }
            Button("Advanced Viewer") { openWindow(id: "advanced", value: advancedTarget) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Battery Lifetime Data") {
                navigator.lifetimeTarget = advancedTarget
                openWindow(id: "lifetime")
            }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Find Replacement Battery…") {
                ReplacementSearch.open(model: replacementModel)
            }
            Button("Copy Diagnostic Report") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiagnosticDump.report(), forType: .string)
            }
        }
    }

    private var advancedTarget: String {
        if case let .device(udid) = navigator.selection { return udid }
        return AdvancedTarget.mac
    }

    private var replacementModel: String {
        if case let .device(udid) = navigator.selection, let name = iosDevices.device(udid: udid)?.snapshot?.marketingName {
            return name
        }
        return monitor.marketingName ?? monitor.macInfo.modelIdentifier
    }

    private func show(_ item: SidebarItem) {
        navigator.selection = item
        openWindow(id: "main")
    }
}

/// Keep the native macOS About panel, with clickable author and source links.
@MainActor
enum AboutCitrusBattery {
    static func show() {
        let text = "Created by rdna897\n\ngithub.com/rdna897/citrus-battery"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let links = [
            ("rdna897", "https://github.com/rdna897"),
            ("github.com/rdna897/citrus-battery", "https://github.com/rdna897/citrus-battery"),
        ]
        for (label, address) in links {
            credits.addAttribute(.link, value: URL(string: address)!, range: (text as NSString).range(of: label))
        }
        NSApp.activate(ignoringOtherApps: true)
        // The build number matches the version (the updater compares it), so an
        // empty value hides the repeated "(1.2)" after "Version 1.2".
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }
}

/// citrusbattery://mac, //history, //sleep, //settings, //device/<udid>, //advanced[/<udid>], //lifetime[/<udid>]
enum CitrusURL {
    enum Route: Equatable {
        case select(SidebarItem)
        case advanced(String)
        case lifetime(String)
    }

    static func route(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == "citrusbattery" else { return nil }
        let id = url.pathComponents.dropFirst().first
        switch url.host?.lowercased() {
        case "mac", nil: return .select(.thisMac)
        case "history": return .select(.history)
        case "sleep": return .select(.sleep)
        case "settings": return .select(.settings)
        case "device": return id.map { .select(.device($0)) }
        case "advanced": return .advanced(id ?? AdvancedTarget.mac)
        case "lifetime": return .lifetime(id ?? AdvancedTarget.mac)
        default: return nil
        }
    }
}
