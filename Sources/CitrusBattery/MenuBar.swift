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
            isCalculatingTimeRemaining: battery?.isCalculatingTimeRemaining ?? false,
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
    @AppStorage(PreferenceKey.batteryPercentInIcon) private var percentInIcon = false
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.defaultStyle

    /// In the menu bar the label follows the menu bar's appearance; elsewhere
    /// (the Settings preview) the app's.
    var inMenuBar = true

    var body: some View {
        // The status bar drops images embedded in Text, so draw icon and text into
        // one image. Usually a template, which macOS tints for light and dark menu
        // bars; when the icon is coloured (Low Power Mode, low battery) the image
        // keeps its colours, so the rest is drawn in the menu bar's own ink.
        if Self.colour(for: monitor.battery, lowPowerMode: monitor.isLowPowerModeEnabled) == .none {
            Image(nsImage: Self.render(content(ink: nil), template: true))
        } else {
            Image(nsImage: Self.render(content(ink: MenuBarInk.current(inMenuBar: inMenuBar)), template: false))
        }
    }

    /// The icon and text as a plain view; `ink` colours everything but a coloured fill.
    private func content(ink: NSColor?) -> some View {
        let text = MenuBarFormatter.render(
            format, values: monitor.menuBarValues(temperatureUnit: temperatureUnit, capacityStyle: capacityStyle))
        let icon = Self.icon(for: monitor.battery, showingPercentage: percentInIcon,
                             lowPowerMode: monitor.isLowPowerModeEnabled, ink: ink)
        return HStack(spacing: 4) {
            if symbolPosition == .left || (symbolPosition == .none && text.isEmpty) { icon }
            if !text.isEmpty { Text(text).monospacedDigit() }
            if symbolPosition == .right { icon }
        }
        .font(.system(size: 13))
        .foregroundStyle(ink.map(Color.init(nsColor:)) ?? .black)
    }

    @MainActor
    static func render<V: View>(_ view: V, template: Bool) -> NSImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = template
        return image
    }

    /// The colour macOS gives the battery icon: yellow in Low Power Mode, red when
    /// the battery is nearly empty and not plugged in.
    static func colour(for battery: MacBatterySnapshot?, lowPowerMode: Bool) -> SystemBatteryIcon.Colour {
        guard let battery, SystemBatteryIcon.isAvailable else { return .none }
        #if DEBUG
        switch ProcessInfo.processInfo.environment["CITRUS_DEBUG_ICON_COLOUR"] {
        case "low": return .low
        default: break
        }
        #endif
        if lowPowerMode { return .lowPowerMode }
        if !battery.isExternalPowerConnected, (battery.chargeFraction(style: .apple) ?? 1) <= SystemBatteryIcon.lowLevel {
            return .low
        }
        return .none
    }

    /// The battery icon macOS itself shows in the menu bar, falling back to the
    /// nearest SF Symbol where the system's renderer isn't available.
    /// With `showingPercentage`, the charge is written inside it, as macOS can.
    static func icon(for battery: MacBatterySnapshot?, showingPercentage: Bool = false,
                     lowPowerMode: Bool = false, ink: NSColor? = nil) -> Image {
        if let battery, let image = SystemBatteryIcon.image(
            level: battery.chargeFraction(style: .apple) ?? 0, charging: battery.isCharging,
            pluggedIn: battery.isExternalPowerConnected, showingPercentage: showingPercentage,
            colour: ink == nil ? .none : colour(for: battery, lowPowerMode: lowPowerMode), ink: ink) {
            return Image(nsImage: image)
        }
        return Image(systemName: symbolName(for: battery))
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

/// Draws the battery icon with the private renderer behind macOS's own battery
/// menu (BatteryUIKit), so the fill, bolt and plug match it exactly.
@MainActor
enum SystemBatteryIcon {
    private typealias Render = @convention(c) (
        AnyObject, Selector, Double, Bool, Bool, Bool, Bool, Bool, Bool, Bool) -> NSImage?

    private static let renderer: (cache: AnyObject, selector: Selector, render: Render)? = {
        guard dlopen("/System/Library/PrivateFrameworks/BatteryUIKit.framework/BatteryUIKit", RTLD_NOW) != nil,
              let type = NSClassFromString("BUIImage") as? NSObject.Type else { return nil }
        let shared = NSSelectorFromString("sharedBUIImageCache")
        let selector = NSSelectorFromString(
            "_modernBatteryImageForLevel:charging:pluggedIn:noBattery:needsReplacement:lowPowerMode:showPercentage:useRed:")
        guard type.responds(to: shared), type.instancesRespond(to: selector),
              let cache = type.perform(shared)?.takeUnretainedValue(),
              let method = class_getInstanceMethod(type, selector) else { return nil }
        return (cache, selector, unsafeBitCast(method_getImplementation(method), to: Render.self))
    }()

    static var isAvailable: Bool { renderer != nil }

    /// macOS's colours for the icon's fill.
    enum Colour {
        case none, lowPowerMode, low
    }

    /// At or below this charge, on battery, the fill turns red.
    static let lowLevel = 0.10

    /// The icon, or nil where the renderer isn't available. With `showingPercentage`
    /// the charge is cut out of the icon as digits. Uncoloured, it is a template
    /// image; coloured, everything but the fill is drawn in `ink`.
    static func image(level: Double, charging: Bool, pluggedIn: Bool, showingPercentage: Bool,
                      colour: Colour = .none, ink: NSColor? = nil) -> NSImage? {
        guard let renderer,
              let image = renderer.render(renderer.cache, renderer.selector, min(max(level, 0), 1),
                                          charging, pluggedIn, false, false, colour == .lowPowerMode,
                                          showingPercentage, colour == .low) else { return nil }
        if colour != .none, let ink {
            return inked(image, with: ink)
        }
        guard let solid = solidFill(image) else { return nil }
        solid.isTemplate = true
        return solid
    }

    /// The coloured icon with its grey parts (outline, empty part, bolt) redrawn
    /// in `ink`, keeping their opacity; the coloured fill is left as it is.
    private static func inked(_ image: NSImage, with ink: NSColor) -> NSImage? {
        guard let rgb = ink.usingColorSpace(.deviceRGB) else { return nil }
        return transformed(image) { red, green, blue, alpha in
            guard alpha > 0 else { return (0, 0, 0, 0) }
            let spread = max(red, green, blue) - min(red, green, blue)
            if spread > 0.2 * alpha { return (red, green, blue, alpha) }
            let inked = alpha * rgb.alphaComponent
            return (rgb.redComponent * inked, rgb.greenComponent * inked, rgb.blueComponent * inked, inked)
        }
    }

    /// Redraws every pixel through `body`, which takes and returns premultiplied
    /// red, green, blue and alpha from 0 to 1.
    private static func transformed(
        _ image: NSImage, _ body: (Double, Double, Double, Double) -> (Double, Double, Double, Double)
    ) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = source.width, height = source.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let result = body(Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255,
                              Double(pixels[index + 2]) / 255, Double(pixels[index + 3]) / 255)
            pixels[index] = UInt8((min(max(result.0, 0), 1) * 255).rounded())
            pixels[index + 1] = UInt8((min(max(result.1, 0), 1) * 255).rounded())
            pixels[index + 2] = UInt8((min(max(result.2, 0), 1) * 255).rounded())
            pixels[index + 3] = UInt8((min(max(result.3, 0), 1) * 255).rounded())
        }
        return context.makeImage().map { NSImage(cgImage: $0, size: image.size) }
    }

    /// The renderer draws the charge at 85% opacity; the menu bar shows it
    /// opaque, so raise the fill to full opacity and leave the rest as it is.
    private static func solidFill(_ image: NSImage) -> NSImage? {
        let empty = 150.0 / 255, fill = 216.0 / 255
        // Template images only use alpha, so the colour stays black.
        return transformed(image) { _, _, _, alpha in
            (0, 0, 0, alpha > empty ? min(1, empty + (alpha - empty) * (1 - empty) / (fill - empty)) : alpha)
        }
    }
}

/// The colour the menu bar draws its text and icons in, for images that can't
/// be templates.
@MainActor
enum MenuBarInk {
    static func current(inMenuBar: Bool) -> NSColor {
        // The status item's window takes the menu bar's appearance, which follows
        // the wallpaper rather than the app.
        let appearance = inMenuBar
            ? NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }?.effectiveAppearance
            : nil
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Matches how the menu bar tints template images for apps.
        return dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
    }
}

/// The window shown when clicking the status item, laid out like a macOS menu:
/// a title with the charge, value rows, sections and menu-style commands.
struct MenuBarPanel: View {
    @EnvironmentObject private var monitor: BatteryMonitor
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var iosDevices: IOSDeviceMonitor
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.showDevicesInMenuBar) private var showDevices = true
    @AppStorage(PreferenceKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius
    @AppStorage(PreferenceKey.capacityStyle) private var capacityStyle = CapacityStyle.defaultStyle
    @StateObject private var energy = SignificantEnergyMonitor()
    @StateObject private var sleepBlockers = SleepBlockerMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let battery = monitor.battery {
                header(battery)
                MenuMeter(title: "Charge", fraction: battery.chargeFraction(style: capacityStyle),
                          decimals: capacityStyle == .raw, tint: .green)
                MenuMeter(title: "Health", fraction: battery.healthFraction, decimals: true,
                          tint: healthColour(battery.healthFraction))
                MenuSeparator()
                MenuSectionHeader("Details")
                ValueRow("Cycles", battery.cycleCount.map(String.init))
                ValueRow("Temperature", battery.temperatureCelsius.map(temperatureUnit.format(celsius:)))
                ValueRow("System usage", monitor.displayedSystemWatts.map { String(format: "%.1f W", $0) })
                let flow = BatteryFlow.describe(battery)
                ValueRow(flow.title, flow.value)
                if let limit = monitor.chargeLimit?.macOSLimitPercent {
                    ValueRow("Charge Limit", "\(limit)%")
                }
                if monitor.isLowPowerModeEnabled {
                    ValueRow("Low Power Mode", "On")
                }
                if let apps = energy.apps {
                    MenuSeparator()
                    if apps.isEmpty {
                        Text("No Apps Using Significant Energy")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .menuRowPadding(vertical: 4)
                    } else {
                        MenuSectionHeader("Using Significant Energy")
                        ForEach(apps) { EnergyAppRow(app: $0) }
                    }
                }
                if !sleepBlockers.blockers.isEmpty {
                    MenuSeparator()
                    MenuSectionHeader("Preventing Sleep")
                    ForEach(sleepBlockers.blockers) { SleepBlockerRow(blocker: $0) }
                }
            } else {
                Text(monitor.marketingName ?? "This Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .menuRowPadding()
                Text("No battery found")
                    .foregroundStyle(.secondary)
                    .menuRowPadding()
            }

            if showDevices, !iosDevices.devices.isEmpty {
                MenuSeparator()
                MenuSectionHeader("Devices")
                ForEach(iosDevices.devices) { device in
                    MenuItem(action: { show(.device(device.udid)) }) {
                        DevicePanelRow(device: device)
                    }
                }
            }

            MenuSeparator()
            PanelButton("Open Citrus Battery") { show(.thisMac) }
            PanelButton("History…") { show(.history) }
            MenuSeparator()
            PanelButton("Battery Settings…") {
                closePanel()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
            }
            PanelButton("Settings…") { show(.settings) }
            PanelButton("Check for Updates…") {
                closePanel()
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            MenuSeparator()
            PanelButton("Quit Citrus Battery") { NSApp.terminate(nil) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(width: 300)
        .onAppear {
            energy.start()
            sleepBlockers.start()
        }
        .onDisappear {
            energy.stop()
            sleepBlockers.stop()
        }
    }

    /// The Mac's name, with what's powering it underneath.
    private func header(_ battery: MacBatterySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.marketingName ?? "This Mac")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Text(statusLine(battery))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .menuRowPadding(vertical: 6)
    }

    private func healthColour(_ fraction: Double?) -> Color {
        switch fraction ?? 1 {
        case 0.8...: .green
        case 0.6..<0.8: .yellow
        default: .red
        }
    }

    private func statusLine(_ battery: MacBatterySnapshot) -> String {
        let source = battery.isExternalPowerConnected ? "Power Adapter" : "Battery"
        var parts = ["Power Source: \(source)"]
        if battery.isExternalPowerConnected && !battery.isCharging {
            // As macOS's Battery menu puts it when a limit is holding the charge.
            if isChargingOnHold(battery) {
                parts.append("Charging On Hold")
            } else if battery.isFullyCharged {
                parts.append("Fully Charged")
            }
        } else if battery.isCalculatingTimeRemaining {
            parts.append(battery.isCharging ? "Calculating time until full…" : "Calculating time left…")
        } else if let minutes = battery.timeRemainingMinutes {
            parts.append("\(DurationFormat.readable(minutes)) \(battery.isCharging ? "until full" : "left")")
        }
        return parts.joined(separator: " · ")
    }

    /// Plugged in but not charging because a charge limit, Optimized Battery
    /// Charging or a third-party limiter is holding the charge below full.
    private func isChargingOnHold(_ battery: MacBatterySnapshot) -> Bool {
        guard battery.isExternalPowerConnected, !battery.isCharging else { return false }
        if battery.isChargingPausedBySettings { return true }
        guard monitor.chargeLimit?.isLimiting == true else { return false }
        return (battery.chargeFraction(style: .apple) ?? 1) < 0.995
    }

    /// The menu bar panel sits at pop-up-menu level; close it once an action is chosen.
    private func closePanel() {
        NSApp.windows.filter { $0.level == .popUpMenu && $0.isVisible }.forEach { $0.close() }
    }

    private func show(_ item: SidebarItem) {
        closePanel()
        navigator.selection = item
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A percentage with a slim bar under it.
private struct MenuMeter: View {
    let title: String
    let fraction: Double?
    let decimals: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                Text(fraction.map { decimals ? String(format: "%.1f%%", $0 * 100) : "\(Int(($0 * 100).rounded()))%" }
                     ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .menuRowPadding(vertical: 5)
    }
}

/// A label with its value right-aligned in grey, as in macOS's own status menus.
private struct ValueRow: View {
    let title: String
    let value: String?

    init(_ title: String, _ value: String?) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .menuRowPadding()
    }
}

/// A menu section title.
private struct MenuSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .menuRowPadding(vertical: 4)
    }
}

/// A menu separator: a hairline inset from the edges.
private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}

private extension View {
    /// The insets of a macOS menu item.
    func menuRowPadding(vertical: CGFloat = 4) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, vertical)
    }
}

/// One iPhone or iPad in the panel: icon, name and charge, with the charge
/// drawn like the menu bar's battery icon.
private struct DevicePanelRow: View {
    let device: TrackedDevice

    var body: some View {
        let battery = device.snapshot?.battery
        let fraction = battery?.chargeFraction(style: .apple)
        HStack(spacing: 10) {
            // A round badge, like the network icons in the Wi-Fi menu.
            Image(systemName: device.symbolName)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName).lineLimit(1)
                if device.state == .disconnected {
                    Text("Not connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(stateText(fraction: fraction))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let fraction, device.state == .ready || device.state == .disconnected,
               let icon = SystemBatteryIcon.image(level: fraction, charging: battery?.isCharging ?? false,
                                                  pluggedIn: battery?.isExternalPowerConnected ?? false,
                                                  showingPercentage: false) {
                Image(nsImage: icon)
                    .foregroundStyle(.primary)
                    .opacity(device.state == .disconnected ? 0.5 : 1)
            }
        }
    }

    private func stateText(fraction: Double?) -> String {
        switch device.state {
        case .ready, .disconnected:
            // When disconnected, the last reading, with "Not connected" under the name.
            return fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        case .notTrusted: return "Tap Trust"
        case .locked: return "Locked"
        case .unavailable: return "–"
        }
    }
}

/// Polls macOS's "Using Significant Energy" list while the panel is open, as
/// macOS's own battery menu does.
@MainActor
final class SignificantEnergyMonitor: ObservableObject {
    /// Nil until the first reading, or when macOS doesn't provide the list.
    @Published private(set) var apps: [SignificantEnergyApp]?
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        Task.detached(priority: .utility) {
            let apps = SignificantEnergy.read()
            await MainActor.run { [weak self] in self?.apps = apps }
        }
    }
}

/// One app in "Using Significant Energy": its icon and name, as in macOS's menu.
private struct EnergyAppRow: View {
    let app: SignificantEnergyApp

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
        HStack(spacing: 8) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSWorkspace.shared.icon(for: .applicationBundle))
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.displayName ?? url.map { FileManager.default.displayName(atPath: $0.path) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? app.bundleIdentifier)
                .lineLimit(1)
        }
        .menuRowPadding()
    }
}

/// An app preventing sleep: its icon and name, with what it's doing underneath.
private struct SleepBlockerRow: View {
    let blocker: SleepBlocker

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIdentity.icon(blocker.owner))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppIdentity.name(blocker.owner)).lineLimit(1)
                Text(SleepBlockerText.detail(blocker))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .menuRowPadding()
    }
}

/// A full-width menu item with the hover highlight of a macOS menu.
private struct MenuItem<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            label
                .menuRowPadding()
                .background(hovering && isEnabled ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A text menu item.
private struct PanelButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        MenuItem(action: action) { Text(title) }
    }
}
