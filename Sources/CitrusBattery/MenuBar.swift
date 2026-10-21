import AppKit
import CitrusKit
import SwiftUI

extension BatteryMonitor {
    /// Values for the menu bar text, using the user's display preferences.
    func menuBarValues(temperatureUnit: TemperatureUnit, capacityStyle: CapacityStyle) -> MenuBarValues {
        MenuBarValues(
            chargeFraction: battery?.chargeFraction(style: capacityStyle),
            cycleCount: battery?.cycleCount,
            temperatureText: battery?.temperatureCelsius.map(temperatureUnit.format(celsius:)),
            healthFraction: battery?.healthFraction,
            timeRemainingMinutes: battery?.timeRemainingMinutes,
            isCharging: battery?.isCharging ?? false,
            isExternalPowerConnected: battery?.isExternalPowerConnected ?? false,
            isFullyCharged: battery?.isFullyCharged ?? false,
            systemWatts: displayedSystemWatts,
            batteryWatts: battery?.batteryPowerWatts,
            chargerWatts: battery?.adapter?.watts
        )
    }
}

/// The status item: battery icon plus the user's format string.
struct MenuBarLabel: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @AppStorage(PreferenceKey.menuBarFormat) private var format = MenuBarToken.defaultFormat
    @AppStorage(PreferenceKey.batterySymbol) private var symbolPosition = BatterySymbolPosition.left
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.raw

    var body: some View {
        // The status bar drops images embedded in Text, so draw icon and text into
        // one template image; macOS then tints it for light and dark menu bars.
        Image(nsImage: Self.renderTemplate(content))
    }

    /// The icon and text as a plain view (also used for the Settings preview).
    var content: some View {
        let text = MenuBarFormatter.render(
            format, values: monitor.menuBarValues(temperatureUnit: temperatureUnit, capacityStyle: capacityStyle))
        let icon = Image(systemName: Self.symbolName(for: monitor.battery))
        return HStack(spacing: 4) {
            if symbolPosition == .left || (symbolPosition == .none && text.isEmpty) { icon }
            if !text.isEmpty { Text(text).monospacedDigit() }
            if symbolPosition == .right { icon }
        }
        .font(.system(size: 13))
        .foregroundStyle(.black)
    }

    @MainActor
    static func renderTemplate<V: View>(_ view: V) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }

    static func symbolName(for battery: MacBatterySnapshot?) -> String {
        guard let battery else { return "powerplug" }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.chargeFraction(style: .apple) ?? 0 {
        case 0.88...: return "battery.100percent"
        case 0.63..<0.88: return "battery.75percent"
        case 0.38..<0.63: return "battery.50percent"
        case 0.13..<0.38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// The window shown when clicking the status item.
struct MenuBarPanel: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.showDevicesInMenuBar) private var showDevices = true
    @AppStorage(PreferenceKey.menuBarAccentColour) private var useAccentColour = false
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.raw

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(monitor.marketingName ?? "This Mac")
                .font(.headline)

            if let battery = monitor.battery {
                MeterRow(title: "Charge", fraction: battery.chargeFraction(style: capacityStyle),
                         detail: statusLine(battery), tint: useAccentColour ? .accentColor : .green)
                MeterRow(title: "Health", fraction: battery.healthFraction, detail: nil,
                         tint: useAccentColour ? .accentColor : healthColour(battery.healthFraction))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    InfoRow("Cycles", battery.cycleCount.map(String.init))
                    InfoRow("Temperature", battery.temperatureCelsius.map(temperatureUnit.format(celsius:)))
                    InfoRow("System usage", monitor.displayedSystemWatts.map { String(format: "%.1f W", $0) })
                    InfoRow((battery.batteryPowerWatts ?? 0) >= 0 ? "Charging with" : "Discharging with",
                            battery.batteryPowerWatts.map { String(format: "%.1f W", abs($0)) })
                    if let limit = monitor.chargeLimit?.macOSLimitPercent {
                        InfoRow("Charge Limit", "\(limit)%")
                    }
                }
                .font(.callout)
            } else {
                Text("No battery found").foregroundStyle(.secondary)
            }

            if showDevices, !iosDevices.devices.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(iosDevices.devices) { device in
                        Button {
                            show(.device(device.udid))
                        } label: {
                            DevicePanelRow(device: device)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                PanelButton("Open Citrus Battery") { show(.thisMac) }
                PanelButton("History…") { show(.history) }
                SettingsPanelButton(beforeOpening: closePanel)
                PanelButton("Check for Updates…") {
                    closePanel()
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
                Divider().padding(.vertical, 4)
                PanelButton("Quit Citrus Battery") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func statusLine(_ battery: MacBatterySnapshot) -> String {
        let status = MenuBarFormatter.render("%STATUS%", values: monitor.menuBarValues(
            temperatureUnit: temperatureUnit, capacityStyle: capacityStyle))
        guard let minutes = battery.timeRemainingMinutes else { return status }
        let label = battery.isCharging ? "until full" : "remaining"
        return "\(status) · \(DurationFormat.readable(minutes)) \(label)"
    }

    /// The menu bar panel sits at pop-up-menu level; close it once an action is chosen.
    private func closePanel() {
        NSApp.windows.filter { $0.level == .popUpMenu && $0.isVisible }.forEach { $0.close() }
    }

    private func healthColour(_ fraction: Double?) -> Color {
        switch fraction ?? 1 {
        case 0.8...: .green
        case 0.6..<0.8: .yellow
        default: .red
        }
    }

    private func show(_ item: SidebarItem) {
        closePanel()
        navigator.selection = item
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

}

/// "Settings…" in the panel. macOS 14+ provides `openSettings`; the older
/// `showSettingsWindow:` action only works while a window is key, which isn't
/// the case once the panel has closed.
private struct SettingsPanelButton: View {
    let beforeOpening: () -> Void

    var body: some View {
        if #available(macOS 14, *) {
            Modern(beforeOpening: beforeOpening)
        } else {
            PanelButton("Settings…") {
                beforeOpening()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    @available(macOS 14, *)
    private struct Modern: View {
        let beforeOpening: () -> Void
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            PanelButton("Settings…") {
                beforeOpening()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }
}

/// One iPhone or iPad in the panel: icon, name, charge and a small bar.
private struct DevicePanelRow: View {
    let device: TrackedDevice

    var body: some View {
        let battery = device.snapshot?.battery
        let fraction = battery?.chargeFraction(style: .apple)
        HStack(spacing: 8) {
            Image(systemName: device.symbolName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(device.displayName).lineLimit(1)
                    Spacer()
                    Text(stateText(fraction: fraction)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule().fill(Color.green).frame(width: proxy.size.width * (fraction ?? 0))
                    }
                }
                .frame(height: 4)
            }
        }
        .contentShape(Rectangle())
    }

    private func stateText(fraction: Double?) -> String {
        switch device.state {
        case .ready, .disconnected:
            let battery = device.snapshot?.battery
            let charging = battery?.isCharging == true ? "⚡︎ " : battery?.isChargingPausedBySettings == true ? "⏸︎ " : ""
            let percent = fraction.map { "\(charging)\(Int(($0 * 100).rounded()))%" } ?? "–"
            return device.state == .disconnected ? "\(percent) (last seen)" : percent
        case .notTrusted: return "Tap Trust"
        case .locked: return "Locked"
        case .unavailable: return "–"
        }
    }
}

/// A full-width, menu-style button.
private struct PanelButton: View {
    let title: String
    let action: () -> Void
    @ViewState private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovering ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
