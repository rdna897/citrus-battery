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
    @Environment(\.openWindow) private var openWindow
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
                        InfoRow("Charge limit", "\(limit)%")
                    }
                }
                .font(.callout)
            } else {
                Text("No battery found").foregroundStyle(.secondary)
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                PanelButton("Open Citrus Battery") { show(.thisMac) }
                PanelButton("History…") { show(.history) }
                PanelButton("Settings…") { openSettings() }
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
        return "\(status) · \(DurationFormat.hoursMinutes(minutes)) \(label)"
    }

    private func healthColour(_ fraction: Double?) -> Color {
        switch fraction ?? 1 {
        case 0.8...: .green
        case 0.6..<0.8: .yellow
        default: .red
        }
    }

    private func show(_ item: SidebarItem) {
        navigator.selection = item
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
