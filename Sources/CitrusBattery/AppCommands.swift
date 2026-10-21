import AppKit
import CitrusKit
import SwiftUI

/// View and Help menu items.
struct AppCommands: Commands {
    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var navigator: Navigator
    @ObservedObject var iosDevices: IOSDeviceMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { monitor.refresh() }
                .keyboardShortcut("r")
            Button("Refresh iPhone/iPad") { iosDevices.refresh() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("History") { show(.history) }
                .keyboardShortcut("y")
            Button("Advanced Viewer") { openWindow(id: "advanced", value: advancedTarget) }
                .keyboardShortcut("i", modifiers: [.command, .option])
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

/// citrusbattery://mac, //history, //device/<udid>, //advanced[/<udid>]
enum CitrusURL {
    enum Route: Equatable {
        case select(SidebarItem)
        case advanced(String)
    }

    static func route(_ url: URL) -> Route? {
        guard url.scheme?.lowercased() == "citrusbattery" else { return nil }
        let id = url.pathComponents.dropFirst().first
        switch url.host?.lowercased() {
        case "mac", nil: return .select(.thisMac)
        case "history": return .select(.history)
        case "device": return id.map { .select(.device($0)) }
        case "advanced": return .advanced(id ?? AdvancedTarget.mac)
        default: return nil
        }
    }
}
